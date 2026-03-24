import 'package:clingfy/app/permissions/permissions_controller.dart';
import 'package:clingfy/core/permissions/models/recording_start_preflight.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';

import '../../test_helpers/native_test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await installCommonNativeMocks();
  });

  tearDown(() async {
    await clearCommonNativeMocks();
  });

  test('preflight is clear when all requested permissions are granted', () {
    final controller = PermissionsController(bridge: NativeBridge.instance);
    controller.screenRecording = true;
    controller.microphone = true;
    controller.camera = true;
    controller.accessibility = true;

    final preflight = controller.buildRecordingStartPreflight(
      intent: const RecordingStartIntent(
        needsScreenRecording: true,
        needsMicrophone: true,
        needsCamera: true,
        needsAccessibility: true,
      ),
    );

    expect(preflight.isClear, isTrue);
    expect(preflight.missingHard, isEmpty);
    expect(preflight.missingOptional, isEmpty);
  });

  test('screen recording missing is classified as hard blocker', () {
    final controller = PermissionsController(bridge: NativeBridge.instance);
    controller.screenRecording = false;
    controller.microphone = true;
    controller.camera = true;
    controller.accessibility = true;

    final preflight = controller.buildRecordingStartPreflight(
      intent: const RecordingStartIntent(
        needsScreenRecording: true,
        needsMicrophone: false,
        needsCamera: false,
        needsAccessibility: false,
      ),
    );

    expect(preflight.hasHardBlocker, isTrue);
    expect(
      preflight.missingHard,
      equals([MissingPermissionKind.screenRecording]),
    );
    expect(preflight.missingOptional, isEmpty);
  });

  test(
    'camera, microphone, and accessibility are optional gaps only when requested',
    () {
      final controller = PermissionsController(bridge: NativeBridge.instance);
      controller.screenRecording = true;
      controller.microphone = false;
      controller.camera = false;
      controller.accessibility = false;

      final preflight = controller.buildRecordingStartPreflight(
        intent: const RecordingStartIntent(
          needsScreenRecording: true,
          needsMicrophone: true,
          needsCamera: true,
          needsAccessibility: false,
        ),
      );

      expect(preflight.hasHardBlocker, isFalse);
      expect(
        preflight.missingOptional,
        equals([
          MissingPermissionKind.microphone,
          MissingPermissionKind.camera,
        ]),
      );
    },
  );

  test('prepareRecordingStartPreflight refreshes before building', () async {
    var refreshCalls = 0;
    var storageCalls = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    messenger.setMockMethodCallHandler(screenRecorderChannel, (call) async {
      switch (call.method) {
        case 'getPermissionStatus':
          refreshCalls += 1;
          return <String, bool>{
            'screenRecording': true,
            'microphone': false,
            'camera': true,
            'accessibility': false,
          };
        case 'getStorageSnapshot':
          storageCalls += 1;
          return <String, dynamic>{
            'systemTotalBytes': 500 * 1024 * 1024 * 1024,
            'systemAvailableBytes': 15 * 1024 * 1024 * 1024,
            'recordingsBytes': 4 * 1024 * 1024,
            'tempBytes': 2 * 1024 * 1024,
            'logsBytes': 512 * 1024,
            'recordingsPath': '/tmp/recordings',
            'tempPath': '/tmp/temp',
            'logsPath': '/tmp/logs',
            'warningThresholdBytes': 20 * 1024 * 1024 * 1024,
            'criticalThresholdBytes': 10 * 1024 * 1024 * 1024,
          };
        default:
          return null;
      }
    });

    final controller = PermissionsController(bridge: NativeBridge.instance);
    controller.screenRecording = false;
    controller.microphone = true;
    controller.camera = false;
    controller.accessibility = true;

    final preflight = await controller.prepareRecordingStartPreflight(
      intent: const RecordingStartIntent(
        needsScreenRecording: true,
        needsMicrophone: true,
        needsCamera: false,
        needsAccessibility: true,
      ),
    );

    expect(refreshCalls, 1);
    expect(storageCalls, 1);
    expect(preflight.hasHardBlocker, isFalse);
    expect(
      preflight.missingOptional,
      equals([
        MissingPermissionKind.microphone,
        MissingPermissionKind.accessibility,
      ]),
    );
    expect(preflight.storage?.isWarning, isTrue);
  });

  test('onboarding step defaults to zero and can be persisted', () async {
    SharedPreferences.setMockInitialValues({});

    final controller = PermissionsController(bridge: NativeBridge.instance);

    expect(await controller.getOnboardingStep(), 0);

    await controller.setOnboardingStep(2);
    expect(await controller.getOnboardingStep(), 2);

    await controller.resetOnboardingStep();
    expect(await controller.getOnboardingStep(), 0);
  });

  test(
    'refresh ignores stale permission results from earlier requests',
    () async {
      final firstResponse = Completer<Map<String, bool>>();
      final secondResponse = Completer<Map<String, bool>>();
      var refreshCalls = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

      messenger.setMockMethodCallHandler(screenRecorderChannel, (call) async {
        switch (call.method) {
          case 'getPermissionStatus':
            refreshCalls += 1;
            if (refreshCalls == 1) {
              return firstResponse.future;
            }
            return secondResponse.future;
          default:
            return null;
        }
      });

      final controller = PermissionsController(bridge: NativeBridge.instance);

      final firstRefresh = controller.refresh();
      final secondRefresh = controller.refresh();

      secondResponse.complete(<String, bool>{
        'screenRecording': true,
        'microphone': true,
        'camera': false,
        'accessibility': false,
      });
      await secondRefresh;

      expect(controller.screenRecording, isTrue);
      expect(controller.microphone, isTrue);
      expect(controller.camera, isFalse);
      expect(controller.accessibility, isFalse);
      expect(controller.loading, isFalse);

      firstResponse.complete(<String, bool>{
        'screenRecording': false,
        'microphone': false,
        'camera': true,
        'accessibility': true,
      });
      await firstRefresh;

      expect(controller.screenRecording, isTrue);
      expect(controller.microphone, isTrue);
      expect(controller.camera, isFalse);
      expect(controller.accessibility, isFalse);
      expect(controller.loading, isFalse);
    },
  );
}
