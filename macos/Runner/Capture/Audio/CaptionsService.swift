import Foundation

/// Owns the one in-flight transcription: its queue, its engine, its cancel flag.
///
/// ## Its own queue, deliberately not `AudioComputeQueue`
///
/// `AudioComputeQueue.swift:3-16` accepts that "a synchronous caller (the export
/// preamble) can wait behind an unrelated in-flight pass" — a bargain struck for
/// passes lasting seconds. A transcription runs for minutes, so putting it there
/// would park an export behind it and read as a frozen app. That same comment
/// forbids nesting queue users, and both audio caches expose a blocking
/// `outcome` doing `queue.sync`, so anything running on that queue that asked
/// for cleaned audio would self-deadlock with no error.
///
/// The memory bound that queue exists to enforce is respected differently here:
/// this queue is serial too, and the job decodes one source at a time.
///
/// ## One job at a time
///
/// `WhisperKit` is an `open class`, not an actor, not `Sendable`, with open data
/// races on its own `progress` property and on `AudioProcessor` state. One
/// instance is owned here and only ever touched from this serial queue.
final class CaptionsService {

  /// Where WhisperKit models live.
  ///
  /// Never the library default, which is `~/Documents/huggingface` — in an
  /// unsandboxed Developer-ID app that is the user's real Documents folder,
  /// which is user-visible clutter in a paid product and may sit inside iCloud
  /// Drive sync.
  static func modelDirectory() -> URL {
    AppPaths.captionModelsDirectory()
  }

  private let queue = DispatchQueue(
    label: "com.clingfy.captions.service", qos: .userInitiated)

  /// Set from any thread to abandon the in-flight job. Read by the engine
  /// between decode buffers and inside its decoding loop.
  private let cancelLock = NSLock()
  private var cancelRequested = false
  private var isRunning = false

  private lazy var transcriber: CaptionTranscriber = WhisperKitTranscriber(
    modelDirectory: Self.modelDirectory())

  /// Injection point for tests, which must never touch a real model.
  init(transcriber: CaptionTranscriber? = nil) {
    if let transcriber {
      self.transcriber = transcriber
    }
  }

  // MARK: - Cancellation

  func cancel() {
    cancelLock.lock()
    cancelRequested = true
    cancelLock.unlock()
    NativeLogger.i("Captions", "Cancellation requested")
  }

  private func shouldCancel() -> Bool {
    cancelLock.lock()
    defer { cancelLock.unlock() }
    return cancelRequested
  }

  private func beginRun() -> Bool {
    cancelLock.lock()
    defer { cancelLock.unlock() }
    if isRunning { return false }
    isRunning = true
    cancelRequested = false
    return true
  }

  private func endRun() {
    cancelLock.lock()
    isRunning = false
    cancelRequested = false
    cancelLock.unlock()
  }

  // MARK: - Running

  /// Transcribes a project's audio and calls back with cues.
  ///
  /// `sources` are resolved by the CALLER, off this queue, and handed over as
  /// plain URLs. That is the rule the `AudioComputeQueue` comment demands: a job
  /// must not reach back into a blocking cache from inside a queue.
  ///
  /// Progress arrives on an arbitrary thread; the bridge marshals.
  func generateCaptions(
    sources: TranscriptionJob.Sources,
    language: String?,
    onProgress: @escaping (JobProgress) -> Void,
    completion: @escaping (Result<[Caption], Error>) -> Void
  ) {
    guard beginRun() else {
      completion(.failure(TranscriptionError.engine("A transcription is already running")))
      return
    }

    // Indeterminate until the engine can report a real fraction: loading a
    // ~626 MB model and letting Core ML specialise it for this chip takes tens
    // of seconds on a cold cache, and a determinate bar pinned at 0% through
    // that is indistinguishable from a hang.
    onProgress(JobProgress.captions(nil, stage: .preparing))

    queue.async { [self] in
      defer { endRun() }

      var micOptions = TranscriptionOptions.default
      var systemOptions = TranscriptionOptions.strict
      micOptions.language = language
      systemOptions.language = language

      let job = TranscriptionJob(transcriber: transcriber)
      do {
        let cues = try job.run(
          sources: sources,
          micOptions: micOptions,
          systemOptions: systemOptions,
          progress: { update in
            // The phase decides the stage the panel names. Before this every
            // phase was reported as `transcribing`, so a first-run model
            // download showed a determinate bar frozen at 10% for minutes.
            let stage: JobProgress.Stage
            switch update.phase {
            case .downloadingModel: stage = .downloadingModel
            case .preparing: stage = .preparing
            case .transcribing: stage = .transcribing
            }
            onProgress(JobProgress.captions(update.fraction, stage: stage))
          },
          isCancelled: { [self] in shouldCancel() }
        )
        NativeLogger.i(
          "Captions", "Transcription finished",
          context: ["cues": cues.count])
        completion(.success(cues))
      } catch {
        if let transcriptionError = error as? TranscriptionError,
          transcriptionError == .cancelled
        {
          NativeLogger.i("Captions", "Transcription cancelled")
        } else {
          NativeLogger.e("Captions", "Transcription failed: \(error)")
        }
        completion(.failure(error))
      }
    }
  }

  /// Picks the audio the job should transcribe, honouring the user's source
  /// selection and falling back the way the capability probe reports.
  ///
  /// Gated on `readableAudioAsset` — an actual decode probe — rather than
  /// `fileExists`, because a sidecar can be present and undecodable (the
  /// documented Bluetooth-HFP writer failure) and a job that trusted the file
  /// system would start and then fail partway through.
  static func resolveSources(
    mediaSources: PreviewMediaSources,
    useMic: Bool,
    useSystem: Bool
  ) -> TranscriptionJob.Sources {
    func decodable(_ path: String?) -> URL? {
      guard let path, !path.isEmpty else { return nil }
      let url = URL(fileURLWithPath: path)
      return LetterboxExporter.readableAudioAsset(url: url) != nil ? url : nil
    }

    let mic = useMic ? decodable(mediaSources.micAudioPath) : nil
    let system = useSystem ? decodable(mediaSources.systemAudioPath) : nil

    // Only when neither sidecar is usable. A recording made before macOS 15 has
    // no sidecars at all — the sidecar writer is macOS 15+ — and on that capture
    // backend `screen.mov` holds the MICROPHONE alone, because AVFoundation
    // screen capture has no loopback tap. A meeting recorded then has one side
    // of the conversation on disk and nothing recovers the other.
    let embedded: URL? =
      (mic == nil && system == nil) ? decodable(mediaSources.screenPath) : nil

    return TranscriptionJob.Sources(
      micURL: mic, systemURL: system, embeddedURL: embedded)
  }
}
