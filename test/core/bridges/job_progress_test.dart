import 'package:clingfy/core/bridges/job_progress.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the `updateExportProgress` payload contract.
///
/// This is a REGRESSION surface, not new ground. The method shipped for
/// releases carrying a bare `double`, three consumers read it, and the Windows
/// publisher's header documented that contract in capitals. Changing it is the
/// one non-additive bridge change in the captions work, and the failure mode is
/// silent: a wrong shape yields a progress bar that never moves, on a feature
/// the user is already waiting on.
///
/// Three runtimes implement this shape — macOS `Runner/Core/JobProgress.swift`,
/// `windows/runner/Bridge/export_progress_publisher.cpp`, and this parser — so
/// the wire strings are asserted literally.
void main() {
  group('parsing the labelled payload', () {
    test('reads what both native runtimes now send', () {
      final progress = JobProgress.fromNative({
        'job': 'export',
        'stage': 'rendering',
        'fraction': 0.42,
      });
      expect(progress, isNotNull);
      expect(progress!.job, ProgressJob.export);
      expect(progress.stage, ProgressStage.rendering);
      expect(progress.fraction, closeTo(0.42, 0.0001));
      expect(progress.isIndeterminate, isFalse);
    });

    test('reads a captions tick', () {
      final progress = JobProgress.fromNative({
        'job': 'captions',
        'stage': 'transcribing',
        'fraction': 0.1,
      });
      expect(progress!.job, ProgressJob.captions);
      expect(progress.stage, ProgressStage.transcribing);
    });

    /// Omitted, not null and not zero. Zero is a real value meaning "just
    /// started"; conflating the two is how a determinate bar sticks at 0%.
    test('an absent fraction is indeterminate, and zero is not', () {
      final absent = JobProgress.fromNative({
        'job': 'captions',
        'stage': 'preparing',
      });
      expect(absent!.isIndeterminate, isTrue);
      expect(absent.fraction, isNull);

      final zero = JobProgress.fromNative({
        'job': 'export',
        'stage': 'rendering',
        'fraction': 0.0,
      });
      expect(zero!.isIndeterminate, isFalse);
      expect(zero.fraction, 0.0);
    });

    test('unknown job and stage degrade rather than throwing', () {
      final progress = JobProgress.fromNative({
        'job': 'somethingNew',
        'stage': 'alsoNew',
        'fraction': 0.5,
      });
      expect(progress!.job, ProgressJob.unknown);
      expect(progress.stage, ProgressStage.unknown);
      expect(progress.fraction, 0.5, reason: 'the number is still usable');
    });

    test('a non-map, non-number payload yields null rather than throwing', () {
      expect(JobProgress.fromNative('nonsense'), isNull);
      expect(JobProgress.fromNative(null), isNull);
    });
  });

  group('REGRESSION: the bare double this method used to carry', () {
    /// Defensive, deliberately. Both runtimes send the map as of this change,
    /// so this path should never fire in a shipped build — but if a native
    /// binary is ever out of step with the Dart side, degrading to a working
    /// export bar beats a bar that silently never moves.
    test('a bare double is still understood as export rendering', () {
      final progress = JobProgress.fromNative(0.65);
      expect(progress, isNotNull);
      expect(progress!.job, ProgressJob.export);
      expect(progress.stage, ProgressStage.rendering);
      expect(progress.fraction, closeTo(0.65, 0.0001));
    });

    test('an int is accepted too', () {
      expect(JobProgress.fromNative(1)!.fraction, 1.0);
      expect(JobProgress.fromNative(0)!.fraction, 0.0);
    });
  });

  group('range handling', () {
    /// Native has historically sent both 0-1 and 0-100 on this channel. A bar
    /// reading 100% when it means 1% is a support ticket, and the check is free.
    test('a 0-100 value is rescaled', () {
      expect(JobProgress.fromNative(50)!.fraction, closeTo(0.5, 0.0001));
      expect(
        JobProgress.fromNative({
          'job': 'export',
          'stage': 'rendering',
          'fraction': 75,
        })!.fraction,
        closeTo(0.75, 0.0001),
      );
    });

    test('out-of-range and non-finite values do not produce a broken bar', () {
      expect(JobProgress.fromNative(-1)!.fraction, isNull);
      expect(JobProgress.fromNative(double.nan)!.fraction, isNull);
      expect(JobProgress.fromNative(double.infinity)!.fraction, isNull);
    });

    test('the fraction never leaves 0..1', () {
      final progress = JobProgress.fromNative({
        'job': 'export',
        'stage': 'rendering',
        'fraction': 400,
      });
      expect(progress!.fraction, 1.0);
    });
  });

  group('wire values are stable', () {
    /// These strings cross the bridge from two native implementations.
    /// Changing one silently freezes a progress bar — it is a breaking change,
    /// not a rename.
    test('jobs', () {
      expect(ProgressJob.export.wireValue, 'export');
      expect(ProgressJob.captions.wireValue, 'captions');
    });

    test('stages', () {
      expect(ProgressStage.preparing.wireValue, 'preparing');
      expect(ProgressStage.transcribing.wireValue, 'transcribing');
      expect(ProgressStage.rendering.wireValue, 'rendering');
      expect(ProgressStage.finalizing.wireValue, 'finalizing');
    });
  });
}
