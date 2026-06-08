import 'package:clingfy/app/home/overlay/overlay_controller.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../test_helpers/native_test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await installCommonNativeMocks();
  });

  tearDown(() async {
    await clearCommonNativeMocks();
  });

  testWidgets('legacy circle ordinal migrates to stable shape id', (
    tester,
  ) async {
    final harness = await _createControllerHarness(
      tester,
      initialPrefs: const {'overlayShape': 0},
    );

    expect(harness.controller.overlayShape, OverlayShape.circle);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('pref.overlayShapeId'), 0);

    final shapeCall = _lastMethodCall(harness.calls, 'setCameraOverlayShape');
    expect(_callArguments(shapeCall)['shapeId'], 0);
  });

  testWidgets('legacy star ordinal migrates to stable shape id', (
    tester,
  ) async {
    final harness = await _createControllerHarness(
      tester,
      initialPrefs: const {'overlayShape': 4},
    );

    expect(harness.controller.overlayShape, OverlayShape.star);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('pref.overlayShapeId'), 4);
  });

  testWidgets('missing shape prefs default to squircle and persist stable id', (
    tester,
  ) async {
    final harness = await _createControllerHarness(tester);

    expect(harness.controller.overlayShape, OverlayShape.squircle);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('pref.overlayShapeId'), 5);
  });

  testWidgets('invalid stable shape id falls back to squircle', (tester) async {
    final harness = await _createControllerHarness(
      tester,
      initialPrefs: const {'pref.overlayShapeId': 99},
    );

    expect(harness.controller.overlayShape, OverlayShape.squircle);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('pref.overlayShapeId'), 5);
  });

  testWidgets('setOverlayShape writes stable id and sends shapeId payload', (
    tester,
  ) async {
    final harness = await _createControllerHarness(tester);
    harness.calls.clear();

    await harness.controller.setOverlayShape(OverlayShape.squircle);
    await tester.pump();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('pref.overlayShapeId'), 5);

    final shapeCall = _lastMethodCall(harness.calls, 'setCameraOverlayShape');
    final args = _callArguments(shapeCall);
    expect(args['shapeId'], 5);
    expect(args.containsKey('shape'), isFalse);
  });

  testWidgets(
    'invalid custom position hydration clears custom mode and coordinates',
    (tester) async {
      final harness = await _createControllerHarness(
        tester,
        initialPrefs: const {
          'overlayUseCustomPosition': true,
          'overlayCustomNormalizedX': 0.4,
        },
      );

      expect(harness.controller.overlayUseCustomPosition, isFalse);
      expect(harness.controller.overlayCustomNormalizedX, isNull);
      expect(harness.controller.overlayCustomNormalizedY, isNull);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('overlayUseCustomPosition'), isFalse);
      expect(prefs.getDouble('overlayCustomNormalizedX'), isNull);
      expect(prefs.getDouble('overlayCustomNormalizedY'), isNull);
    },
  );

  testWidgets('setting custom position keeps custom mode enabled', (
    tester,
  ) async {
    final harness = await _createControllerHarness(tester);

    await harness.controller.setOverlayCustomPositionNormalized(
      x: 0.25,
      y: 0.8,
    );
    await tester.pump();

    expect(harness.controller.overlayUseCustomPosition, isTrue);
    expect(harness.controller.overlayCustomNormalizedX, closeTo(0.25, 0.0001));
    expect(harness.controller.overlayCustomNormalizedY, closeTo(0.8, 0.0001));

    final customPositionCall = _lastMethodCall(
      harness.calls,
      'setCameraOverlayCustomPosition',
    );
    final args = _callArguments(customPositionCall);
    expect(args['normalizedX'], closeTo(0.25, 0.0001));
    expect(args['normalizedY'], closeTo(0.8, 0.0001));
  });

  testWidgets(
    'Phase 9.3.2: floating preview falls back to in-app when native refuses',
    (tester) async {
      // Camera on + floating preference, but native reports the floating bubble
      // is unavailable (no capture-exclusion). The controller must switch to the
      // in-app texture and persist the choice so it survives restarts.
      final harness = await _createControllerHarness(
        tester,
        initialPrefs: const {
          'overlayEnabled': true,
          'cameraPreviewMode': 'floating',
        },
        onCall: (call) async {
          if (call.method == 'setCameraPreviewMode') {
            return <String, Object?>{'floating': false};
          }
          return null;
        },
      );

      expect(harness.controller.cameraFloatingPreview, isTrue);

      harness.controller.updateRecordingState(true);
      for (var i = 0; i < 50 && harness.controller.cameraFloatingPreview; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }

      expect(harness.controller.cameraFloatingPreview, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('cameraPreviewMode'), 'inApp');

      final modeCall = _lastMethodCall(harness.calls, 'setCameraPreviewMode');
      expect(_callArguments(modeCall)['floating'], isTrue);
    },
  );

  testWidgets('Phase 9.3.2: floating preview is kept when native honors it', (
    tester,
  ) async {
    final harness = await _createControllerHarness(
      tester,
      initialPrefs: const {
        'overlayEnabled': true,
        'cameraPreviewMode': 'floating',
      },
      onCall: (call) async {
        if (call.method == 'setCameraPreviewMode') {
          return <String, Object?>{'floating': true};
        }
        return null;
      },
    );

    harness.controller.updateRecordingState(true);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(harness.controller.cameraFloatingPreview, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('cameraPreviewMode'), 'floating');
  });
}

Future<_OverlayControllerHarness> _createControllerHarness(
  WidgetTester tester, {
  Map<String, Object> initialPrefs = const {},
  Future<Object?> Function(MethodCall call)? onCall,
}) async {
  SharedPreferences.setMockInitialValues(initialPrefs);
  final calls = <MethodCall>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  messenger.setMockMethodCallHandler(screenRecorderChannel, (call) async {
    calls.add(call);
    if (onCall != null) return onCall(call);
    return null;
  });

  final controller = OverlayController(bridge: NativeBridge.instance);
  await _pumpUntilHydrated(tester, controller);
  addTearDown(controller.dispose);
  return _OverlayControllerHarness(controller: controller, calls: calls);
}

Future<void> _pumpUntilHydrated(
  WidgetTester tester,
  OverlayController controller,
) async {
  for (var i = 0; i < 50 && !controller.isHydrated; i += 1) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(controller.isHydrated, isTrue);
}

MethodCall _lastMethodCall(List<MethodCall> calls, String method) {
  return calls.lastWhere((call) => call.method == method);
}

Map<String, dynamic> _callArguments(MethodCall call) {
  return Map<String, dynamic>.from(call.arguments as Map);
}

class _OverlayControllerHarness {
  const _OverlayControllerHarness({
    required this.controller,
    required this.calls,
  });

  final OverlayController controller;
  final List<MethodCall> calls;
}
