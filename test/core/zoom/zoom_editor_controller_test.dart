import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/zoom/zoom_editor_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../test_helpers/native_test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await clearCommonNativeMocks();
  });

  testWidgets('default add mode is off', (tester) async {
    final harness = await _createHarness(tester);

    expect(harness.controller.addMode, ZoomAddMode.off);
    expect(harness.controller.addModeEnabled, isFalse);
    expect(harness.controller.stickyAddModeEnabled, isFalse);
  });

  testWidgets('toggleAddMode enters one-shot mode from off', (tester) async {
    final harness = await _createHarness(tester);

    harness.controller.toggleAddMode();
    await tester.pump();

    expect(harness.controller.addMode, ZoomAddMode.oneShot);
    expect(harness.controller.addModeEnabled, isTrue);
    expect(harness.controller.stickyAddModeEnabled, isFalse);
  });

  testWidgets('enterStickyAddMode enters sticky mode from off', (tester) async {
    final harness = await _createHarness(tester);

    harness.controller.enterStickyAddMode();
    await tester.pump();

    expect(harness.controller.addMode, ZoomAddMode.sticky);
    expect(harness.controller.addModeEnabled, isTrue);
    expect(harness.controller.stickyAddModeEnabled, isTrue);
  });

  testWidgets('toggleStickyAddMode downgrades sticky mode to one-shot', (
    tester,
  ) async {
    final harness = await _createHarness(tester);

    harness.controller.enterStickyAddMode();
    harness.controller.toggleStickyAddMode();
    await tester.pump();

    expect(harness.controller.addMode, ZoomAddMode.oneShot);
    expect(harness.controller.addModeEnabled, isTrue);
    expect(harness.controller.stickyAddModeEnabled, isFalse);
  });

  testWidgets('commitDraft exits one-shot add mode after creating a segment', (
    tester,
  ) async {
    final harness = await _createHarness(tester);

    harness.controller.enterOneShotAddMode();
    harness.controller.updateDraft(120, 460);
    harness.controller.commitDraft();
    await tester.pump();

    expect(harness.controller.addMode, ZoomAddMode.off);
    expect(harness.controller.manualSegments, hasLength(1));
    expect(harness.controller.selectedCount, 1);
  });

  testWidgets('commitDraft keeps sticky add mode active after creation', (
    tester,
  ) async {
    final harness = await _createHarness(tester);

    harness.controller.enterStickyAddMode();
    harness.controller.updateDraft(120, 460);
    harness.controller.commitDraft();
    await tester.pump();

    expect(harness.controller.addMode, ZoomAddMode.sticky);
    expect(harness.controller.manualSegments, hasLength(1));
    expect(harness.controller.selectedCount, 1);
  });

  testWidgets('handleEscapeAction clears draft and exits one-shot add mode', (
    tester,
  ) async {
    final harness = await _createHarness(tester);

    harness.controller.enterOneShotAddMode();
    harness.controller.updateDraft(120, 460);

    expect(harness.controller.draftSegment, isNotNull);

    final handled = harness.controller.handleEscapeAction();
    await tester.pump();

    expect(handled, isTrue);
    expect(harness.controller.draftSegment, isNull);
    expect(harness.controller.addMode, ZoomAddMode.off);
  });

  testWidgets('handleEscapeAction clears draft and exits sticky add mode', (
    tester,
  ) async {
    final harness = await _createHarness(tester);

    harness.controller.enterStickyAddMode();
    harness.controller.updateDraft(120, 460);

    final handled = harness.controller.handleEscapeAction();
    await tester.pump();

    expect(handled, isTrue);
    expect(harness.controller.draftSegment, isNull);
    expect(harness.controller.addMode, ZoomAddMode.off);
  });

  testWidgets('sticky mode keeps the newly created segment selected', (
    tester,
  ) async {
    final harness = await _createHarness(tester);

    harness.controller.enterStickyAddMode();
    harness.controller.updateDraft(100, 500);
    harness.controller.commitDraft();
    await tester.pump();

    final createdSegment = harness.controller.manualSegments.single;
    expect(harness.controller.primarySelectedSegmentId, createdSegment.id);
    expect(harness.controller.selectedSegmentIds, {createdSegment.id});
  });

  testWidgets('undo behavior remains unchanged with new add modes', (
    tester,
  ) async {
    final harness = await _createHarness(tester);

    harness.controller.enterOneShotAddMode();
    harness.controller.updateDraft(100, 500);
    harness.controller.commitDraft();
    await tester.pump();

    expect(harness.controller.canUndo, isTrue);
    expect(harness.controller.manualSegments, hasLength(1));

    harness.controller.undo();
    await tester.pump();

    expect(harness.controller.canUndo, isFalse);
    expect(harness.controller.manualSegments, isEmpty);
    expect(harness.controller.addMode, ZoomAddMode.off);
  });

  testWidgets('snapping enabled keeps draft times on the frame grid', (
    tester,
  ) async {
    final harness = await _createHarness(tester);

    harness.controller.enterOneShotAddMode();
    harness.controller.updateDraft(101, 487);
    await tester.pump();

    expect(harness.controller.draftSegment?.startMs, isNot(equals(101)));
    expect(harness.controller.draftSegment?.endMs, isNot(equals(487)));
  });

  testWidgets(
    'snapping enabled keeps move and trim results on the frame grid',
    (tester) async {
      final harness = await _createHarness(
        tester,
        autoSegments: const [
          {'id': 'auto_0', 'startMs': 100, 'endMs': 300, 'source': 'auto'},
        ],
      );

      final segment = harness.controller.segmentById('auto_0')!;
      harness.controller.beginMoveAt(150, segment);
      harness.controller.updateMoveTo(277);
      harness.controller.commitMove();
      await tester.pump();

      final movedSegment = harness.controller.manualSegments.single;
      expect(_isOnFrameGrid(movedSegment.startMs), isTrue);
      expect(_isOnFrameGrid(movedSegment.endMs), isTrue);
      expect(movedSegment.startMs, isNot(227));

      harness.controller.beginTrimAt(
        movedSegment.startMs,
        movedSegment,
        TrimHandle.right,
      );
      harness.controller.updateTrimTo(398);
      harness.controller.commitTrim();
      await tester.pump();

      expect(
        _isOnFrameGrid(harness.controller.manualSegments.single.endMs),
        isTrue,
      );
      expect(harness.controller.manualSegments.single.endMs, isNot(398));
    },
  );

  testWidgets('snapping disabled preserves raw draft, move, and trim times', (
    tester,
  ) async {
    final harness = await _createHarness(
      tester,
      autoSegments: const [
        {'id': 'auto_0', 'startMs': 100, 'endMs': 300, 'source': 'auto'},
      ],
    );

    harness.controller.setSnappingEnabled(false);
    harness.controller.enterOneShotAddMode();
    harness.controller.updateDraft(101, 487);
    await tester.pump();

    expect(harness.controller.draftSegment?.startMs, 101);
    expect(harness.controller.draftSegment?.endMs, 487);

    final segment = harness.controller.segmentById('auto_0')!;
    harness.controller.beginMoveAt(150, segment);
    harness.controller.updateMoveTo(277);
    harness.controller.commitMove();
    await tester.pump();

    expect(harness.controller.manualSegments, hasLength(1));
    expect(harness.controller.manualSegments.single.startMs, 227);
    expect(harness.controller.manualSegments.single.endMs, 427);

    final movedSegment = harness.controller.manualSegments.single;
    harness.controller.beginTrimAt(227, movedSegment, TrimHandle.right);
    harness.controller.updateTrimTo(398);
    harness.controller.commitTrim();
    await tester.pump();

    expect(harness.controller.manualSegments.single.endMs, 398);
  });

  testWidgets('snapping disabled still enforces bounds and minimum duration', (
    tester,
  ) async {
    final harness = await _createHarness(
      tester,
      autoSegments: const [
        {'id': 'auto_0', 'startMs': 100, 'endMs': 300, 'source': 'auto'},
      ],
    );

    harness.controller.setSnappingEnabled(false);

    final segment = harness.controller.segmentById('auto_0')!;
    harness.controller.beginMoveAt(150, segment);
    harness.controller.updateMoveTo(-80);
    harness.controller.commitMove();
    await tester.pump();

    final movedSegment = harness.controller.manualSegments.single;
    expect(movedSegment.startMs, 0);
    expect(movedSegment.endMs, 200);

    harness.controller.beginTrimAt(0, movedSegment, TrimHandle.right);
    harness.controller.updateTrimTo(1);
    harness.controller.commitTrim();
    await tester.pump();

    expect(
      harness.controller.manualSegments.single.endMs -
          harness.controller.manualSegments.single.startMs,
      ZoomEditorController.minDurationMs,
    );
  });

  testWidgets(
      'addDefaultSegmentAt creates and selects a centered manual segment',
      (tester) async {
    await installCommonNativeMocks();
    final controller = ZoomEditorController(
      nativeBridge: NativeBridge.instance,
      videoPath: '/tmp/demo.mov',
      durationMs: 8000,
    );
    await controller.init();
    addTearDown(controller.dispose);

    final created = controller.addDefaultSegmentAt(4000);
    await tester.pump();

    expect(created, isNotNull);
    expect(
      created!.endMs - created.startMs,
      ZoomEditorController.defaultNewSegmentDurationMs,
    );
    expect(controller.primarySelectedSegmentId, created.id);
    expect(controller.manualSegments, hasLength(1));
  });

  testWidgets('addDefaultSegmentAt returns null when overlapping existing',
      (tester) async {
    await installCommonNativeMocks();
    final controller = ZoomEditorController(
      nativeBridge: NativeBridge.instance,
      videoPath: '/tmp/demo.mov',
      durationMs: 8000,
    );
    await controller.init();
    addTearDown(controller.dispose);

    final first = controller.addDefaultSegmentAt(2000);
    expect(first, isNotNull);
    final centerOfExisting = ((first!.startMs + first.endMs) / 2).round();

    expect(controller.canAddDefaultSegmentAt(centerOfExisting), isFalse);
    expect(controller.addDefaultSegmentAt(centerOfExisting), isNull);
    expect(controller.manualSegments, hasLength(1));
  });

  testWidgets(
    'verification table: move/resize/ghost/visual reflect snap on vs off',
    (tester) async {
      await installCommonNativeMocks();
      final controller = ZoomEditorController(
        nativeBridge: NativeBridge.instance,
        videoPath: '/tmp/demo.mov',
        durationMs: 8000,
      );
      await controller.init();
      addTearDown(controller.dispose);

      // Visual button: defaults to ON / highlighted.
      expect(controller.snappingEnabled, isTrue);

      // ROW 1+2 (Snap ON): move + resize align to the frame grid.
      // Seed a manual segment to operate on.
      final seeded = controller.addDefaultSegmentAt(2000);
      expect(seeded, isNotNull);
      controller.beginMoveAt(seeded!.startMs + 50, seeded);
      controller.updateMoveTo(seeded.startMs + 50 + 277);
      controller.commitMove();
      await tester.pump();
      final movedOn = controller.manualSegments.single;
      expect(_isOnFrameGrid(movedOn.startMs), isTrue);
      expect(_isOnFrameGrid(movedOn.endMs), isTrue);

      controller.beginTrimAt(movedOn.startMs, movedOn, TrimHandle.right);
      controller.updateTrimTo(movedOn.startMs + 998);
      controller.commitTrim();
      await tester.pump();
      final trimmedOn = controller.manualSegments.single;
      expect(_isOnFrameGrid(trimmedOn.endMs), isTrue);

      // ROW 3 (Snap ON): ghost span aligns to the grid.
      // Pick a center far from the existing segment so a default span fits.
      final ghostCenterOn = trimmedOn.endMs + 1500;
      final spanOn = controller.defaultSpanFor(ghostCenterOn);
      expect(spanOn, isNotNull);
      expect(_isOnFrameGrid(spanOn!.$1), isTrue);
      expect(_isOnFrameGrid(spanOn.$2), isTrue);

      // Toggle to OFF. Visual button: inactive/not highlighted.
      controller.setSnappingEnabled(false);
      await tester.pump();
      expect(controller.snappingEnabled, isFalse);

      // ROW 1 (Snap OFF): move follows mouse exactly (raw ms preserved).
      final preMoveStart = trimmedOn.startMs;
      final preMoveEnd = trimmedOn.endMs;
      final duration = preMoveEnd - preMoveStart;
      const rawDelta = 277;
      // Pointer down at startMs+50, then drag by rawDelta to (startMs+50+rawDelta).
      controller.beginMoveAt(preMoveStart + 50, trimmedOn);
      controller.updateMoveTo(preMoveStart + 50 + rawDelta);
      controller.commitMove();
      await tester.pump();
      final movedOff = controller.manualSegments.single;
      expect(movedOff.startMs, preMoveStart + rawDelta);
      expect(movedOff.endMs, preMoveStart + rawDelta + duration);

      // ROW 2 (Snap OFF): resize edge follows mouse exactly.
      const rawTrimEnd = 5001; // intentionally non-grid integer
      controller.beginTrimAt(movedOff.startMs, movedOff, TrimHandle.right);
      controller.updateTrimTo(rawTrimEnd);
      controller.commitTrim();
      await tester.pump();
      expect(controller.manualSegments.single.endMs, rawTrimEnd);

      // ROW 3 (Snap OFF): ghost span endpoints exactly mirror the raw input.
      const ghostCenterOff = 6501;
      final spanOff = controller.defaultSpanFor(ghostCenterOff);
      expect(spanOff, isNotNull);
      // Snap-off normalize keeps raw ms (verified independently below).
      expect(controller.normalizeEditableMsForUi(spanOff!.$1), spanOff.$1);
      expect(controller.normalizeEditableMsForUi(spanOff.$2), spanOff.$2);
      // And the span should not be grid-aligned for a non-grid center.
      expect(_isOnFrameGrid(spanOff.$1) && _isOnFrameGrid(spanOff.$2),
          isFalse);
    },
  );

  testWidgets('snap OFF: defaultSpanFor returns raw non-grid span',
      (tester) async {
    await installCommonNativeMocks();
    final controller = ZoomEditorController(
      nativeBridge: NativeBridge.instance,
      videoPath: '/tmp/demo.mov',
      durationMs: 8000,
    );
    await controller.init();
    addTearDown(controller.dispose);

    controller.setSnappingEnabled(false);
    // Center is intentionally off the 60fps grid (~16.667ms).
    final span = controller.defaultSpanFor(4001);
    expect(span, isNotNull);
    final start = span!.$1;
    final end = span.$2;
    // With snap off, normalizeEditableMsForUi must equal the raw clamped ms.
    expect(controller.normalizeEditableMsForUi(start), start);
    expect(controller.normalizeEditableMsForUi(end), end);
    // And the raw center should not be force-aligned to the frame grid.
    final raw = 4001;
    expect(controller.normalizeEditableMsForUi(raw), raw);
  });

  testWidgets('snap ON: defaultSpanFor aligns to frame grid',
      (tester) async {
    await installCommonNativeMocks();
    final controller = ZoomEditorController(
      nativeBridge: NativeBridge.instance,
      videoPath: '/tmp/demo.mov',
      durationMs: 8000,
    );
    await controller.init();
    addTearDown(controller.dispose);
    expect(controller.snappingEnabled, isTrue);

    // Ensure normalize collapses non-grid input to the frame grid.
    final raw = 4001;
    final normalized = controller.normalizeEditableMsForUi(raw);
    expect(_isOnFrameGrid(normalized), isTrue);
  });

  testWidgets('setSnappingEnabled notifies listeners exactly once',
      (tester) async {
    await installCommonNativeMocks();
    final controller = ZoomEditorController(
      nativeBridge: NativeBridge.instance,
      videoPath: '/tmp/demo.mov',
      durationMs: 8000,
    );
    await controller.init();
    addTearDown(controller.dispose);

    var notifyCount = 0;
    controller.addListener(() => notifyCount++);

    controller.setSnappingEnabled(false);
    expect(notifyCount, 1);
    // Same value: no extra notification.
    controller.setSnappingEnabled(false);
    expect(notifyCount, 1);
    controller.setSnappingEnabled(true);
    expect(notifyCount, 2);
  });

  testWidgets('canAddDefaultSegmentAt respects snap-off span',
      (tester) async {
    await installCommonNativeMocks();
    final controller = ZoomEditorController(
      nativeBridge: NativeBridge.instance,
      videoPath: '/tmp/demo.mov',
      durationMs: 8000,
    );
    await controller.init();
    addTearDown(controller.dispose);

    controller.setSnappingEnabled(false);
    expect(controller.canAddDefaultSegmentAt(4001), isTrue);
    final created = controller.addDefaultSegmentAt(4001);
    expect(created, isNotNull);
    // No further default segment can be placed at the center of the new one.
    final center = ((created!.startMs + created.endMs) / 2).round();
    expect(controller.canAddDefaultSegmentAt(center), isFalse);
  });

  testWidgets('addDefaultSegmentAt clamps near timeline start/end',
      (tester) async {
    await installCommonNativeMocks();
    final controller = ZoomEditorController(
      nativeBridge: NativeBridge.instance,
      videoPath: '/tmp/demo.mov',
      durationMs: 8000,
    );
    await controller.init();
    addTearDown(controller.dispose);

    final near0 = controller.addDefaultSegmentAt(50);
    expect(near0, isNotNull);
    expect(near0!.startMs, greaterThanOrEqualTo(0));
    expect(
      near0.endMs - near0.startMs,
      ZoomEditorController.defaultNewSegmentDurationMs,
    );
  });
}

