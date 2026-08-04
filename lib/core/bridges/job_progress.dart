import 'package:flutter/foundation.dart';

/// Which long-running native job a progress tick belongs to.
///
/// Wire values, not display text — Flutter localises. An unrecognised value
/// degrades to [unknown] rather than throwing, so an older Flutter against a
/// newer native binary keeps showing a bar instead of crashing.
enum ProgressJob {
  export('export'),
  captions('captions'),
  unknown('unknown');

  const ProgressJob(this.wireValue);
  final String wireValue;

  static ProgressJob fromWire(String? value) {
    for (final job in ProgressJob.values) {
      if (job.wireValue == value) return job;
    }
    return ProgressJob.unknown;
  }
}

/// Which phase of a job is running.
///
/// The reason this exists at all: a bare fraction cannot distinguish "still
/// decoding audio" from "actually transcribing", so a bar that sits near zero
/// for a minute is indistinguishable from a hang. Naming the stage lets the UI
/// say what it is waiting for.
enum ProgressStage {
  /// Setting up — resolving inputs, loading a model, compiling shaders.
  preparing('preparing'),

  /// Speech-to-text.
  transcribing('transcribing'),

  /// Rendering video frames.
  rendering('rendering'),

  /// Muxing, transcoding, writing the final file.
  finalizing('finalizing'),

  unknown('unknown');

  const ProgressStage(this.wireValue);
  final String wireValue;

  static ProgressStage fromWire(String? value) {
    for (final stage in ProgressStage.values) {
      if (stage.wireValue == value) return stage;
    }
    return ProgressStage.unknown;
  }
}

/// One progress tick from a long-running native job.
///
/// ## Why this replaced a bare double
///
/// `updateExportProgress` used to carry a naked `double` and nothing else, so
/// there was exactly one job in the world and one anonymous phase. Transcription
/// needs to report alongside export, needs to say which phase it is in, and
/// needs to be cancellable — none of which a lone number can express.
///
/// ## The contract, which two native runtimes implement
///
/// ```
///   { "job":      "export" | "captions",
///     "stage":    "preparing" | "transcribing" | "rendering" | "finalizing",
///     "fraction":  0.0...1.0        // ABSENT means indeterminate
///   }
/// ```
///
/// `fraction` being absent rather than null-or-zero is deliberate: zero is a
/// real value meaning "just started", and conflating it with "no idea" is how a
/// determinate bar gets stuck at 0% forever.
@immutable
class JobProgress {
  const JobProgress({
    required this.job,
    this.stage = ProgressStage.unknown,
    this.fraction,
  });

  final ProgressJob job;
  final ProgressStage stage;

  /// 0...1, or `null` when the job cannot say — which the UI shows as an
  /// indeterminate spinner rather than a stalled bar.
  final double? fraction;

  bool get isIndeterminate => fraction == null;

  /// Parses a native tick.
  ///
  /// Tolerates a bare `double` as well as the map. Not for backward
  /// compatibility — both runtimes send the map as of this change — but because
  /// the alternative when something unexpected arrives is a progress bar that
  /// silently never moves, and a frozen-looking export is the worst possible
  /// failure mode for a feature the user is already waiting on.
  static JobProgress? fromNative(Object? arguments) {
    if (arguments is num) {
      return JobProgress(
        job: ProgressJob.export,
        stage: ProgressStage.rendering,
        fraction: _normalize(arguments.toDouble()),
      );
    }
    if (arguments is! Map) return null;

    final rawFraction = arguments['fraction'];
    return JobProgress(
      job: ProgressJob.fromWire(arguments['job'] as String?),
      stage: ProgressStage.fromWire(arguments['stage'] as String?),
      fraction: rawFraction is num ? _normalize(rawFraction.toDouble()) : null,
    );
  }

  /// Native has historically sent both 0-1 and 0-100 on this channel, so the
  /// tolerance is kept rather than tightened — a bar that reads 100% when it
  /// means 1% is a support ticket, and the check costs nothing.
  static double? _normalize(double value) {
    if (!value.isFinite || value.isNaN || value < 0) return null;
    final scaled = value > 1.0 ? value / 100.0 : value;
    return scaled.clamp(0.0, 1.0).toDouble();
  }

  @override
  bool operator ==(Object other) =>
      other is JobProgress &&
      other.job == job &&
      other.stage == stage &&
      other.fraction == fraction;

  @override
  int get hashCode => Object.hash(job, stage, fraction);

  @override
  String toString() =>
      'JobProgress(${job.wireValue}/${stage.wireValue}: '
      '${fraction == null ? "indeterminate" : fraction!.toStringAsFixed(3)})';
}
