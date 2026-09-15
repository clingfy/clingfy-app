import Foundation

/// The speech-to-text seam.
///
/// Everything above this protocol — job orchestration, source selection, the
/// bleed dedup, progress, cancellation, cue emission — is engine-agnostic and
/// unit-testable with a fake. WhisperKit sits behind it as one implementation.
///
/// That split is deliberate. WhisperKit is an SPM dependency that forces the
/// whole app's deployment target up, so it must not be load-bearing for the
/// logic around it, and the logic around it must be testable without a 600 MB
/// model download in CI.
protocol CaptionTranscriber {
  /// Whether this engine can run on the current machine, and why not if it
  /// cannot. Checked before a job starts so the UI can explain itself rather
  /// than offering a button that fails.
  var availability: TranscriberAvailability { get }

  /// Transcribes one audio file.
  ///
  /// - Parameters:
  ///   - url: the audio to transcribe. Implementations must handle whatever
  ///     the recorder produced: the mic sidecar can be 44.1 kHz mono while
  ///     system audio is 48 kHz stereo, so per-file resampling is the
  ///     implementation's job, not the caller's.
  ///   - options: thresholds and hints; see `TranscriptionOptions`.
  ///   - progress: phase plus an optional 0...1 fraction. May be called on any
  ///     queue; callers marshal. The phase matters because the model download
  ///     is the one part that can run for minutes and is worth naming — the UI
  ///     labelled everything "Preparing", so a first run looked frozen.
  ///   - isCancelled: polled during decoding. Returning `true` must abandon the
  ///     run promptly and throw `TranscriptionError.cancelled`.
  /// - Returns: segments in SOURCE time, ordered, non-overlapping.
  func transcribe(
    url: URL,
    options: TranscriptionOptions,
    progress: @escaping (TranscriptionProgress) -> Void,
    isCancelled: @escaping () -> Bool
  ) throws -> [TranscribedSegment]

  /// Whether the engine is touching its model files right now.
  ///
  /// Separate from "a job is running" because the dangerous window is wider
  /// than a job: a cancelled first-run download keeps writing into the model
  /// directory after the user has moved on, and deleting the model underneath
  /// that leaves a half-written tree the next run will happily load.
  var isEngineBusy: Bool { get }

  /// Drops the loaded model so its files can be removed.
  ///
  /// Core ML holds the weights mmapped, so removing the directory while a
  /// pipeline is alive frees no space and leaves the engine able to keep
  /// transcribing from an inode with no name — the disk stays full and the UI
  /// reports it empty.
  ///
  /// - Returns: `false` when the engine DECLINED, because something it does not
  ///   control still owns the weights (a cancelled job's abandoned task). A
  ///   caller that deletes files must treat that as a refusal: this used to
  ///   return the same nothing whether it had unloaded a pipeline or skipped
  ///   entirely, and `deleteCaptionModel` removed 730 MB on the strength of it.
  @discardableResult
  func releaseModel() async -> Bool
}

extension CaptionTranscriber {
  // Defaulted so the existing test doubles keep compiling: only the real engine
  // owns a model on disk. A double holding nothing has, trivially, released it.
  var isEngineBusy: Bool { false }
  func releaseModel() async -> Bool { true }
}

/// What a transcriber is doing, and how far in.
struct TranscriptionProgress: Equatable {
  enum Phase: Equatable {
    /// Fetching the speech model. First run only, and the only phase that can
    /// take minutes.
    case downloadingModel
    /// Decoding audio, loading the model, Core ML specialisation. Genuinely
    /// indeterminate.
    case preparing
    case transcribing
  }

  let phase: Phase
  /// `nil` when the phase cannot report one. Shown as a spinner, not a bar.
  let fraction: Double?

  static func downloadingModel(_ fraction: Double?) -> TranscriptionProgress {
    TranscriptionProgress(phase: .downloadingModel, fraction: fraction)
  }
  static func preparing() -> TranscriptionProgress {
    TranscriptionProgress(phase: .preparing, fraction: nil)
  }
  static func transcribing(_ fraction: Double) -> TranscriptionProgress {
    TranscriptionProgress(phase: .transcribing, fraction: fraction)
  }
}

enum TranscriberAvailability: Equatable {
  case available
  /// Named reason so the UI can show one specific sentence instead of a
  /// generic failure. Mirrors the `captionsCapability` bridge contract.
  case unavailable(reason: String)

  var isAvailable: Bool { self == .available }
}

/// One transcribed span, in **source** milliseconds.
///
/// Source time because the composition and every baked effect are in source
/// time; converting to edited time happens later, at the point cues are mapped
/// for the sidecar. See `CaptionCueTrack`.
struct TranscribedSegment: Equatable {
  let startMs: Int
  let endMs: Int
  let text: String

