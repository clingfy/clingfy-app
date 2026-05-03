import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/zoom/zoom_editor_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../test_helpers/native_test_setup.dart';

/// Guards a regression where `_normalizeSegments` rebuilt
/// `_effectiveSegments` (the list pushed to native via
/// `previewSetZoomSegments`) without copying `focusMode` or
/// `fixedTarget`. Native then never saw the user's fixed-target
/// intent and rendered a follow-cursor zoom (or nothing, when the
/// cursor was off-screen).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await clearCommonNativeMocks();
  });

  testWidgets(
    'fixedTarget on a manual segment survives _effectiveSegments rebuild',
    (tester) async {
      final harness = await _createHarness(tester);

      harness.controller.addDefaultSegmentAt(
        1500,
        durationMs: 1200,
        focusMode: ZoomFocusMode.fixedTarget,
        fixedTarget: const NormalizedPoint(0.25, 0.75),
      );
      await tester.pump();

      final effective = harness.controller.effectiveZoomSegments;
      expect(effective, hasLength(1));
      expect(effective.single.focusMode, ZoomFocusMode.fixedTarget);
      expect(effective.single.fixedTarget,
          const NormalizedPoint(0.25, 0.75));

      final pushed = harness.calls
          .lastWhere((c) => c.method == 'previewSetZoomSegments')
          .arguments as Map;
      final segments = (pushed['segments'] as List).cast<Map>();
      expect(segments, hasLength(1));
      expect(segments.single['focusMode'], 'fixedTarget');
      expect(segments.single['fixedTarget'], isA<Map>());
      expect((segments.single['fixedTarget'] as Map)['dx'], 0.25);
      expect((segments.single['fixedTarget'] as Map)['dy'], 0.75);
    },
  );

  testWidgets(
    'adjacent segments with different focus modes are NOT merged',
    (tester) async {
      final harness = await _createHarness(tester);

      // Two manual segments back-to-back; one followCursor, one
      // fixedTarget. The 120ms gap-merge optimization must not blend
      // them — that would erase the fixedTarget intent.
      harness.controller.addDefaultSegmentAt(
        500,
        durationMs: 600,
        focusMode: ZoomFocusMode.followCursor,
      );
      harness.controller.addDefaultSegmentAt(
        1300,
        durationMs: 600,
        focusMode: ZoomFocusMode.fixedTarget,
        fixedTarget: NormalizedPoint.center,
      );
      await tester.pump();

      final effective = harness.controller.effectiveZoomSegments;
      expect(effective.length, 2,
          reason: 'segments with different focus modes must stay separate');
      expect(effective.first.focusMode, ZoomFocusMode.followCursor);
      expect(effective.last.focusMode, ZoomFocusMode.fixedTarget);
    },
  );
}

Future<_Harness> _createHarness(WidgetTester tester) async {
  await installCommonNativeMocks();
  final calls = <MethodCall>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  messenger.setMockMethodCallHandler(screenRecorderChannel, (call) async {
    calls.add(call);
    switch (call.method) {
      case 'getZoomSegments':
        return <Map<String, Object?>>[];
      case 'getManualZoomSegments':
        return <Map<String, Object?>>[];
      case 'saveManualZoomSegments':
        return true;
      case 'previewSetZoomSegments':
        return null;
      case 'previewGetZoomCapabilities':
        return const {
          'cursorSamples': true,
          'fixedTargetPreview': true,
          'fixedTargetExport': true,
        };
      default:
        return null;
    }
  });

  final controller = ZoomEditorController(
    nativeBridge: NativeBridge.instance,
    videoPath: '/tmp/demo.mov',
    durationMs: 4000,
  );
  await controller.init();
  addTearDown(controller.dispose);
  return _Harness(controller: controller, calls: calls);
}

class _Harness {
  const _Harness({required this.controller, required this.calls});
  final ZoomEditorController controller;
  final List<MethodCall> calls;
}
