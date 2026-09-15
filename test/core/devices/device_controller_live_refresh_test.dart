import 'dart:async';

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
List<Map<String, Object?>> _appWindows = const [];
final List<MethodCall> _calls = <MethodCall>[];

/// What the fake native side replies to identifyDisplays. Null means "reply
/// with whatever getDisplays would".
List<Map<String, Object?>>? _identifyReply;

/// When true the fake native side has no identifyDisplays handler at all.
bool _identifyMissing = false;

/// Gate that lets a test hold an identify reply open to force a race.
Completer<void>? _identifyGate;

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
          return <dynamic>[];
        case 'getAppWindows':
          return _appWindows;
        case 'identifyDisplays':
          if (_identifyMissing) {
            throw MissingPluginException('no identifyDisplays handler');
          }
          if (_identifyGate != null) await _identifyGate!.future;
          return _identifyReply ?? _displays;
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
    _appWindows = const [];
    _identifyReply = null;
    _identifyMissing = false;
    _identifyGate = null;
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

  group('appWindowsChanged event', () {
    test('is a wire constant, kept in sync with Swift', () {
      expect(DeviceEventType.appWindowsChanged, 'appWindowsChanged');
    });

    test('reloads the window list', () async {
      _appWindows = const [
        {'windowId': 1, 'appName': 'Safari', 'title': 'Docs'},
      ];
      final controller = await makeController();
      addTearDown(controller.dispose);
      expect(controller.appWindows.length, 1);

      // A second window opens while the picker is on screen.
      _appWindows = const [
        {'windowId': 1, 'appName': 'Safari', 'title': 'Docs'},
        {'windowId': 2, 'appName': 'Xcode', 'title': 'Runner'},
      ];
      await _emit(DeviceEventType.appWindowsChanged);

      await waitUntil(
        () => controller.appWindows.length == 2,
        reason: 'window list did not refresh on appWindowsChanged',
      );
    });

    test('does not reload unrelated lists', () async {
      _appWindows = const [
        {'windowId': 1, 'appName': 'Safari', 'title': 'Docs'},
      ];
      final controller = await makeController();
      addTearDown(controller.dispose);

      _calls.clear();
      await _emit(DeviceEventType.appWindowsChanged);
      await waitUntil(
        () => _calls.any((c) => c.method == 'getAppWindows'),
        reason: 'windows were never re-enumerated',
      );

      expect(_calls.where((c) => c.method == 'getDisplays'), isEmpty);
      expect(_calls.where((c) => c.method == 'getAudioSources'), isEmpty);
    });
  });

  group('identify displays', () {
    Map<String, Object?> display(
      int id, {
      required int ordinal,
      String? osName,
      bool isPrimary = false,
      double x = 0,
    }) => {
      'id': id,
      'name': '$ordinal. ${osName ?? 'Screen'}',
      'x': x,
      'y': 0.0,
      'width': 2560.0,
      'height': 1440.0,
      'scale': 2.0,
      'ordinal': ordinal,
      if (osName != null) 'osName': osName,
      'isPrimary': isPrimary,
      'isAppWindowHost': false,
    };

    MethodCall? lastCall(String method) {
      for (final call in _calls.reversed) {
        if (call.method == method) return call;
      }
      return null;
    }

    test('identifyDisplays is a wire constant, kept in sync with Swift', () {
      expect(NativeMethod.identifyDisplays, 'identifyDisplays');
    });

    test('the identify sweep asks native to flash every screen', () async {
      _displays = [
        display(1, ordinal: 1, osName: 'A', isPrimary: true),
        display(2, ordinal: 2, osName: 'B', x: 2560),
      ];
      final controller = await makeController();
      _calls.clear();

      await controller.identifyDisplays(labels: {'1': '1. A', '2': '2. B'});

      final call = lastCall('identifyDisplays');
      expect(call, isNotNull);
      final args = call!.arguments as Map;
      expect(args['only'], isFalse);
      expect(args['onlyDisplayId'], isNull);
      expect(args['durationMs'], 1600);
      expect(args['labels'], {'1': '1. A', '2': '2. B'});
    });

    test('choosing a display flashes that display, after setDisplay', () async {
      _displays = [
        display(1, ordinal: 1, osName: 'A', isPrimary: true),
        display(2, ordinal: 2, osName: 'B', x: 2560),
      ];
      final controller = await makeController();
      _calls.clear();

      await controller.setDisplay(2, labels: {'2': '2. B'});
      await pumpEventQueue();

      final setIndex = _calls.indexWhere((c) => c.method == 'setDisplay');
      final flashIndex = _calls.indexWhere(
        (c) => c.method == 'identifyDisplays',
      );
      expect(setIndex, isNonNegative);
      expect(flashIndex, isNonNegative);
      expect(
        setIndex,
        lessThan(flashIndex),
        reason: 'native must know the new target before it flashes it',
      );

      final args = lastCall('identifyDisplays')!.arguments as Map;
      expect(args['only'], isTrue);
      expect(args['onlyDisplayId'], 2);
      expect(args['durationMs'], 900);
    });

    test(
      'choosing Main display asks native to flash its own default',
      () async {
        _displays = [display(1, ordinal: 1, osName: 'A', isPrimary: true)];
        final controller = await makeController();
        _calls.clear();

        await controller.setDisplay(null);
        await pumpEventQueue();

        final args = lastCall('identifyDisplays')!.arguments as Map;
        expect(args['only'], isTrue);
        expect(args['onlyDisplayId'], isNull);
      },
    );

    test(
      'choosing Main display is not rewritten by the identify reply',
      () async {
        // The identify reply flows back into the display list. If it also re-ran
        // the preferred-vs-effective pass, a deliberate "Main display" choice
        // would be rewritten to an explicit id one frame later.
        _displays = [
          display(1, ordinal: 1, osName: 'A', isPrimary: true),
          display(2, ordinal: 2, osName: 'B', x: 2560),
        ];
        final controller = await makeController();
        await controller.setDisplay(null);
        _calls.clear();
        await pumpEventQueue();

        expect(controller.selectedDisplayId, isNull);
        final rewrites = _calls.where(
          (c) => c.method == 'setDisplay' && (c.arguments as Map)['id'] != null,
        );
        expect(rewrites, isEmpty);
      },
    );

    test('the flashed list is adopted without a second getDisplays', () async {
      _displays = [display(1, ordinal: 1, osName: 'A', isPrimary: true)];
      final controller = await makeController();
      _identifyReply = [
        display(1, ordinal: 1, osName: 'A', isPrimary: true),
        display(9, ordinal: 2, osName: 'Freshly plugged in', x: 2560),
      ];
      _calls.clear();

      await controller.identifyDisplays();

      expect(controller.displays.length, 2);
      expect(controller.displays[1].osName, 'Freshly plugged in');
      expect(_calls.where((c) => c.method == 'getDisplays'), isEmpty);
    });

    test('a stale identify reply loses to a newer reload', () async {
      _displays = [display(1, ordinal: 1, osName: 'A', isPrimary: true)];
      final controller = await makeController();

      _identifyGate = Completer<void>();
      _identifyReply = [display(7, ordinal: 1, osName: 'Stale')];
      final pending = controller.identifyDisplays();

      _displays = [display(5, ordinal: 1, osName: 'Fresh', isPrimary: true)];
      await controller.reloadDisplays();

      _identifyGate!.complete();
      await pending;

      expect(controller.displays.single.osName, 'Fresh');
    });

    test(
      'a native build without identifyDisplays is harmless and quiet',
      () async {
        _displays = [
          display(1, ordinal: 1, osName: 'A', isPrimary: true),
          display(2, ordinal: 2, osName: 'B', x: 2560),
        ];
        final controller = await makeController();
        _identifyMissing = true;
        var notifications = 0;
        controller.addListener(() => notifications++);
        _calls.clear();

        await controller.identifyDisplays();
        expect(controller.displayIdentifySupported, isFalse);
        expect(notifications, 1);

        final callsAfterFirst = _calls.length;
        await controller.identifyDisplays();
        expect(
          _calls.length,
          callsAfterFirst,
          reason: 'an unsupported build must never be asked twice',
        );
      },
    );

    test('a malformed identify reply is dropped, not thrown', () async {
      // _identify runs unawaited from setDisplay, so a throw here would land
      // as an unhandled async error rather than a caught PlatformException.
      _displays = [display(1, ordinal: 1, osName: 'A', isPrimary: true)];
      final controller = await makeController();
      _identifyReply = [
        display(1, ordinal: 1, osName: 'A', isPrimary: true),
        <String, Object?>{'name': 'no id at all'},
      ];

      await expectLater(controller.identifyDisplays(), completes);
      expect(controller.displays.length, 1);
      expect(controller.displays.single.id, 1);
    });

    test('the reload fallback prefers the primary display', () async {
      // The list arrives in desk order, so the first entry is the leftmost
      // monitor rather than the one the user calls their main screen.
      _displays = [
        display(7, ordinal: 1, osName: 'Left'),
        display(9, ordinal: 2, osName: 'Middle', isPrimary: true, x: 2560),
      ];
      final controller = await makeController();

      expect(controller.selectedDisplayId, 9);
      final pushed = _calls.lastWhere((c) => c.method == 'setDisplay');
      expect((pushed.arguments as Map)['id'], 9);
    });

    test('the reload fallback survives an empty display list', () async {
      _displays = const [];
      final controller = await makeController();

      await controller.reloadDisplays();

      expect(controller.selectedDisplayId, isNull);
      expect(controller.displays, isEmpty);
    });

    test('an identical reload does not notify', () async {
      _displays = [display(1, ordinal: 1, osName: 'A', isPrimary: true)];
      final controller = await makeController();
      var notifications = 0;
      controller.addListener(() => notifications++);

      await controller.reloadDisplays();
      await controller.reloadDisplays();

      expect(notifications, 0);
    });
  });
}
