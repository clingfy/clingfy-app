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
}