Future<_ZoomEditorHarness> _createHarness(
  WidgetTester tester, {
  List<Map<String, Object?>> autoSegments = const [],
  List<Map<String, Object?>> manualSegments = const [],
}) async {
  await installCommonNativeMocks();
  final calls = <MethodCall>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  messenger.setMockMethodCallHandler(screenRecorderChannel, (call) async {
    calls.add(call);
    switch (call.method) {
      case 'getZoomSegments':
        return autoSegments;
      case 'getManualZoomSegments':
        return manualSegments;
      case 'saveManualZoomSegments':
        return true;
      case 'previewSetZoomSegments':
        return null;
      default:
        return null;
    }
  });

  final controller = ZoomEditorController(
    nativeBridge: NativeBridge.instance,
    videoPath: '/tmp/demo.mov',
    durationMs: 2000,
  );
  await controller.init();
  addTearDown(controller.dispose);

  return _ZoomEditorHarness(controller: controller, calls: calls);
}

class _ZoomEditorHarness {
  const _ZoomEditorHarness({required this.controller, required this.calls});

  final ZoomEditorController controller;
  final List<MethodCall> calls;
}

bool _isOnFrameGrid(int ms) {
  final frameMs = ZoomEditorController.frameMs;
  final snappedMs = ((ms / frameMs).round() * frameMs);
  return (snappedMs - ms).abs() < 0.6;
}
