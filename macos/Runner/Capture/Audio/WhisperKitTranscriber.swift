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

  /// The engine task from a job the user cancelled, still unwinding.
  ///
  /// Cancelling no longer blocks the caller, because the model download is not
  /// interruptible — `HubApi.snapshot` has no cancellation check, so a cancel
  /// during a first-run download used to leave the user staring at a live
  /// progress bar for the ten seconds the old code spent waiting on it. The
  /// task is abandoned instead, and the NEXT job waits for it here rather than
  /// touching a `WhisperKit` instance it is still using.
  ///
  /// Deliberately NOT `lazy`. Swift's lazy initialisation is not atomic, and
  /// this is first touched from two threads that hold no common lock:
  /// `isEngineBusy` reads it from the main thread (the delete path) AFTER
  /// releasing `busyLock`, while the ASR queue reaches it through `transcribe`.
  /// A simultaneous first touch runs the initialiser twice and leaves the two
  /// threads looking at different `EngineDrain` objects — one of which nobody
  /// clears. Assigned in `init` instead, where there is exactly one thread.
  ///
  /// Internal, not private, so a test can put a claim in place without a 626 MB
  /// model. Nothing outside this file writes it.
  let drain: EngineDrain

  /// Guards `engineBusy`, which is read from the main thread by the delete path
  /// while the ASR queue writes it.
  private let busyLock = NSLock()
  private var engineBusy = false

  var isEngineBusy: Bool {
    busyLock.lock()
    let running = engineBusy
    busyLock.unlock()
    return running || drain.isDraining
  }

  private func setEngineBusy(_ value: Bool) {
    busyLock.lock()
    engineBusy = value
    busyLock.unlock()
  }

  /// Unloads the pipeline so the weights on disk can actually be removed.
  ///
  /// Routed through the queue that owns `pipe` (see the concurrency note at the
  /// top of this file). It used to unload from whatever thread the delete or the
  /// export preamble arrived on, mutating `pipe` with no lock at all — and the
  /// enqueue is not bureaucracy: while the queue is held by a run, an abandoned
  /// task can still be inside `WhisperKit(config)` and about to assign into
  /// `pipe`, so an unlocked `pipe = nil` from another thread is both a data race
  /// and a silent no-op that leaves the weights loaded.
  ///
  /// Answers `false` when it declined. "Nothing to unload" and "a cancelled job
  /// still owns the engine" used to be the same silent return, and the caller
  /// that matters is `deleteCaptionModel`: it removed 730 MB on the strength of
  /// this having been called, so a skip meant deleting files Core ML still had
  /// mmapped while an abandoned download was writing more of them.
  @discardableResult
  func releaseModel() async -> Bool {
    let outcome: (released: Bool, pipeline: WhisperKit?) = await withCheckedContinuation {
      continuation in
      queue.async { [self] in
        // Skipped while a cancelled job unwinds. That task owns the engine and
        // may be assigning a freshly loaded pipeline into `pipe` right now;
        // taking it away underneath is the race this file's header forbids.
        // Nothing is leaked by waiting — `isEngineBusy` is true for the whole
        // drain, so the delete path refuses anyway, and the export preamble
        // calls this again on the next export.
        if drain.isDraining {
          NativeLogger.i(
            "Captions", "Kept the speech model loaded: a cancelled job is still unwinding")
          continuation.resume(returning: (false, nil))
          return
        }
        let current = pipe
        pipe = nil
        continuation.resume(returning: (true, current))
      }
    }
    guard outcome.released else { return false }
    guard let pipeline = outcome.pipeline else { return true }
    await pipeline.unloadModels()
    NativeLogger.i("Captions", "Released the speech model from memory")
    return true
  }

  init(model: String = WhisperKitTranscriber.defaultModel, modelDirectory: URL) {
    self.model = model
    self.modelDirectory = modelDirectory
    // After `queue`, which has its own initialiser expression and is therefore
    // already assigned here. See the `drain` declaration for why this is not a
    // `lazy var`.
    self.drain = EngineDrain(queue: queue)
  }

  /// Test seam: takes the engine claim a cancelled job would have left behind.
  ///
  /// `EngineDrain.claim` is documented to run on the queue that owns the engine
  /// — that is what orders the release against a job taking the engine — and
  /// that queue is private, so a test cannot make an honest claim without this.
  func claimEngineForTesting(_ task: Task<Void, Never>) {
    queue.sync { drain.claim(task) }
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
    progress: @escaping (TranscriptionProgress) -> Void,
    isCancelled: @escaping () -> Bool
  ) throws -> [TranscribedSegment] {
    // Held across the whole run, including the model load, so a delete cannot
    // land between loading the weights and reading them.
    setEngineBusy(true)
    defer { setEngineBusy(false) }
    // Decode first, and report it as the first slice of progress. On a long
    // recording this is seconds of real work and a bar that sits at zero
    // through it reads as a hang.
    progress(.preparing())
    var samples: [Float]
    do {
      samples = try CaptionAudioDecoder.decodeMono16k(url: url, isCancelled: isCancelled)
    } catch {
      // The decoder speaks `CaptionAudioDecoder.DecodeError`, and a file
      // AVFoundation refuses arrives as a bare `NSError`. This protocol is
      // documented to throw `TranscriptionError`, and everything above it casts
      // to that type to tell a cancel from a failure — so letting one through
      // turned the user's own Stop, pressed during the decode that runs before
      // anything else, into "Couldn't generate subtitles" and a Sentry error.
      throw TranscriptionError(decodeFailure: error)
    }
    CaptionAudioDecoder.normalizePeak(&samples)
    if isCancelled() { throw TranscriptionError.cancelled }
    progress(.transcribing(decodeProgressShare))

    return try queue.sync {
      // An earlier job the user cancelled may still be inside a download or an
      // encoder pass on the shared WhisperKit instance, which is not Sendable
      // and has open data races. Starting a second one on top of it would be a
      // crash, so wait it out first.
      try awaitDrain(isCancelled: isCancelled)
      if isCancelled() { throw TranscriptionError.cancelled }
      return try runTranscription(
        samples: samples, options: options, progress: progress, isCancelled: isCancelled)
    }
  }

  /// Waits out an abandoned engine task, or throws if the user gives up.
  ///
  /// Runs on the transcriber's serial queue, so nothing else can reach the
  /// pipeline meanwhile. The wait itself is unbounded -- an abandoned model
  /// download can run for minutes -- so it is polled rather than blocked on,
  /// and a cancel during it throws instead of being ignored.
  private func awaitDrain(isCancelled: @escaping () -> Bool) throws {
    guard let pending = drain.pendingTask else { return }
    let done = DispatchSemaphore(value: 0)
    Task {
      await pending.value
      done.signal()
    }
    // Polled, not a bare `wait()`. The abandoned task is a model download that
    // cannot be interrupted, so this can sit for minutes; the parameter was
    // already here and simply never read, which meant a user who pressed Cancel
    // got nothing at all -- the panel stayed on an indeterminate "preparing"
    // for the rest of a download they had already given up on.
    while done.wait(timeout: .now() + 0.1) == .timedOut {
      if isCancelled() {
        // Leave the drain in place: the old task still owns the engine, and
        // the next job must wait for it rather than race it.
        throw TranscriptionError.cancelled
      }
    }
    // The drain clears its own claim, but that clear is queued BEHIND this
    // block on the same serial queue, so it cannot land until this job is over.
    // Releasing it here keeps `isEngineBusy` honest for the rest of the run.
    drain.clear()
  }

  /// Decode is roughly this fraction of the wall clock on a typical recording.
  /// Only used to keep the bar honest during decode; the rest is real.
  private let decodeProgressShare = 0.1

  private func runTranscription(
    samples: [Float],
    options: TranscriptionOptions,
    progress: @escaping (TranscriptionProgress) -> Void,
    isCancelled: @escaping () -> Bool
  ) throws -> [TranscribedSegment] {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<[TranscribedSegment], Error> = .failure(TranscriptionError.cancelled)

    let work = Task { [self] in
      do {
        let pipeline = try await loadedPipeline(
          report: { fraction, phase in
            switch phase {
            case .downloadingModel: progress(.downloadingModel(fraction))
            case .preparing: progress(.preparing())
            }
          },
          isCancelled: isCancelled)
        // Poll rather than KVO: WhisperKit REASSIGNS its `progress` property on
        // completion and on cancellation, so an observer registered on the
        // original object silently stops firing. Polling is what Argmax's own
        // CLI does.
        let poller = Task { [weak pipeline] in
          while !Task.isCancelled {
            if let fraction = pipeline?.progress.fractionCompleted, fraction > 0 {
              let scaled = decodeProgressShare + (fraction * (1.0 - decodeProgressShare))
              progress(.transcribing(min(scaled, 0.999)))
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

    // Task cancellation reaches the transcription loop quickly — WhisperKit
    // checks `Task.checkCancellation()` three times per 30s window plus once in
    // the decode loop. It does NOT reach a model download: `HubApi.snapshot`
    // never checks it, so a first-run cancel can leave this task running for as
    // long as the download takes.
    //
    // So the user is not made to wait for it. Cancelling returns immediately
    // and the task is left to unwind; the next job waits for it in
    // `awaitDrain()` rather than touching a `WhisperKit` it is still using.
    // Blocking here for ten seconds — which is what this did — is exactly the
    // "pressed stop and nothing happened" the logs showed.
    while semaphore.wait(timeout: .now() + 0.1) == .timedOut {
      if isCancelled() {
        work.cancel()
        // `claim` is what makes this recoverable. Nothing else observes an
        // abandoned task: the `drain.clear()` below is never reached (we throw),
        // and `awaitDrain` only runs when a LATER job arrives — so one cancel
        // used to leave `isEngineBusy` true for the rest of the session, which
        // is what made Settings › Storage refuse to delete the 730 MB model and
        // call it "in use" with nothing running.
        drain.claim(work)
        throw TranscriptionError.cancelled
      }
    }
    drain.clear()

    progress(.transcribing(1.0))
    return try result.get()
  }

  /// Where `WhisperKit.download` puts this variant once it has run.
  /// Exposed for tests: the download-skip decision is the whole bug.
  var localModelFolder: URL {
    modelDirectory
      .appendingPathComponent("models", isDirectory: true)
      .appendingPathComponent("argmaxinc", isDirectory: true)
      .appendingPathComponent("whisperkit-coreml", isDirectory: true)
      .appendingPathComponent(model, isDirectory: true)
  }

  /// The three compiled bundles `WhisperKit.loadModels` resolves, by name.
  ///
  /// Read off the resolved package, not guessed: `loadModels` calls
  /// `ModelUtilities.detectModelURL(inFolder:named:)` for exactly these, then
  /// throws `WhisperError.modelsUnavailable("Model file not found at …")` if any
  /// of them is missing. A folder that has fewer than all three is not a model
  /// this engine can load.
  private static let requiredModelBundles = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]

  /// The model already on disk, or nil.
  ///
  /// Presence is judged on EVERY compiled Core ML bundle the engine loads plus
  /// the variant's `config.json`, not on the directory and not on one file.
  ///
  /// A single `.mlmodelc` suffix match was enough to declare the model
  /// installed, which turned an interrupted first download into a permanent
  /// failure: press Stop (or drop wifi) after `AudioEncoder.mlmodelc` has landed
  /// and before the other two, and the next Generate saw one `.mlmodelc`, SKIPPED
  /// the fetch that was meant to repair it, and built the config with
  /// `download: false` — so `loadModels` threw on the missing `MelSpectrogram`
  /// every time, with nothing in the UI able to recover it. All four files come
  /// from the one `HubApi.snapshot` a complete download runs, so requiring them
  /// costs a finished install nothing.
  func existingModelFolder() -> URL? {
    let url = localModelFolder
    let fm = FileManager.default
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue
    else { return nil }
    for name in Self.requiredModelBundles {
      guard Self.compiledModelExists(inFolder: url, named: name) else { return nil }
    }
    // The variant metadata, fetched by the same snapshot as the weights, so its
    // absence means the download did not finish either.
    return fm.fileExists(atPath: url.appendingPathComponent("config.json").path) ? url : nil
  }

  /// Mirrors `ModelUtilities.detectModelURL(inFolder:named:)`: a compiled
  /// `<name>.mlmodelc`, or an uncompiled `<name>.mlpackage` whose Core ML
  /// payload is on disk.
  ///
  /// Reimplemented rather than called because that helper returns a URL whether
  /// or not anything is there — it is a path builder, not an existence check —
  /// so asking it alone would answer "installed" for an empty folder.
  private static func compiledModelExists(inFolder folder: URL, named name: String) -> Bool {
    let fm = FileManager.default
    if fm.fileExists(atPath: folder.appendingPathComponent("\(name).mlmodelc").path) {
      return true
    }
    let packagePayload = folder
      .appendingPathComponent("\(name).mlpackage")
      .appendingPathComponent("Data/com.apple.CoreML/model.mlmodel")
    return fm.fileExists(atPath: packagePayload.path)
  }

  private func loadedPipeline(
    report: @escaping (Double?, PipelinePhase) -> Void,
    isCancelled: @escaping () -> Bool
  ) async throws -> WhisperKit {
    if let pipe { return pipe }

    // Downloaded explicitly rather than letting `WhisperKit(download: true)` do
    // it internally, because only this form yields a progress fraction. The
    // model is 626 MB, so on a first run the internal path left the bar frozen
    // for minutes with nothing to say — the single worst thing this feature did.
    //
    // Same network calls either way: WhisperKit's own init calls this exact
    // function, and HubApi skips files already on disk, so a warm cache still
    // returns quickly.
    // Only fetch when it is genuinely not here. `WhisperKit.download` still
    // reaches the network on a warm cache (a HEAD per file) and, more visibly,
    // this is what puts "Downloading speech model" on screen -- so calling it
    // unconditionally told every user after the first that a 600 MB download
    // was happening when nothing was being downloaded, and made transcription
    // fail offline with the model sitting on disk.
    let folder: URL
    if let existing = existingModelFolder() {
      folder = existing
    } else {
      report(nil, .downloadingModel)
      folder = try await WhisperKit.download(
        variant: model,
        downloadBase: modelDirectory,
        progressCallback: { progress in
          // Best-effort abort. `HubApi.snapshot` never checks task
          // cancellation, so this Progress is the only handle on an in-flight
          // download. It may not be cancellable, in which case the download
          // runs to completion and is discarded — the user is not kept waiting
          // either way.
          if isCancelled() {
            progress.cancel()
            return
          }
          report(progress.fractionCompleted, .downloadingModel)
        })
      if isCancelled() { throw TranscriptionError.cancelled }
    }

    // Last look before the expensive part. The check above only guards the
    // download branch, so a cancel during a warm-cache run reached this anyway
    // and spent tens of seconds loading 626 MB for a job nobody was waiting on.
    if isCancelled() { throw TranscriptionError.cancelled }

    // Loading and Core ML specialisation. Genuinely indeterminate and not
    // interruptible, but it is tens of seconds rather than minutes.
    report(nil, .preparing)
    let config = WhisperKitConfig(
      model: model,
      // Never the default. WhisperKit's HubApi defaults downloadBase to
      // ~/Documents/huggingface, which for an unsandboxed Developer-ID app is
      // the user's real Documents folder — visible clutter in a paid app, and
      // possibly inside iCloud Drive sync.
      downloadBase: modelDirectory,
      modelFolder: folder.path,
      // Loads each model then unloads before the next, so peak memory is one
      // model rather than all three plus compilation. Costs a second load when
      // Core ML's per-chip specialisation cache is already warm, which is the
      // right trade for a 626 MB model.
      prewarm: true,
      load: true,
      // Already on disk by now; re-entering the download path would repeat the
      // filename lookup for nothing.
      download: false
    )
    let created = try await WhisperKit(config)
    pipe = created
    return created
  }

  /// What the engine is doing, for the stage the UI names.
  enum PipelinePhase {
    case downloadingModel
    case preparing
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
    // Also false by default, and that default puts Whisper's own control tokens
    // into the caption text: `SegmentSeeker` builds segment text from
    // `skipSpecialTokens ? wordTokens : decodingResult.tokens`, so leaving it
    // off yielded cues reading
    // `<|startoftranscript|><|en|><|transcribe|><|0.00|> And I was ...`.
    // Found on a first real run — it would have burned straight into the video
    // and the .srt. It also fixes the word list, which was being built from the
    // same unfiltered token stream.
    decoding.skipSpecialTokens = true
    decoding.noSpeechThreshold = Float(options.noSpeechThreshold)
    return decoding
  }

  /// Whisper control tokens, e.g. `<|startoftranscript|>`, `<|en|>`, `<|0.00|>`.
  private static let specialTokenPattern = try? NSRegularExpression(
    pattern: "<\\|[^|>]*\\|>")

  /// Removes any control token that survived the decoder, then collapses the
  /// whitespace they leave behind.
  ///
  /// Belt and braces on top of `skipSpecialTokens`. The engine's defaults have
  /// now surprised this file twice — `suppressBlank` and `skipSpecialTokens`
  /// both ship off — and a caption reading `<|startoftranscript|>` is burned
  /// into the user's video permanently. A regex is nothing next to that.
  static func stripSpecialTokens(_ text: String) -> String {
    let range = NSRange(text.startIndex..., in: text)
    let cleaned =
      specialTokenPattern?.stringByReplacingMatches(
        in: text, range: range, withTemplate: " ") ?? text
    return
      cleaned
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  static func map(_ segments: [TranscriptionSegment]) -> [TranscribedSegment] {
    segments.map { segment in
      TranscribedSegment(
        startMs: Int((segment.start * 1000).rounded()),
        endMs: Int((segment.end * 1000).rounded()),
        text: stripSpecialTokens(segment.text),
        words: (segment.words ?? []).map { word in
          TranscribedWord(
            text: stripSpecialTokens(word.word),
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

/// Tracks the engine task of a cancelled job while it unwinds.
///
/// ## Why the claim has to release itself
///
/// Nobody else is watching. The cancelling job throws immediately — that is the
/// point, the model download is not interruptible and the user must not be made
/// to wait for it — so the success path that used to clear this is never
/// reached, and the only other clear runs inside a LATER job. Cancel once and
/// never transcribe again, and the engine stayed "busy" for the rest of the
/// session: Settings › Storage refused to delete the 730 MB model and told the
/// user it was in use while nothing at all was running.
///
/// ## Why a generation number
///
/// A claim that finishes late must not release a claim made after it. Serialising
/// on the owning queue orders the writes but says nothing about which claim they
/// belong to, so each one carries a number and only clears itself.
///
/// ## Why it is a separate type
///
/// So this is testable without a 626 MB model. The bug lived in three lines
/// spread across a method that cannot run without WhisperKit, which is exactly
/// why no test caught it.
final class EngineDrain {

  /// The serial queue that owns the engine. Every write to the claim happens on
  /// it, so a release cannot interleave with a job taking the engine or with
  /// `releaseModel` handing the weights back.
  private let queue: DispatchQueue

  /// Read from the main thread by the delete path while the ASR queue writes it.
  private let lock = NSLock()
  private var pending: Task<Void, Never>?
  private var generation = 0

  init(queue: DispatchQueue) {
    self.queue = queue
  }

  /// True while an abandoned task still owns the engine.
  var isDraining: Bool {
    lock.lock()
    defer { lock.unlock() }
    return pending != nil
  }

  /// The abandoned task, for a later job that has to wait it out.
  var pendingTask: Task<Void, Never>? {
    lock.lock()
    defer { lock.unlock() }
    return pending
  }

  /// Takes ownership of an abandoned task and releases the claim when it ends.
  ///
  /// Call from `queue`.
  func claim(_ task: Task<Void, Never>) {
    lock.lock()
    generation += 1
    let mine = generation
    pending = task
    lock.unlock()

    Task { [self] in
      _ = await task.result
      queue.async { [self] in release(mine) }
    }
  }

  /// Drops the claim outright, for the caller that has already waited the task
  /// out and is holding the queue.
  func clear() {
    lock.lock()
    pending = nil
    lock.unlock()
  }

  private func release(_ generation: Int) {
    lock.lock()
    // Only if no newer job has been abandoned on top of this one.
    if generation == self.generation { pending = nil }
    lock.unlock()
  }
}
