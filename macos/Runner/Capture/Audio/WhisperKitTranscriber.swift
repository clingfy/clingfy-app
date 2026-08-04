import Foundation
import WhisperKit

/// `CaptionTranscriber` backed by WhisperKit.
///
/// The only file in the app that imports WhisperKit. Everything above it —
/// source selection, hallucination guards, bleed dedup, overlap resolution —
/// is engine-agnostic and tested against a fake, so swapping engines or adding
/// a second one touches this file and nothing else.
///
/// ## Decoding is deliberately not WhisperKit's job
///
/// `transcribe(audioPath:)` is never called. It has an open bug
/// (argmaxinc/argmax-oss-swift#500) that silently corrupts long compressed
/// audio — an 87-minute file yields a garbage transcript with a success exit
/// code — and long compressed `.m4a` is precisely what this app records. Audio
/// is decoded by `CaptionAudioDecoder` and handed over as `[Float]`, which is
/// the documented "16 kHz raw float samples" contract of `transcribe(audioArray:)`.
///
/// ## Concurrency
///
/// `WhisperKit` is an `open class`, not an actor, not `Sendable`, and has open
/// data races on its own `progress` property (#331) and on `AudioProcessor`
/// state (#442). One instance is owned here and guarded by a serial queue;
/// nothing transcribes two things on it concurrently.
final class WhisperKitTranscriber: CaptionTranscriber {

  /// Argmax's recommended default. Despite the name this IS the turbo model —
  /// OpenAI's large-v3-turbo is the 2024-09-30 release, with a 4-layer decoder.
  ///
  /// Do not reach for a variant with a `_turbo` suffix: in WhisperKit that
  /// suffix means something else entirely (an extra context-prefill model), and
  /// as of v1.0.0 `TextDecoderContextPrefill` is referenced nowhere in the
  /// source — so those variants are pure dead download weight.
  static let defaultModel = "openai_whisper-large-v3-v20240930_626MB"

  private let model: String
  private let modelDirectory: URL
  private let queue = DispatchQueue(label: "com.clingfy.captions.asr", qos: .userInitiated)
  private var pipe: WhisperKit?

  init(model: String = WhisperKitTranscriber.defaultModel, modelDirectory: URL) {
    self.model = model
    self.modelDirectory = modelDirectory
  }

  // MARK: - Availability

  var availability: TranscriberAvailability {
    #if arch(arm64)
      return .available
    #else
      // WhisperKit builds on x86_64 but there is no Neural Engine, so compute
      // falls back to CPU+GPU. That is slow rather than broken — surfaced as a
      // distinct reason so the UI can warn rather than refuse.
      return .unavailable(reason: "intelSlowPath")
    #endif
  }

  // MARK: - Transcription

  func transcribe(
    url: URL,
    options: TranscriptionOptions,
    progress: @escaping (Double) -> Void,
    isCancelled: @escaping () -> Bool
  ) throws -> [TranscribedSegment] {
    // Decode first, and report it as the first slice of progress. On a long
    // recording this is seconds of real work and a bar that sits at zero
    // through it reads as a hang.
    progress(0.0)
    var samples = try CaptionAudioDecoder.decodeMono16k(url: url, isCancelled: isCancelled)
    CaptionAudioDecoder.normalizePeak(&samples)
    if isCancelled() { throw TranscriptionError.cancelled }
    progress(decodeProgressShare)

    return try queue.sync {
      try runTranscription(
        samples: samples, options: options, progress: progress, isCancelled: isCancelled)
    }
  }

  /// Decode is roughly this fraction of the wall clock on a typical recording.
  /// Only used to keep the bar honest during decode; the rest is real.
  private let decodeProgressShare = 0.1

