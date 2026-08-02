import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/bridges/native_method_channel.dart';
import 'package:clingfy/core/recording/models/audio_output_route.dart';
import 'package:clingfy/core/recording/settings/recording_settings_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(NativeChannel.screenRecorder);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late String outputRoute;

  setUp(() {
    calls = <MethodCall>[];
    outputRoute = 'headphones';
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'getExcludeRecorderApp':
          return false;
        case 'getExcludeMicFromSystemAudio':
          return true;
        case 'getAudioOutputRoute':
          return {'route': outputRoute};
        default:
          return null;
      }
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  List<MethodCall> echoPushes() =>
      calls.where((c) => c.method == 'setMicEchoCancellationEnabled').toList();

  test('mic echo cancellation defaults to off', () {
    final controller = RecordingSettingsController(
      nativeBridge: NativeBridge.instance,
    );
    expect(controller.micEchoCancellationEnabled, isFalse);
  });

  test('loadPreferences with no stored value syncs OFF to native', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = RecordingSettingsController(
      nativeBridge: NativeBridge.instance,
    );

    await controller.loadPreferences(await SharedPreferences.getInstance());

    expect(controller.micEchoCancellationEnabled, isFalse);
    final pushes = echoPushes();
    expect(pushes, hasLength(1));
    expect((pushes.single.arguments as Map)['enabled'], isFalse);
  });

  test('loadPreferences restores a stored ON value and syncs it', () async {
    SharedPreferences.setMockInitialValues({
      'micEchoCancellationEnabled': true,
    });
    final controller = RecordingSettingsController(
      nativeBridge: NativeBridge.instance,
    );

    await controller.loadPreferences(await SharedPreferences.getInstance());

    expect(controller.micEchoCancellationEnabled, isTrue);
    final pushes = echoPushes();
    expect(pushes, hasLength(1));
    expect((pushes.single.arguments as Map)['enabled'], isTrue);
  });

  test(
    'updateMicEchoCancellationEnabled persists, notifies, and pushes',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = RecordingSettingsController(
        nativeBridge: NativeBridge.instance,
      );
      var notifications = 0;
      controller.addListener(() => notifications++);

      await controller.updateMicEchoCancellationEnabled(true);

      expect(controller.micEchoCancellationEnabled, isTrue);
      expect(notifications, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('micEchoCancellationEnabled'), isTrue);
      var pushes = echoPushes();
      expect(pushes, hasLength(1));
      expect((pushes.single.arguments as Map)['enabled'], isTrue);

      // Same value again is a no-op: no extra notify, no extra native push.
      await controller.updateMicEchoCancellationEnabled(true);
      expect(notifications, 1);
      expect(echoPushes(), hasLength(1));

      await controller.updateMicEchoCancellationEnabled(false);
      expect(controller.micEchoCancellationEnabled, isFalse);
      expect(prefs.getBool('micEchoCancellationEnabled'), isFalse);
      pushes = echoPushes();
      expect(pushes, hasLength(2));
      expect((pushes.last.arguments as Map)['enabled'], isFalse);
    },
  );

  group('system audio default', () {
    test('a fresh install records system audio', () async {
      // Shipping this OFF meant a recording could silently omit system audio,
      // and the omission was only discoverable by inspecting the bundle after
      // the take was already gone. "Record my screen" implies recording what
      // the screen plays.
      SharedPreferences.setMockInitialValues({});
      final controller = RecordingSettingsController(
        nativeBridge: NativeBridge.instance,
      );
      addTearDown(controller.dispose);

      expect(controller.systemAudioEnabled, isTrue, reason: 'before load');
      await controller.loadPreferences(await SharedPreferences.getInstance());
      expect(controller.systemAudioEnabled, isTrue, reason: 'after load');
    });

    test('an explicit opt-out is still honoured', () async {
      // Flipping the default must not override a user who deliberately turned
      // system audio off.
      SharedPreferences.setMockInitialValues({'systemAudioEnabled': false});
      final controller = RecordingSettingsController(
        nativeBridge: NativeBridge.instance,
      );
      addTearDown(controller.dispose);

      await controller.loadPreferences(await SharedPreferences.getInstance());
      expect(controller.systemAudioEnabled, isFalse);
    });

    test('an explicit opt-in still reads back on', () async {
      SharedPreferences.setMockInitialValues({'systemAudioEnabled': true});
      final controller = RecordingSettingsController(
        nativeBridge: NativeBridge.instance,
      );
      addTearDown(controller.dispose);

      await controller.loadPreferences(await SharedPreferences.getInstance());
      expect(controller.systemAudioEnabled, isTrue);
    });
  });

  group('speaker bleed warning', () {
    test('warns when system audio is on and output is speakers', () async {
      outputRoute = 'speakers';
      SharedPreferences.setMockInitialValues({});
      final controller = RecordingSettingsController(
        nativeBridge: NativeBridge.instance,
      );
      addTearDown(controller.dispose);

      await controller.loadPreferences(await SharedPreferences.getInstance());
      await controller.refreshAudioOutputRoute();

      expect(controller.systemAudioEnabled, isTrue);
      expect(controller.audioOutputRoute, AudioOutputRoute.speakers);
      expect(controller.systemAudioBleedRisk, isTrue);
    });

    test('stays quiet on headphones', () async {
      outputRoute = 'headphones';
      SharedPreferences.setMockInitialValues({});
      final controller = RecordingSettingsController(
        nativeBridge: NativeBridge.instance,
      );
      addTearDown(controller.dispose);

      await controller.loadPreferences(await SharedPreferences.getInstance());
      await controller.refreshAudioOutputRoute();

      expect(controller.systemAudioBleedRisk, isFalse);
    });

    test('stays quiet when system audio is off, even on speakers', () async {
      // No system audio means nothing for the mic to pick up twice.
      outputRoute = 'speakers';
      SharedPreferences.setMockInitialValues({'systemAudioEnabled': false});
      final controller = RecordingSettingsController(
        nativeBridge: NativeBridge.instance,
      );
      addTearDown(controller.dispose);

      await controller.loadPreferences(await SharedPreferences.getInstance());
      await controller.refreshAudioOutputRoute();

      expect(controller.audioOutputRoute, AudioOutputRoute.speakers);
      expect(controller.systemAudioBleedRisk, isFalse);
    });

    test('an unrecognized route never warns', () async {
      // A native build reporting something we do not understand must not
      // produce a false alarm — that trains the user to ignore the real one.
      outputRoute = 'teleporter';
      SharedPreferences.setMockInitialValues({});
      final controller = RecordingSettingsController(
        nativeBridge: NativeBridge.instance,
      );
      addTearDown(controller.dispose);

      await controller.loadPreferences(await SharedPreferences.getInstance());
      await controller.refreshAudioOutputRoute();

      expect(controller.audioOutputRoute, AudioOutputRoute.unknown);
      expect(controller.systemAudioBleedRisk, isFalse);
    });

    test(
      'loadPreferences probes the route without an explicit refresh',
      () async {
        // The startup probe is what makes the warning correct on the first take.
        // Deleting it must fail a test.
        outputRoute = 'speakers';
        SharedPreferences.setMockInitialValues({});
        final controller = RecordingSettingsController(
          nativeBridge: NativeBridge.instance,
        );
        addTearDown(controller.dispose);

        await controller.loadPreferences(await SharedPreferences.getInstance());
        // The probe is fire-and-forget; let it land.
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(controller.audioOutputRoute, AudioOutputRoute.speakers);
        expect(controller.systemAudioBleedRisk, isTrue);
        expect(calls.map((c) => c.method), contains('getAudioOutputRoute'));
      },
    );

    test('a route change notifies exactly once', () async {
      outputRoute = 'headphones';
      SharedPreferences.setMockInitialValues({});
      final controller = RecordingSettingsController(
        nativeBridge: NativeBridge.instance,
      );
      addTearDown(controller.dispose);
      await controller.loadPreferences(await SharedPreferences.getInstance());
      await controller.refreshAudioOutputRoute();

      var notifications = 0;
      controller.addListener(() => notifications++);

      outputRoute = 'speakers';
      await controller.refreshAudioOutputRoute();
      expect(notifications, 1);

      // Same route again is a no-op.
      await controller.refreshAudioOutputRoute();
      expect(notifications, 1);
    });
  });

  group('output route pushed by the CoreAudio listener', () {
    Future<void> emitRouteChanged() async {
      final data = const StandardMethodCodec().encodeSuccessEnvelope({
        'type': DeviceEventType.audioOutputRouteChanged,
      });
      await messenger.handlePlatformMessage(
        NativeChannel.screenRecorderEvents,
        data,
        (_) {},
      );
    }

    test('is a wire constant, kept in sync with Swift', () {
      expect(
        DeviceEventType.audioOutputRouteChanged,
        'audioOutputRouteChanged',
      );
    });

    test(
      're-probes the route when the default output device changes',
      () async {
        // The bleed warning used to be probed at exactly two moments, so
        // plugging in headphones mid-session left a stale warning up and
        // unplugging them showed no warning when it now applied.
        SharedPreferences.setMockInitialValues({});
        outputRoute = 'speakers';
        final controller = RecordingSettingsController(
          nativeBridge: NativeBridge.instance,
        );
        addTearDown(controller.dispose);
        await controller.loadPreferences(await SharedPreferences.getInstance());
        await controller.refreshAudioOutputRoute();
        expect(controller.audioOutputRoute, AudioOutputRoute.speakers);

        // Headphones go in — no toggle touched.
        outputRoute = 'headphones';
        await emitRouteChanged();

        for (var i = 0; i < 40; i++) {
          if (controller.audioOutputRoute == AudioOutputRoute.headphones) break;
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        expect(controller.audioOutputRoute, AudioOutputRoute.headphones);
      },
    );
  });
}
