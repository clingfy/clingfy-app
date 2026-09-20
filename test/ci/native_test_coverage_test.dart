import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every `XCTestCase` in `macos/RunnerTests/` is either run by CI or listed
/// here as knowingly not run.
///
/// The macOS lanes select tests with an explicit `-only-testing:` allowlist.
/// `ci.yml` names that trade-off itself:
///
/// > An allowlist has the same failure mode as the selector it replaced, one
/// > class at a time: a NEW class is dead in CI until someone adds it here,
/// > and nothing fails to say so.
///
/// This is the "something that says so". It runs no Swift — it compares two
/// text files — so it rides the Flutter lane on any platform, including a
/// Windows dev box where the native suite cannot be built at all.
///
/// Adding a test class and forgetting the CI entry now fails here, with the
/// class named. The fix is one of two lines: add `-only-testing:` to
/// `ci.yml`, or add the class to [knowinglyNotRunInCi] with a reason. Neither
/// is automatic, which is the point — landing in the uncovered list should be
/// a decision, not a default.
void main() {
  test('every RunnerTests class is run by CI or listed as not run', () {
    final classes = _testClassNames();
    final covered = _classesSelectedInCi();

    expect(
      classes,
      isNotEmpty,
      reason: 'found no XCTestCase classes - the parse broke, not the repo',
    );
    expect(
      covered,
      isNotEmpty,
      reason: 'found no -only-testing entries - the parse broke, not the repo',
    );

    final unaccounted =
        classes.difference(covered).difference(knowinglyNotRunInCi).toList()
          ..sort();

    expect(
      unaccounted,
      isEmpty,
      reason:
          'These RunnerTests classes are neither selected in '
          '.github/workflows/ci.yml nor listed in knowinglyNotRunInCi, so they '
          'never run and nothing says so. Add a '
          '`-only-testing:RunnerTests/<name>` line to ci.yml, or add the name '
          'to knowinglyNotRunInCi with the reason it stays out.',
    );
  });

  test('nothing in the not-run list is actually run', () {
    // Honest in the other direction too: a class that HAS been wired into CI
    // should not still sit here claiming it is not.
    final covered = _classesSelectedInCi();
    final stale = knowinglyNotRunInCi.intersection(covered).toList()..sort();

    expect(
      stale,
      isEmpty,
      reason:
          'Selected in ci.yml but still listed as knowingly not run. Remove '
          'them from knowinglyNotRunInCi.',
    );
  });

  test('nothing in the not-run list has been deleted', () {
    final classes = _testClassNames();
    final ghosts = knowinglyNotRunInCi.difference(classes).toList()..sort();

    expect(
      ghosts,
      isEmpty,
      reason:
          'Listed as knowingly not run but no longer present in '
          'macos/RunnerTests/. Remove them from knowinglyNotRunInCi.',
    );
  });
}

/// Classes that do not run in CI today, recorded deliberately.
///
/// A debt ledger, not an allowlist to grow. `ci.yml` says why it has not been
/// emptied: adding the rest is worth doing, but several have never run in CI
/// and would need triaging first.
///
/// One entry is deliberate rather than untriaged: `CaptionBurnInProofTests`
/// composites a burned-in `.mov` for a human to look at, from bitmaps a
/// Flutter test writes to `/tmp` - absent on a runner, so it skips there and
/// can never fail.
const Set<String> knowinglyNotRunInCi = <String>{
  'AppWindowWatcherTests',
  'AudioHardwareListenerTests',
  'AudioLevelEstimatorTests',
  'AudioSourceRecordingTests',
  'CameraCoordinationControllerTests',
  'CanvasBackgroundRendererTests',
  'CanvasBackgroundTests',
  'CaptionBurnInProofTests',
  'CaptureBackendBinderTests',
  'CaptureStartConfigBuilderTests',
  'CaptureTargetResolverTests',
  'CleanedMicCacheTests',
  'ColorGradeValidatorMarginTests',
  'CursorHighlightCoordinatorTests',
  'DeviceChangeFanOutTests',
  'InlinePreviewRehydrationStateTests',
  'InlinePreviewViewLifecycleTests',
  'MetadataSidecarWriterTests',
  'MicEchoCancellerTests',
  'OverlayVisibilityControllerTests',
  'PermissionsMethodRouterTests',
  'PreRecordingBarWarningTests',
  'PreviewEngineTests',
  'PreviewSceneRequestParsingTests',
  'RecordingEngineTests',
  'RecordingFinalizerTests',
  'RecordingIndicatorCoordinatorTests',
  'RecordingPreflightServiceTests',
  'RecordingProjectServiceTests',
  'RecordingSessionCoordinatorTests',
  'RecordingSessionStateTests',
  'RecordingStateMachineTests',
  'ScreenRecorderEventBridgeTests',
  'StartRecordingContextTests',
  'StartRecordingRequestParsingTests',
  'TrailingDebouncerTests',
  'ZoomFocusModeTests',
  'ZoomQueryServiceTests',
};

Set<String> _testClassNames() {
  final dir = Directory('macos/RunnerTests');
  if (!dir.existsSync()) return <String>{};
  final pattern = RegExp(r'class\s+([A-Za-z0-9_]+)\s*:\s*XCTestCase');
  final names = <String>{};
  for (final entity in dir.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.swift')) continue;
    for (final match in pattern.allMatches(entity.readAsStringSync())) {
      names.add(match.group(1)!);
    }
  }
  return names;
}

Set<String> _classesSelectedInCi() {
  final file = File('.github/workflows/ci.yml');
  if (!file.existsSync()) return <String>{};
  final pattern = RegExp(r'-only-testing:RunnerTests/([A-Za-z0-9_]+)');
  return <String>{
    for (final line in file.readAsLinesSync())
      // Skip commented-out selectors so a disabled line does not read as
      // coverage.
      if (!line.trimLeft().startsWith('#'))
        for (final match in pattern.allMatches(line)) match.group(1)!,
  };
}