  /// Per-word timings when the engine provides them. Used by the cut-reflow
  /// rule: when a clip edit removes part of a cue's audio, the surviving words
  /// are re-emitted rather than the whole sentence being repeated over each
  /// fragment.
  let words: [TranscribedWord]

  /// Engine's confidence that this span contains no speech, 0...1 when known.
  ///
  /// The single most useful signal for suppressing hallucination. Whisper's
  /// documented failure mode is inventing text over silence and music, and a
  /// screen recording is mostly silence.
  let noSpeechProbability: Double?

  var durationMs: Int { max(0, endMs - startMs) }
}

struct TranscribedWord: Equatable {
  let text: String
  let startMs: Int
  let endMs: Int
}

/// Tuning handed to the engine. Defaults are the conservative ones.
struct TranscriptionOptions: Equatable {
  /// BCP-47-ish language hint, or `nil` to let the engine detect.
  var language: String?

  /// Segments whose `noSpeechProbability` exceeds this are dropped.
  ///
  /// Applied by `TranscriptionJob`, not the engine, so the rule is identical
  /// no matter which engine ran and is testable without one.
  var noSpeechThreshold: Double

  /// Segments whose text is shorter than this after trimming are dropped.
  /// Whisper emits stray punctuation-only segments over noise.
  var minimumCharacters: Int

  /// Segments shorter than this are dropped. A caption that flashes for
  /// 120 ms is unreadable and is almost always a decoding artefact.
  var minimumDurationMs: Int

  /// Drops a segment whose text repeats the previous segment's within
  /// `repetitionWindowMs`. Whisper's second failure mode over music is a
  /// repetition loop.
  var suppressRepeats: Bool
  var repetitionWindowMs: Int

  static let `default` = TranscriptionOptions(
    language: nil,
    noSpeechThreshold: 0.6,
    minimumCharacters: 2,
    minimumDurationMs: 200,
    suppressRepeats: true,
    repetitionWindowMs: 8000
  )

  /// Stricter variant for the SYSTEM audio track.
  ///
  /// The prior is genuinely different: a microphone track is mostly someone
  /// talking with silence between sentences, while a system track is mostly
  /// music, game audio, video soundtracks and UI chirps — continuous non-speech
  /// that looks like signal and is exactly what Whisper hallucinates over.
  static let strict = TranscriptionOptions(
    language: nil,
    noSpeechThreshold: 0.4,
    minimumCharacters: 3,
    minimumDurationMs: 400,
    suppressRepeats: true,
    repetitionWindowMs: 15000
  )
}

enum TranscriptionError: Error, Equatable {
  case cancelled
  case unavailable(reason: String)
  case noAudioTrack(URL)
  case modelUnavailable(String)
  case engine(String)
}

extension TranscriptionError {

  /// Re-expresses a decode failure in this taxonomy.
  ///
  /// `CaptionAudioDecoder` throws its own `DecodeError`, and a file AVFoundation
  /// refuses surfaces as a plain `NSError` from the reader. Neither is a
  /// `TranscriptionError` — and every layer above a transcriber decides what to
  /// show the user by asking `error as? TranscriptionError`: the service picks
  /// an info log over an error log, the bridge picks `CAPTIONS_CANCELLED` over
  /// `CAPTIONS_FAILED`, and the panel picks silence over a red notice.
  ///
  /// So a decode error that crossed the seam untranslated failed all three
  /// casts at once. Decoding runs FIRST, before any model download, which made
  /// the common case the worst one: the user pressed Stop, and got "Couldn't
  /// generate subtitles" plus a Sentry error for doing exactly what they meant.
  init(decodeFailure error: Error) {
    if let already = error as? TranscriptionError {
      self = already
      return
    }
    guard let decode = error as? CaptionAudioDecoder.DecodeError else {
      self = .engine(String(describing: error))
      return
    }
    switch decode {
    case .cancelled:
      self = .cancelled
    case .noAudioTrack(let url):
      self = .noAudioTrack(url)
    case .unreadable(let url):
      // No `unreadable` case here, and adding one would widen a taxonomy the
      // bridge already pins. The path is what makes it diagnosable.
      self = .engine("Audio could not be decoded: \(url.path)")
    }
  }

  /// Passes an error through untouched unless it is a decode failure.
  ///
  /// The net above the protocol, not below it: `transcribe(url:…)` is documented
  /// to throw `TranscriptionError`, but the decode that every implementation
  /// must do throws a different type, and one leak reports a deliberate cancel
  /// as a failure. An engine's own errors are left alone — only the known leak
  /// is translated.
  static func normalizing(_ error: Error) -> Error {
    guard error is CaptionAudioDecoder.DecodeError else { return error }
    return TranscriptionError(decodeFailure: error)
  }
}
