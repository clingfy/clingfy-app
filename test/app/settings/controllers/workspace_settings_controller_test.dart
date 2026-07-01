import 'package:clingfy/app/settings/controllers/workspace_settings_controller.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/bridges/native_method_channel.dart';
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
      if (call.method == 'getSaveFolder') return '/tmp/clingfy';
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  List<MethodCall> logLevelPushes() =>
      calls.where((c) => c.method == 'setNativeLogLevel').toList();

  test('setVerboseLogging persists and pushes the level to native', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = WorkspaceSettingsController(
      nativeBridge: NativeBridge.instance,
    );
    expect(controller.verboseLogging, isFalse);

    await controller.setVerboseLogging(true);

    expect(controller.verboseLogging, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('verboseLogging'), isTrue);

    final pushes = logLevelPushes();
    expect(pushes, hasLength(1));
    expect((pushes.single.arguments as Map)['level'], 'debug');
  });

  test(
    'setVerboseLogging(false) restores the default level on native',
    () async {
      SharedPreferences.setMockInitialValues({'verboseLogging': true});
      final controller = WorkspaceSettingsController(
        nativeBridge: NativeBridge.instance,
      );
      final prefs = await SharedPreferences.getInstance();
      await controller.loadPreferences(prefs);
      expect(controller.verboseLogging, isTrue);

      await controller.setVerboseLogging(false);

      expect(controller.verboseLogging, isFalse);
      expect(prefs.getBool('verboseLogging'), isFalse);
      // The most recent push restores the default (a concrete level name).
      expect(logLevelPushes(), isNotEmpty);
      expect((logLevelPushes().last.arguments as Map)['level'], isA<String>());
    },
  );

  test('loadPreferences pushes the native level when verbose is on', () async {
    SharedPreferences.setMockInitialValues({'verboseLogging': true});
    final controller = WorkspaceSettingsController(
      nativeBridge: NativeBridge.instance,
    );
    final prefs = await SharedPreferences.getInstance();

    await controller.loadPreferences(prefs);

    expect(controller.verboseLogging, isTrue);
    final pushes = logLevelPushes();
    expect(pushes, isNotEmpty);
    expect((pushes.last.arguments as Map)['level'], 'debug');
  });

  test('loadPreferences does not force a level when verbose is off', () async {
    SharedPreferences.setMockInitialValues({'verboseLogging': false});
    final controller = WorkspaceSettingsController(
      nativeBridge: NativeBridge.instance,
    );
    final prefs = await SharedPreferences.getInstance();

    await controller.loadPreferences(prefs);

    expect(controller.verboseLogging, isFalse);
    // Off → leave the startup-resolved level (env/build default) untouched.
    expect(logLevelPushes(), isEmpty);
  });
}
