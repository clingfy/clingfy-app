import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/bridges/native_method_channel.dart';
import 'package:clingfy/core/updater/windows_update_feed.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../test_helpers/native_test_setup.dart';

/// Phase 10.6 — Dart half of the Windows update-check contract:
///   * checkForUpdates attaches {feedUrl, channel} args on Windows only
///   * updater-channel events surface on NativeBridge.updaterEvents and
///     type=updateAvailable still flips isUpdateAvailable (macOS parity)
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final captured = <MethodCall>[];

  setUp(() async {
    await installCommonNativeMocks();
    captured.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(screenRecorderChannel, (call) async {
          captured.add(call);
          if (call.method == 'checkForUpdates') {
            return true;
          }
          return null;
        });
    NativeBridge.instance.isUpdateAvailable.value = false;
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await clearCommonNativeMocks();
  });

  Future<void> emitUpdaterEvent(Map<String, dynamic> event) async {
    const codec = StandardMethodCodec();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          NativeChannel.updaterEvents,
          codec.encodeSuccessEnvelope(event),
          (_) {},
        );
  }

  group('checkForUpdates args', () {
    test('attaches feedUrl + channel on Windows', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final started = await NativeBridge.instance.checkForUpdates(
        feedUrl: 'https://feed.example/latest-windows.json',
        channel: 'dev',
      );
      expect(started, isTrue);
      final call = captured.singleWhere((c) => c.method == 'checkForUpdates');
      expect(call.arguments, {
        'feedUrl': 'https://feed.example/latest-windows.json',
        'channel': 'dev',
      });
    });

    test('bare call mirrors the build-time define on Windows', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await NativeBridge.instance.checkForUpdates();
      final call = captured.singleWhere((c) => c.method == 'checkForUpdates');
      if (windowsUpdateCdnEndpointDefine.isEmpty) {
        // Bare `flutter test`: no define -> no args; native replies false
        // + an updateError event, never a silent no-op.
        expect(call.arguments, isNull);
      } else {
        // --dart-define-from-file run: args auto-filled from the define.
        expect(
          (call.arguments as Map)['feedUrl'],
          defaultWindowsUpdateFeedUrl(),
        );
      }
    });

    test('never attaches args on macOS — Sparkle owns the feed', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await NativeBridge.instance.checkForUpdates(
        feedUrl: 'https://feed.example/latest-windows.json',
      );
      final call = captured.singleWhere((c) => c.method == 'checkForUpdates');
      expect(call.arguments, isNull);
    });
  });

  group('updater event stream', () {
    test('updateAvailable surfaces on the stream and flips the flag', () async {
      expect(NativeBridge.instance.isUpdateAvailable.value, isFalse);
      final next = NativeBridge.instance.updaterEvents.first;
      await emitUpdaterEvent(const {
        'type': 'updateAvailable',
        'version': '1.0.5',
        'build': '7',
        'url': 'https://dl.example/Clingfy_Dev_Setup_1.0.5+7.exe',
        'versionFull': '1.0.5+7',
      });
      final event = await next;
      expect(event['type'], 'updateAvailable');
      expect(event['version'], '1.0.5');
      expect(event['url'], 'https://dl.example/Clingfy_Dev_Setup_1.0.5+7.exe');
      expect(NativeBridge.instance.isUpdateAvailable.value, isTrue);
    });

    test(
      'non-updateAvailable types stream through without flipping the flag',
      () async {
        expect(NativeBridge.instance.isUpdateAvailable.value, isFalse);
        final next = NativeBridge.instance.updaterEvents.first;
        await emitUpdaterEvent(const {
          'type': 'noUpdateAvailable',
          'version': '1.0.4',
        });
        final event = await next;
        expect(event['type'], 'noUpdateAvailable');
        expect(NativeBridge.instance.isUpdateAvailable.value, isFalse);
      },
    );
  });
}
