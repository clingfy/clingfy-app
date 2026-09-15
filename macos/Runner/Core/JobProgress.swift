import Foundation

/// One progress tick from a long-running native job, in the shape the Dart side
/// parses.
///
/// ## Why this replaced a bare double
///
/// `updateExportProgress` carried a naked `Double` and nothing else, which
/// assumed exactly one job in the world and one anonymous phase. Transcription
/// reports alongside export, has phases that take very different amounts of
/// time, and is cancellable — none of which a lone number expresses. A bar
/// sitting near zero while audio decodes is indistinguishable from a hang.
///
/// ## The contract
///
/// ```
///   { "job":      "export" | "captions",
///     "stage":    "preparing" | "transcribing" | "rendering" | "finalizing",
///     "fraction":  0.0...1.0        // OMITTED means indeterminate
///   }
/// ```
///
/// Keep in sync with `lib/core/bridges/job_progress.dart` and with
/// `windows/runner/Bridge/export_progress_publisher.cpp`. Three implementations
/// of one shape; the Dart side pins the wire strings by test.
///
/// `fraction` is omitted rather than sent as null or zero when unknown. Zero is
/// a real value meaning "just started", and conflating the two is how a
/// determinate bar gets stuck at 0% forever.
struct JobProgress {

  enum Job: String {
    case export
    case captions
  }

  enum Stage: String {
    /// Resolving inputs, loading a model, compiling shaders.
    case preparing
    /// Fetching the speech model over the network. Its own stage because it is
    /// the one phase that can take minutes on a first run, reports a real
    /// fraction, and is worth naming — "Preparing" pinned for four minutes
    /// reads as a hang.
    case downloadingModel
    case transcribing
    case rendering
    /// Muxing, transcoding, writing the final file.
    case finalizing
  }

  let job: Job
  let stage: Stage
  /// `nil` when the job genuinely cannot say. Shown as a spinner, not a bar.
  let fraction: Double?

  func toFlutter() -> [String: Any] {
    var payload: [String: Any] = [
      "job": job.rawValue,
      "stage": stage.rawValue,
    ]
    if let fraction, fraction.isFinite, !fraction.isNaN {
      payload["fraction"] = min(max(fraction, 0.0), 1.0)
    }
    return payload
  }

  static func export(_ fraction: Double?, stage: Stage = .rendering) -> JobProgress {
    JobProgress(job: .export, stage: stage, fraction: fraction)
  }

  static func captions(_ fraction: Double?, stage: Stage) -> JobProgress {
    JobProgress(job: .captions, stage: stage, fraction: fraction)
  }
}
