import Foundation

/// Owns the one in-flight transcription: its queue, its engine, its cancel token.
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

  /// The token handed to the job that is running now, or `nil` between jobs.
  ///
  /// Guarded because `cancel()` arrives on the main thread while the service
  /// queue starts and ends jobs.
  private let cancelLock = NSLock()
  private var activeToken: CaptionJobCancellation?
  private var isRunning = false

  /// The engine this service drives, decided once and never re-decided.
  ///
  /// Deliberately NOT `lazy` — the same defect `WhisperKitTranscriber.drain` was
  /// demoted from a `lazy var` for. Swift's lazy initialisation is not atomic,
  /// and this is first touched from threads that share no lock: `isBusy` and
  /// `isModelLoaded` read it on the main thread for the Settings › Storage
  /// delete gate, the export preamble reaches it through `releaseModel`, and the
  /// service queue captures it for a job. A simultaneous first touch runs the
  /// initialiser twice, and the two threads walk away holding DIFFERENT engines:
  /// the job transcribes on one while the delete gate asks the other whether the
  /// model is loaded and is told no, so 730 MB is removed with Core ML still
  /// mmapping it.
  ///
  /// Assigned in `init` instead, where there is exactly one thread.
  private let transcriber: CaptionTranscriber

  /// Injection point for tests, which must never touch a real model.
  ///
  /// The default engine is built here rather than on first use. That does mean
  /// `AppPaths.captionModelsDirectory()` creates its (empty) folder when the
  /// service is constructed; harmless, because `CaptionModelStore` keys
  /// "installed" off bytes and never off directory existence.
  init(transcriber: CaptionTranscriber? = nil) {
    self.transcriber =
      transcriber ?? WhisperKitTranscriber(modelDirectory: Self.modelDirectory())
  }

  #if DEBUG
    /// Identity of the engine this service drives.
    ///
    /// Test seam for the one thing a non-atomic `lazy var` here would break and
    /// nothing else can observe: two threads first-touching the property run the
    /// initialiser twice and walk away with different engines. Only identity
    /// shows that — every method on the protocol answers the same for either
    /// instance.
    var engineIdentityForTesting: ObjectIdentifier {
      ObjectIdentifier(transcriber as AnyObject)
    }
  #endif

  // MARK: - Model lifetime

  /// True while anything is touching the model, so a delete can be refused.
  ///
  /// Wider than `isRunning` deliberately: the engine stays busy through the
  /// unwinding of a cancelled first-run download, which is precisely when a
  /// user who just hit Cancel is most likely to reach for Delete.
  var isBusy: Bool {
    cancelLock.lock()
    let running = isRunning
    cancelLock.unlock()
    return running || transcriber.isEngineBusy
  }

  /// Whether a model is currently held in memory. Reported to the UI so
  /// "Delete" can explain that it also unloads.
  var isModelLoaded: Bool { transcriber.isEngineBusy }

  /// Drops the in-memory model, then hands back to the caller.
  ///
  /// - Parameter completion: `false` when the engine refused — a cancelled job's
  ///   abandoned task still owns the weights. The caller must not delete on a
  ///   refusal: Core ML has those files mmapped, and the abandoned download is
  ///   still writing more of them into the same directory. Before this carried a
  ///   result, a skip and a real unload were indistinguishable, and
  ///   `deleteCaptionModel` removed the model on either.
  func releaseModel(completion: @escaping (Bool) -> Void) {
    Task {
      let released = await transcriber.releaseModel()
      completion(released)
    }
  }

  /// The variant the engine would download, for display.
  static var modelVariant: String { WhisperKitTranscriber.defaultModel }

  // MARK: - Cancellation

  func cancel() {
    cancelLock.lock()
    let token = activeToken
    cancelLock.unlock()
    // Nothing running is not an error, and it is not remembered either: a cancel
    // that arrives between jobs used to be latched in a service-wide flag and
    // had to be scrubbed by the next `beginRun`.
    token?.cancel()
    NativeLogger.i("Captions", "Cancellation requested")
  }

  private func beginRun() -> CaptionJobCancellation? {
    cancelLock.lock()
    defer { cancelLock.unlock() }
    if isRunning { return nil }
    isRunning = true
    let token = CaptionJobCancellation()
    activeToken = token
    return token
  }

  private func endRun(_ token: CaptionJobCancellation) {
    cancelLock.lock()
    isRunning = false
    // Only ever detached, never un-cancelled. The token outlives the job that
    // owns it — see `CaptionJobCancellation` — and the `=== token` guard is
    // there so a job that ends late cannot unhook a newer job's token.
    if activeToken === token { activeToken = nil }
    cancelLock.unlock()

    releaseModelWhenTheEngineWillGiveItBack()
  }

  /// How long to leave between asking the engine again after it refused.
  ///
  /// A refusal means an abandoned model download is unwinding, which is a
  /// network fetch measured in tens of seconds — polling faster buys nothing,
  /// and each poll is one lock read.
  private static let releaseRetryInterval: TimeInterval = 0.25

  /// How long to keep asking before giving up and logging it.
  ///
  /// Bounded so a task that never ends cannot leave a poll running for the life
  /// of the process. Generous, because the thing being waited on is a 626 MB
  /// download on whatever connection the user has.
  private static let releaseRetryWindow: TimeInterval = 15 * 60

  /// Hands the weights back once the job is over, waiting out an abandoned task
  /// if one still owns them.
  ///
  /// A loaded pipeline is several hundred megabytes, and what a user does next
  /// after captioning is usually export the video they just captioned — the
  /// peak-memory moment in this app. Dropping this left the model resident for
  /// the whole session on the chance a second transcription was wanted, so a
  /// user who generated subtitles and then recorded a 4K screen carried it
  /// through recording, preview and export.
  ///
  /// It is only affordable because `WhisperKitTranscriber` now checks the disk
  /// before fetching. Last time this ran, unloading after every job sent the
  /// next one back through `WhisperKit.download`, which reaches the network even
  /// on a warm cache and is what puts "Downloading speech model" on screen — so
  /// every run after the first announced a download that was not happening, and
  /// failed outright offline. `existingModelFolder()` is what stopped that: the
  /// cost of releasing here is a reload, not a re-download.
  ///
  /// ## Why it retries rather than asking once
  ///
  /// The engine REFUSES while a cancelled job's abandoned task still owns the
  /// pipeline — that task can be inside `WhisperKit(config)`, about to assign
  /// into `pipe`, so unloading underneath it is a data race on a type that is
  /// not `Sendable`. Asking once and accepting the refusal would then strand the
  /// model in the one case where nothing is going to ask for it again: the user
  /// cancelled, so no second job is coming to release it either. A refusal is
  /// therefore "not yet", not "no".
  private func releaseModelWhenTheEngineWillGiveItBack() {
    Task { [weak self] in
      let deadline = Date().addingTimeInterval(Self.releaseRetryWindow)
      while let service = self {
        // A newer job has taken the engine. It wants the model loaded, and its
        // own `endRun` schedules the next release — stopping here is what keeps
        // this from unloading weights the job is about to read.
        if service.isJobRunning { return }
        if await service.transcriber.releaseModel() { return }
        guard Date() < deadline else {
          NativeLogger.i(
            "Captions",
            "Stopped waiting to hand the speech model back: the engine still holds it")
          return
        }
        try? await Task.sleep(
          nanoseconds: UInt64(Self.releaseRetryInterval * 1_000_000_000))
      }
    }
  }

  /// Whether a transcription job is running right now.
  ///
  /// Narrower than `isBusy` on purpose. `isBusy` also reports the ENGINE, which
  /// is precisely the drain the release above is waiting out — asking it there
  /// would abandon the retry at the first refusal and strand the model forever.
  private var isJobRunning: Bool {
    cancelLock.lock()
    defer { cancelLock.unlock() }
    return isRunning
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
    guard let token = beginRun() else {
      completion(.failure(TranscriptionError.engine("A transcription is already running")))
      return
    }

    // Indeterminate until the engine can report a real fraction: loading a
    // ~626 MB model and letting Core ML specialise it for this chip takes tens
    // of seconds on a cold cache, and a determinate bar pinned at 0% through
    // that is indistinguishable from a hang.
    onProgress(JobProgress.captions(nil, stage: .preparing))

    queue.async { [self] in
      defer { endRun(token) }

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
          // The token, not the service. A cancelled job's engine task OUTLIVES
          // the job — the model download is not interruptible, so it keeps
          // polling this closure while it unwinds — and `endRun` fires from the
          // same `defer` that ends the cancelled job. Reading a service-wide
          // flag therefore meant the abandoned task was told, moments later,
          // that nothing had been cancelled: it finished the 626 MB download the
          // user had stopped and loaded it into a pipeline nobody would ever
          // use, after the release had already run against an empty one.
          isCancelled: { token.isCancelled }
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

/// One transcription's cancel flag, owned by that transcription alone.
///
/// A per-job object rather than a field on the service, because the thing that
/// reads it outlives the job that created it. A cancelled run abandons its
/// engine task — deliberately, since `HubApi.snapshot` never checks
/// cancellation and the user must not be made to wait out a 626 MB download —
/// and that task goes on polling the closure it was handed for as long as the
/// download takes.
///
/// With one flag on the service, the job's own teardown cleared it: the service
/// reset the flag as the cancelled job unwound, the abandoned task asked "was I
/// cancelled?", was told no, and finished the download the user had stopped.
///
/// Latches. There is no `reset()` on purpose — un-cancelling is the bug.
final class CaptionJobCancellation {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
}
