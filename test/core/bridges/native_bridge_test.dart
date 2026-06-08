import 'dart:async';

import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/bridges/native_method_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../test_helpers/native_test_setup.dart';

Future<void> _emitNativeMethod(String method, [Object? arguments]) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final completer = Completer<void>();
  messenger.handlePlatformMessage(
    NativeChannel.screenRecorder,
    const StandardMethodCodec().encodeMethodCall(MethodCall(method, arguments)),
    (_) => completer.complete(),
  );
  await completer.future;
}

Future<void> _emitWorkflowEvent(Map<String, Object?> event) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final completer = Completer<void>();
  messenger.handlePlatformMessage(
    NativeChannel.workflowEvents,
    const StandardMethodCodec().encodeSuccessEnvelope(event),
    (_) => completer.complete(),
  );
  await completer.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await installCommonNativeMocks();
  });

  tearDown(() async {
    final bridge = NativeBridge.instance;
    bridge.setOnIndicatorPauseTapped(null);
    bridge.setOnIndicatorStopTapped(null);
    bridge.setOnIndicatorResumeTapped(null);
    bridge.setOnProjectOpenRequested(null);
    await clearCommonNativeMocks();
  });

  test('indicatorPauseTapped dispatches through NativeBridge', () async {
    final bridge = NativeBridge.instance;
    var pauseTapped = 0;

    bridge.setOnIndicatorPauseTapped(() {
      pauseTapped += 1;
    });

    await _emitNativeMethod(NativeToFlutterMethod.indicatorPauseTapped);

    expect(pauseTapped, 1);
  });

  test(
    'Finder project open requests buffer until callback is attached',
    () async {
      final bridge = NativeBridge.instance;
      final openedProjects = <String>[];

      await _emitWorkflowEvent({
        'type': 'openProjectRequest',
        'projectPath': '/tmp/first.clingfyproj',
      });
      await _emitWorkflowEvent({
        'type': 'openProjectRequest',
        'projectPath': '/tmp/first.clingfyproj',
      });
      await _emitWorkflowEvent({
        'type': 'openProjectRequest',
        'projectPath': '/tmp/second.clingfyproj',
      });

      bridge.setOnProjectOpenRequested(openedProjects.add);
      await Future<void>.delayed(Duration.zero);

      expect(openedProjects, [
        '/tmp/first.clingfyproj',
        '/tmp/second.clingfyproj',
      ]);
    },
  );

  group('camera preview bridge (Phase 9.3.1/9.3.2)', () {
    void overrideScreenRecorder(
      Future<Object?> Function(MethodCall call) handler,
    ) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(screenRecorderChannel, handler);
    }

    void clearScreenRecorder() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(screenRecorderChannel, null);
    }

    test(
      'setCameraPreviewMode forwards floating + parses resulting true',
      () async {
        MethodCall? captured;
        overrideScreenRecorder((call) async {
          captured = call;
          return <String, Object?>{'floating': true};
        });

        final result = await NativeBridge.instance.setCameraPreviewMode(
          floating: true,
        );

        expect(result, isTrue);
        expect(captured?.method, 'setCameraPreviewMode');
        expect((captured?.arguments as Map)['floating'], isTrue);
      },
    );

    test(
      'setCameraPreviewMode parses resulting false (floating refused)',
      () async {
        overrideScreenRecorder(
          (call) async => <String, Object?>{'floating': false},
        );

        final result = await NativeBridge.instance.setCameraPreviewMode(
          floating: true,
        );

        expect(result, isFalse);
      },
    );

    test(
      'setCameraPreviewMode returns false on MissingPluginException',
      () async {
        // No handler registered → channel throws MissingPluginException (macOS /
        // builds without the Windows handler). Must degrade to false, not throw.
        clearScreenRecorder();

        final result = await NativeBridge.instance.setCameraPreviewMode(
          floating: true,
        );

        expect(result, isFalse);
      },
    );

    test('getCameraPreviewTextureId parses a valid texture id', () async {
      overrideScreenRecorder((call) async => <String, Object?>{'textureId': 7});

      final id = await NativeBridge.instance.getCameraPreviewTextureId();

      expect(id, 7);
    });

    test('getCameraPreviewTextureId returns null for a negative id', () async {
      overrideScreenRecorder(
        (call) async => <String, Object?>{'textureId': -1},
      );

      final id = await NativeBridge.instance.getCameraPreviewTextureId();

      expect(id, isNull);
    });

    test(
      'getCameraPreviewTextureId returns null on MissingPluginException',
      () async {
        clearScreenRecorder();

        final id = await NativeBridge.instance.getCameraPreviewTextureId();

        expect(id, isNull);
      },
    );
  });
}
