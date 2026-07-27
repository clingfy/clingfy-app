import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/bridges/native_method_channel.dart';
import 'package:clingfy/core/devices/device_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test_helpers/wait_until.dart';

/// Displays the fake native side reports on the next getDisplays call.
List<Map<String, Object?>> _displays = const [];
List<Map<String, Object?>> _cameras = const [];
final List<MethodCall> _calls = <MethodCall>[];

void _installMocks() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel(NativeChannel.screenRecorder),
    (call) async {
      _calls.add(call);
      switch (call.method) {
        case 'getDisplays':
          return _displays;
        case 'getVideoSources':
          return _cameras;
        case 'getAudioSources':
        case 'getAppWindows':
          return <dynamic>[];
        default:
          return null;
      }
    },
  );
  // EventChannel subscribes via a 'listen' method call on the SAME channel
  // name. Without this the stream errors on subscribe and no event ever
  // arrives — which looks exactly like the feature being broken.
  messenger.setMockMethodCallHandler(
    const MethodChannel(NativeChannel.screenRecorderEvents),
    (call) async => null,
  );
}

Future<void> _emit(String type) async {
  final data = const StandardMethodCodec().encodeSuccessEnvelope({
    'type': type,
  });
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(NativeChannel.screenRecorderEvents, data, (_) {});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _calls.clear();
    _displays = const [];
    _cameras = const [];
    SharedPreferences.setMockInitialValues({});
    _installMocks();
  });

  Future<DeviceController> makeController() async {
    final controller = DeviceController(nativeBridge: NativeBridge.instance);
    await waitUntil(
      () => controller.isHydrated,
      reason: 'device controller never hydrated',
    );
    return controller;
  }

  group('displaysChanged event', () {
    test('is a wire constant, kept in sync with Swift', () {
      // The Swift side declares the same literal; a rename on one side alone
      // makes the event silently stop arriving.
      expect(DeviceEventType.displaysChanged, 'displaysChanged');
    });

    test('reloads the display list', () async {
      _displays = const [
        {
          'id': 1,
          'name': 'Built-in',
          'x': 0.0,
          'y': 0.0,
          'width': 1920.0,
          'height': 1080.0,
          'scale': 2.0,
        },
      ];
      final controller = await makeController();
      addTearDown(controller.dispose);
      expect(controller.displays.length, 1);

      // A monitor is plugged in.
      _displays = const [
        {
          'id': 1,
          'name': 'Built-in',
          'x': 0.0,
          'y': 0.0,
          'width': 1920.0,
          'height': 1080.0,
          'scale': 2.0,
        },
        {
          'id': 2,
          'name': 'Studio Display',
          'x': 1920.0,
          'y': 0.0,
          'width': 2560.0,
          'height': 1440.0,
          'scale': 2.0,
        },
      ];
      await _emit(DeviceEventType.displaysChanged);

      await waitUntil(
        () => controller.displays.length == 2,
        reason: 'display list did not refresh on displaysChanged',
      );
      expect(
        controller.displays.map((d) => d.name),
        contains('Studio Display'),
      );
    });

    test('does not reload the microphone list', () async {
      // The bug this replaces: a screen change fired audioSourcesChanged, so
      // plugging in a monitor re-enumerated microphones and never displays.
      _displays = const [
        {
          'id': 1,
          'name': 'Built-in',
          'x': 0.0,
          'y': 0.0,
          'width': 1920.0,
          'height': 1080.0,
          'scale': 2.0,
        },
      ];
      final controller = await makeController();
      addTearDown(controller.dispose);

      _calls.clear();
      await _emit(DeviceEventType.displaysChanged);
      await waitUntil(
        () => _calls.any((c) => c.method == 'getDisplays'),
        reason: 'displays were never re-enumerated',
      );

      expect(_calls.where((c) => c.method == 'getAudioSources'), isEmpty);
    });
  });

  group('selection survives a device disappearing and returning', () {
    test(
      'an unplugged display does not overwrite the saved preference',
      () async {
        SharedPreferences.setMockInitialValues({'selectedDisplayId': 2});
        _displays = const [
          {
            'id': 1,
            'name': 'Built-in',
            'x': 0.0,
            'y': 0.0,
            'width': 1920.0,
            'height': 1080.0,
            'scale': 2.0,
          },
          {
            'id': 2,
            'name': 'Studio Display',
            'x': 1920.0,
            'y': 0.0,
            'width': 2560.0,
            'height': 1440.0,
            'scale': 2.0,
          },
        ];
        final controller = await makeController();
        addTearDown(controller.dispose);
        expect(controller.selectedDisplayId, 2);

        // Unplug the external display: recording must still work, so the
        // effective selection falls back to the built-in screen...
        _displays = const [
          {
            'id': 1,
            'name': 'Built-in',
            'x': 0.0,
            'y': 0.0,
            'width': 1920.0,
            'height': 1080.0,
            'scale': 2.0,
          },
        ];
        await _emit(DeviceEventType.displaysChanged);
        await waitUntil(
          () => controller.selectedDisplayId == 1,
          reason: 'did not fall back to the remaining display',
        );

        // ...but the user's stored choice must be untouched.
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getInt('selectedDisplayId'),
          2,
          reason: 'fallback clobbered the saved preference',
        );

        // Re-plug: the preference is honoured again.
        _displays = const [
          {
            'id': 1,
            'name': 'Built-in',
            'x': 0.0,
            'y': 0.0,
            'width': 1920.0,
            'height': 1080.0,
            'scale': 2.0,
          },
          {
            'id': 2,
            'name': 'Studio Display',
            'x': 1920.0,
            'y': 0.0,
            'width': 2560.0,
            'height': 1440.0,
            'scale': 2.0,
          },
        ];
        await _emit(DeviceEventType.displaysChanged);
        await waitUntil(
          () => controller.selectedDisplayId == 2,
          reason: 'preferred display was not restored on reconnect',
        );
      },
    );

    test(
      'an unplugged camera does not overwrite the saved preference',
      () async {
        SharedPreferences.setMockInitialValues({'videoDeviceId': 'usb-cam'});
        _cameras = const [
          {'id': 'facetime', 'name': 'FaceTime HD'},
          {'id': 'usb-cam', 'name': 'USB Camera'},
        ];
        final controller = await makeController();
        addTearDown(controller.dispose);
        expect(controller.selectedCamId, 'usb-cam');

        _cameras = const [
          {'id': 'facetime', 'name': 'FaceTime HD'},
        ];
        await _emit(DeviceEventType.videoSourcesChanged);
        await waitUntil(
          () => controller.selectedCamId == 'facetime',
          reason: 'did not fall back to the remaining camera',
        );

        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getString('videoDeviceId'),
          'usb-cam',
          reason: 'fallback clobbered the saved camera preference',
        );

        _cameras = const [
          {'id': 'facetime', 'name': 'FaceTime HD'},
          {'id': 'usb-cam', 'name': 'USB Camera'},
        ];
        await _emit(DeviceEventType.videoSourcesChanged);
        await waitUntil(
          () => controller.selectedCamId == 'usb-cam',
          reason: 'preferred camera was not restored on reconnect',
        );
      },
    );

    test(
      'a display fallback is pushed to native, not just held in Dart',
      () async {
        // Native keeps its own selected display; without the push the Swift
        // facade keeps targeting a screen that is gone.
        SharedPreferences.setMockInitialValues({'selectedDisplayId': 2});
        _displays = const [
          {
            'id': 1,
            'name': 'Built-in',
            'x': 0.0,
            'y': 0.0,
            'width': 1920.0,
            'height': 1080.0,
            'scale': 2.0,
          },
          {
            'id': 2,
            'name': 'Studio Display',
            'x': 1920.0,
            'y': 0.0,
            'width': 2560.0,
            'height': 1440.0,
            'scale': 2.0,
          },
        ];
        final controller = await makeController();
        addTearDown(controller.dispose);

        _calls.clear();
        _displays = const [
          {
            'id': 1,
            'name': 'Built-in',
            'x': 0.0,
            'y': 0.0,
            'width': 1920.0,
            'height': 1080.0,
            'scale': 2.0,
          },
        ];
        await _emit(DeviceEventType.displaysChanged);
        await waitUntil(
          () => controller.selectedDisplayId == 1,
          reason: 'did not fall back',
        );

        final setDisplay = _calls.where((c) => c.method == 'setDisplay');
        expect(setDisplay, isNotEmpty);
        expect((setDisplay.last.arguments as Map)['id'], 1);
      },
    );
  });
}
