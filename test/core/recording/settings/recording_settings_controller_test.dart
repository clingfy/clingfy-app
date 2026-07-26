import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/bridges/native_method_channel.dart';
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

  setUp(() {
    calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'getExcludeRecorderApp':
          return false;
        case 'getExcludeMicFromSystemAudio':
          return true;
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
}
