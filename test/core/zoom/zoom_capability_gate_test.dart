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

  testWidgets('legacy capabilities -> addDefaultSegmentAtWithFocus '
      'creates a followCursor segment without querying samples', (
    tester,
  ) async {
    final harness = await _createHarness(
      tester,
      capabilities: null, // simulates pre-Phase-1 native (no method).
    );

    final created = await harness.controller.addDefaultSegmentAtWithFocus(
      1000,
      playheadMs: 1000,
    );

    expect(created, isNotNull);
    expect(created!.focusMode, ZoomFocusMode.followCursor);
    expect(created.fixedTarget, isNull);
    expect(
      harness.calls.where((c) => c.method == 'previewGetCursorSamples'),
      isEmpty,
      reason: 'must not query cursor samples when capabilities are legacy',
    );
  });

  testWidgets('MissingPluginException from cursor samples -> '
      'falls back to followCursor and disables capability for session', (
    tester,
  ) async {
    final harness = await _createHarness(
      tester,
      capabilities: const {
        'cursorSamples': true,
        'fixedTargetPreview': true,
        'fixedTargetExport': true,
      },
      cursorSamplesHandler: (_) async {
        throw MissingPluginException('not implemented');
      },
    );

    expect(
      harness.controller.capabilities.supportsSmartFixedTarget,
      isTrue,
    );

    final created = await harness.controller.addDefaultSegmentAtWithFocus(
      1000,
      playheadMs: 1000,
    );

    expect(created, isNotNull);
    expect(created!.focusMode, ZoomFocusMode.followCursor);
    expect(created.fixedTarget, isNull);
    expect(
      harness.controller.capabilities.supportsSmartFixedTarget,
      isFalse,
      reason: 'capability must be downgraded after MissingPluginException',
    );
  });

  testWidgets('supported + empty samples -> creates fixedTarget center', (
    tester,
  ) async {
    final harness = await _createHarness(
      tester,
      capabilities: const {
        'cursorSamples': true,
        'fixedTargetPreview': true,
        'fixedTargetExport': true,
      },
      cursorSamplesHandler: (_) async => <String, Object?>{
        'samples': <Map<String, Object?>>[],
        'playheadSample': null,
        'width': 1920,
        'height': 1080,
      },
    );

    final created = await harness.controller.addDefaultSegmentAtWithFocus(
      1000,
      playheadMs: 1000,
    );

    expect(created, isNotNull);
    expect(created!.focusMode, ZoomFocusMode.fixedTarget);
    expect(created.fixedTarget, NormalizedPoint.center);
  });

  testWidgets('supported + static cursor -> fixedTarget at cursor sample', (
    tester,
  ) async {
    final harness = await _createHarness(
      tester,
      capabilities: const {
        'cursorSamples': true,
        'fixedTargetPreview': true,
        'fixedTargetExport': true,
      },
      cursorSamplesHandler: (_) async => <String, Object?>{
        'samples': const <Map<String, Object?>>[
          {'tMs': 800, 'x': 480.0, 'y': 270.0, 'visible': true},
          {'tMs': 1000, 'x': 482.0, 'y': 271.0, 'visible': true},
          {'tMs': 1200, 'x': 484.0, 'y': 272.0, 'visible': true},
        ],
        'playheadSample': const <String, Object?>{
          'tMs': 1000,
          'x': 482.0,
          'y': 271.0,
          'visible': true,
        },
        'width': 1920,
        'height': 1080,
      },
    );

    final created = await harness.controller.addDefaultSegmentAtWithFocus(
      1000,
      playheadMs: 1000,
    );

    expect(created, isNotNull);
    expect(created!.focusMode, ZoomFocusMode.fixedTarget);
    expect(created.fixedTarget, isNotNull);
    expect(created.fixedTarget!.dx, closeTo(482 / 1920, 1e-9));
    expect(created.fixedTarget!.dy, closeTo(271 / 1080, 1e-9));
  });

  testWidgets('supported + moving cursor -> followCursor', (tester) async {
    final harness = await _createHarness(
      tester,
      capabilities: const {
        'cursorSamples': true,
        'fixedTargetPreview': true,
        'fixedTargetExport': true,
      },
      cursorSamplesHandler: (_) async => <String, Object?>{
        'samples': const <Map<String, Object?>>[
          {'tMs': 800, 'x': 100.0, 'y': 100.0, 'visible': true},
          {'tMs': 1000, 'x': 400.0, 'y': 220.0, 'visible': true},
          {'tMs': 1200, 'x': 700.0, 'y': 480.0, 'visible': true},
        ],
        'playheadSample': const <String, Object?>{
          'tMs': 1000,
          'x': 400.0,
          'y': 220.0,
          'visible': true,
        },
        'width': 1920,
        'height': 1080,
      },
    );

    final created = await harness.controller.addDefaultSegmentAtWithFocus(
      1000,
      playheadMs: 1000,
    );

    expect(created, isNotNull);
    expect(created!.focusMode, ZoomFocusMode.followCursor);
    expect(created.fixedTarget, isNull);
  });
}

Future<_CapabilityHarness> _createHarness(
  WidgetTester tester, {
  Map<String, Object?>? capabilities,
  Future<Object?> Function(MethodCall call)? cursorSamplesHandler,
}) async {
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
        return capabilities;
      case 'previewGetCursorSamples':
        if (cursorSamplesHandler == null) return null;
        return await cursorSamplesHandler(call);
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

  return _CapabilityHarness(controller: controller, calls: calls);
}

class _CapabilityHarness {
  const _CapabilityHarness({required this.controller, required this.calls});

  final ZoomEditorController controller;
  final List<MethodCall> calls;
}
