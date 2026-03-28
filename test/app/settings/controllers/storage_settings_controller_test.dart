import 'dart:async';

import 'package:clingfy/app/settings/controllers/storage_settings_controller.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/bridges/native_method_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(NativeChannel.screenRecorder);

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('refresh loads storage snapshot and notifies listeners', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getStorageSnapshot') {
            return <String, dynamic>{
              'systemTotalBytes': 500 * 1024 * 1024 * 1024,
              'systemAvailableBytes': 200 * 1024 * 1024 * 1024,
              'recordingsBytes': 4 * 1024 * 1024,
              'tempBytes': 2 * 1024 * 1024,
              'logsBytes': 512 * 1024,
              'recordingsPath': '/tmp/recordings',
              'tempPath': '/tmp/temp',
              'logsPath': '/tmp/logs',
              'warningThresholdBytes': 20 * 1024 * 1024 * 1024,
              'criticalThresholdBytes': 10 * 1024 * 1024 * 1024,
            };
          }
          return null;
        });

    final controller = StorageSettingsController(
      nativeBridge: NativeBridge.instance,
    );
    var notifications = 0;
    controller.addListener(() {
      notifications += 1;
    });

    await controller.refresh();

    expect(controller.snapshot, isNotNull);
    expect(controller.snapshot?.systemAvailableBytes, 200 * 1024 * 1024 * 1024);
    expect(controller.error, isNull);
    expect(controller.isLoading, isFalse);
    expect(notifications, greaterThanOrEqualTo(2));
  });

  test('refresh surfaces error state when native call fails', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(code: 'BROKEN');
        });

    final controller = StorageSettingsController(
      nativeBridge: NativeBridge.instance,
    );

    await controller.refresh();

    expect(controller.snapshot, isNull);
    expect(controller.error, isNotNull);
    expect(controller.isLoading, isFalse);
  });

  test(
    'refresh skips overlapping requests while a load is in flight',
    () async {
      final completer = Completer<Map<String, dynamic>>();
      var calls = 0;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getStorageSnapshot') {
              calls += 1;
              return completer.future;
            }
            return null;
          });

      final controller = StorageSettingsController(
        nativeBridge: NativeBridge.instance,
      );

      final first = controller.refresh();
      final second = controller.refresh();

      expect(calls, 1);
      expect(controller.isLoading, isTrue);

      completer.complete(<String, dynamic>{
        'systemTotalBytes': 500 * 1024 * 1024 * 1024,
        'systemAvailableBytes': 200 * 1024 * 1024 * 1024,
        'recordingsBytes': 4 * 1024 * 1024,
        'tempBytes': 2 * 1024 * 1024,
        'logsBytes': 512 * 1024,
        'recordingsPath': '/tmp/recordings',
        'tempPath': '/tmp/temp',
        'logsPath': '/tmp/logs',
        'warningThresholdBytes': 20 * 1024 * 1024 * 1024,
        'criticalThresholdBytes': 10 * 1024 * 1024 * 1024,
      });

      await Future.wait([first, second]);

      expect(calls, 1);
      expect(controller.snapshot, isNotNull);
      expect(controller.isLoading, isFalse);
    },
  );

  test(
    'clearCachedRecordings delegates to native and refreshes snapshot',
    () async {
      var snapshotCalls = 0;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'getStorageSnapshot':
                snapshotCalls += 1;
                return <String, dynamic>{
                  'systemTotalBytes': 500 * 1024 * 1024 * 1024,
                  'systemAvailableBytes': 200 * 1024 * 1024 * 1024,
                  'recordingsBytes': snapshotCalls == 1 ? 4 * 1024 * 1024 : 0,
                  'tempBytes': 2 * 1024 * 1024,
                  'logsBytes': 512 * 1024,
                  'recordingsPath': '/tmp/recordings',
                  'tempPath': '/tmp/temp',
                  'logsPath': '/tmp/logs',
                  'warningThresholdBytes': 20 * 1024 * 1024 * 1024,
                  'criticalThresholdBytes': 10 * 1024 * 1024 * 1024,
                };
              case 'clearCachedRecordings':
                return <String, dynamic>{'deletedCount': 2};
            }
            return null;
          });

      final controller = StorageSettingsController(
        nativeBridge: NativeBridge.instance,
      );

      await controller.refresh();
      final deletedCount = await controller.clearCachedRecordings();

      expect(deletedCount, 2);
      expect(snapshotCalls, 2);
      expect(controller.snapshot?.recordingsBytes, 0);
      expect(controller.error, isNull);
    },
  );

  test(
    'openSystemStorageSettings delegates to native system settings',
    () async {
      MethodCall? openCall;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'openSystemSettings') {
              openCall = call;
            }
            return null;
          });

      final controller = StorageSettingsController(
        nativeBridge: NativeBridge.instance,
      );

      await controller.openSystemStorageSettings();

      expect(openCall, isNotNull);
      expect(openCall!.method, 'openSystemSettings');
      expect(
        Map<String, dynamic>.from(
          openCall!.arguments! as Map<dynamic, dynamic>,
        ),
        {'pane': 'storage'},
      );
    },
  );
}