  private func runTranscription(
    samples: [Float],
    options: TranscriptionOptions,
    progress: @escaping (Double) -> Void,
    isCancelled: @escaping () -> Bool
  ) throws -> [TranscribedSegment] {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<[TranscribedSegment], Error> = .failure(TranscriptionError.cancelled)

    let work = Task { [self] in
      do {
        let pipeline = try await loadedPipeline()
        // Poll rather than KVO: WhisperKit REASSIGNS its `progress` property on
        // completion and on cancellation, so an observer registered on the
        // original object silently stops firing. Polling is what Argmax's own
        // CLI does.
        let poller = Task { [weak pipeline] in
          while !Task.isCancelled {
            if let fraction = pipeline?.progress.fractionCompleted, fraction > 0 {
              let scaled = decodeProgressShare + (fraction * (1.0 - decodeProgressShare))
              progress(min(scaled, 0.999))
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
          }
        }
        defer { poller.cancel() }

        let raw = try await pipeline.transcribe(
          audioArray: samples,
          decodeOptions: Self.decodingOptions(from: options)
        )
        let merged = TranscriptionUtilities.mergeTranscriptionResults(raw)
        result = .success(Self.map(merged.segments))
      } catch is CancellationError {
        result = .failure(TranscriptionError.cancelled)
      } catch {
        result = .failure(TranscriptionError.engine(String(describing: error)))
      }
      semaphore.signal()
    }

    // Task cancellation is the real cancel: WhisperKit checks
    // `Task.checkCancellation()` three times per 30s window plus once in the
    // decode loop, so the worst-case latency is about one encoder pass.
    // Returning false from the decoding callback would only truncate the
    // current window, not the job.
    while semaphore.wait(timeout: .now() + 0.1) == .timedOut {
      if isCancelled() {
        work.cancel()
        _ = semaphore.wait(timeout: .now() + 10)
        throw TranscriptionError.cancelled
      }
    }

    progress(1.0)
    return try result.get()
  }

  private func loadedPipeline() async throws -> WhisperKit {
    if let pipe { return pipe }
    let config = WhisperKitConfig(
      model: model,
      // Never the default. WhisperKit's HubApi defaults downloadBase to
      // ~/Documents/huggingface, which for an unsandboxed Developer-ID app is
      // the user's real Documents folder — visible clutter in a paid app, and
      // possibly inside iCloud Drive sync.
      downloadBase: modelDirectory,
      // Loads each model then unloads before the next, so peak memory is one
      // model rather than all three plus compilation. Costs a second load when
      // Core ML's per-chip specialisation cache is already warm, which is the
      // right trade for a 626 MB model.
      prewarm: true,
      load: true,
      download: true
    )
    let created = try await WhisperKit(config)
    pipe = created
    return created
  }

  // MARK: - Mapping

  static func decodingOptions(from options: TranscriptionOptions) -> DecodingOptions {
    var decoding = DecodingOptions()
    decoding.task = .transcribe
    decoding.language = options.language
    // Word timings power the cut-reflow rule: when a clip edit removes part of
    // a cue's audio, the surviving words are re-emitted rather than the whole
    // sentence repeating over each fragment.
    decoding.wordTimestamps = true
    // Off by default in WhisperKit, unlike upstream whisper. A screen recording
    // is mostly silence, and VAD chunking is the single biggest lever against
    // hallucinating over it.
    decoding.chunkingStrategy = .vad
    // Defaults to 16 on macOS and only bites with VAD on, where it decodes that
    // many windows at once — 16x the per-window working set, in an app already
    // holding video buffers.
    decoding.concurrentWorkerCount = 4
    // WhisperKit defaults this false; upstream whisper defaults it true.
    decoding.suppressBlank = true
    decoding.noSpeechThreshold = Float(options.noSpeechThreshold)
    return decoding
  }

  static func map(_ segments: [TranscriptionSegment]) -> [TranscribedSegment] {
    segments.map { segment in
      TranscribedSegment(
        startMs: Int((segment.start * 1000).rounded()),
        endMs: Int((segment.end * 1000).rounded()),
        text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
        words: (segment.words ?? []).map { word in
          TranscribedWord(
            text: word.word,
            startMs: Int((word.start * 1000).rounded()),
            endMs: Int((word.end * 1000).rounded())
          )
        },
        // Carried through so `TranscriptionJob` can filter after the fact. The
        // engine's own threshold only decides whether to RETRY a window; it
        // does not delete the segment.
        noSpeechProbability: Double(segment.noSpeechProb)
      )
    }
  }
}
