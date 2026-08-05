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
