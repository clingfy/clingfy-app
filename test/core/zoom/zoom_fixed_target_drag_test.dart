import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/zoom/zoom_editor_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../test_helpers/native_test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await clearCommonNativeMocks();
  });

  testWidgets('drag updates fixedTarget live and survives commit', (
    tester,
  ) async {
    final harness = await _createHarness(tester);

    final segment = harness.controller.addDefaultSegmentAt(
      1500,
      durationMs: 1200,
      focusMode: ZoomFocusMode.fixedTarget,
      fixedTarget: NormalizedPoint.center,
    );
    expect(segment, isNotNull);
    await tester.pump();

    harness.controller.beginFixedTargetDrag(segment!);

    harness.controller.updateFixedTargetDrag(const NormalizedPoint(0.2, 0.7));
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      harness.controller.primarySelectedSegment!.fixedTarget,
      const NormalizedPoint(0.2, 0.7),
    );
    expect(
      harness.controller.primarySelectedSegment!.focusMode,
      ZoomFocusMode.fixedTarget,
    );

    harness.controller.updateFixedTargetDrag(const NormalizedPoint(0.9, 0.1));
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      harness.controller.primarySelectedSegment!.fixedTarget,
      const NormalizedPoint(0.9, 0.1),
    );

    harness.controller.commitFixedTargetDrag();
    await tester.pump();

    final after = harness.controller.primarySelectedSegment!;
    expect(after.focusMode, ZoomFocusMode.fixedTarget);
    expect(after.fixedTarget, const NormalizedPoint(0.9, 0.1));

    final pushed =
        harness.calls
                .lastWhere((c) => c.method == 'previewSetZoomSegments')
                .arguments
            as Map;
    final segments = (pushed['segments'] as List).cast<Map>();
    expect(segments, isNotEmpty);
    final pushedTarget = segments.last['fixedTarget'] as Map?;
    expect(pushedTarget, isNotNull);
    expect(pushedTarget!['dx'], 0.9);
    expect(pushedTarget['dy'], 0.1);
  });

  testWidgets('drag clamps points outside [0,1]', (tester) async {
    final harness = await _createHarness(tester);
    final segment = harness.controller.addDefaultSegmentAt(
      1500,
      durationMs: 1200,
      focusMode: ZoomFocusMode.fixedTarget,
      fixedTarget: NormalizedPoint.center,
    )!;
    await tester.pump();

    harness.controller.beginFixedTargetDrag(segment);
    harness.controller.updateFixedTargetDrag(const NormalizedPoint(-0.5, 1.5));
    await tester.pump();

    expect(
      harness.controller.primarySelectedSegment!.fixedTarget,
      const NormalizedPoint(0.0, 1.0),
    );

    harness.controller.commitFixedTargetDrag();
    await tester.pump();
  });

  testWidgets('cancel reverts to pre-drag fixedTarget', (tester) async {
    final harness = await _createHarness(tester);
    final segment = harness.controller.addDefaultSegmentAt(
      1500,
      durationMs: 1200,
      focusMode: ZoomFocusMode.fixedTarget,
      fixedTarget: const NormalizedPoint(0.25, 0.25),
    )!;
    await tester.pump();

    harness.controller.beginFixedTargetDrag(segment);
    harness.controller.updateFixedTargetDrag(const NormalizedPoint(0.9, 0.9));
    harness.controller.cancelFixedTargetDrag();
    await tester.pump();

    expect(
      harness.controller.primarySelectedSegment!.fixedTarget,
      const NormalizedPoint(0.25, 0.25),
    );
  });

  testWidgets('non-fixedTarget segment is ignored', (tester) async {
    final harness = await _createHarness(tester);
    final segment = harness.controller.addDefaultSegmentAt(
      1500,
      durationMs: 1200,
      focusMode: ZoomFocusMode.followCursor,
    )!;
    await tester.pump();

    harness.controller.beginFixedTargetDrag(segment);
    harness.controller.updateFixedTargetDrag(const NormalizedPoint(0.1, 0.1));
    await tester.pump();

    expect(harness.controller.isDraggingFixedTarget, isFalse);
    expect(
      harness.controller.primarySelectedSegment!.focusMode,
      ZoomFocusMode.followCursor,
    );
  });
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
      case 'previewGetSourceDimensions':
        return const {'width': 1920.0, 'height': 1080.0};
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
