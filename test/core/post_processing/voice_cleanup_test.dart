import 'package:clingfy/core/post_processing/settings/post_processing_settings_controller.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Voice cleanup ships opt-in and OFF by default, and its wire values are
/// shared with the Swift `VoiceCleanupMode`. Both are pinned here: a silent
/// default flip would run a lossy DSP pass on everyone's voice, and a wire
/// mismatch would no-op natively with no error.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CleanupMode wire contract', () {
    test('wire values match the Swift VoiceCleanupMode raw values', () {
      expect(CleanupMode.light.wire, 'light');
      expect(CleanupMode.balanced.wire, 'balanced');
      expect(CleanupMode.highQuality.wire, 'highQuality');
    });

    test('unknown wire values fall back to balanced, as Swift does', () {
      expect(CleanupMode.fromWire('ultra'), CleanupMode.balanced);
      expect(CleanupMode.fromWire(null), CleanupMode.balanced);
      expect(CleanupMode.fromWire(42), CleanupMode.balanced);
    });
  });

  group('VoiceCleanup model', () {
    test('defaults to disabled', () {
      const cleanup = VoiceCleanup();
      expect(cleanup.enabled, isFalse);
      expect(cleanup.mode, CleanupMode.balanced);
    });

    test('serializes the shape the native side parses', () {
      const cleanup = VoiceCleanup(enabled: true, mode: CleanupMode.light);
      expect(cleanup.toMap(), {'enabled': true, 'mode': 'light'});
    });

    test('round-trips through its map form', () {
      const cleanup = VoiceCleanup(
        enabled: true,
        mode: CleanupMode.highQuality,
      );
      expect(VoiceCleanup.fromMap(cleanup.toMap()), cleanup);
    });

    test(
      'is compared by value so unchanged settings do not push to native',
      () {
        expect(
          const VoiceCleanup(enabled: true, mode: CleanupMode.light),
          const VoiceCleanup(enabled: true, mode: CleanupMode.light),
        );
        expect(
          const VoiceCleanup(enabled: true, mode: CleanupMode.light),
          isNot(const VoiceCleanup(enabled: true, mode: CleanupMode.balanced)),
        );
      },
    );

    test('copyWith changes one field at a time', () {
      const cleanup = VoiceCleanup();
      expect(cleanup.copyWith(enabled: true).mode, CleanupMode.balanced);
      expect(cleanup.copyWith(mode: CleanupMode.light).enabled, isFalse);
    });
  });

  group('PostProcessingSettingsController persistence', () {
    test('defaults to off with no stored value', () async {
      SharedPreferences.setMockInitialValues({});
      final controller = PostProcessingSettingsController();
      await controller.loadPreferences(await SharedPreferences.getInstance());

      expect(controller.postVoiceCleanup.enabled, isFalse);
      expect(controller.postVoiceCleanup.mode, CleanupMode.balanced);
    });

    test('restores a stored setting', () async {
      SharedPreferences.setMockInitialValues({
        'postVoiceCleanupEnabled': true,
        'postVoiceCleanupMode': 'light',
      });
      final controller = PostProcessingSettingsController();
      await controller.loadPreferences(await SharedPreferences.getInstance());

      expect(controller.postVoiceCleanup.enabled, isTrue);
      expect(controller.postVoiceCleanup.mode, CleanupMode.light);
    });

    test('an unrecognized stored mode falls back to balanced', () async {
      SharedPreferences.setMockInitialValues({
        'postVoiceCleanupEnabled': true,
        'postVoiceCleanupMode': 'from-a-newer-build',
      });
      final controller = PostProcessingSettingsController();
      await controller.loadPreferences(await SharedPreferences.getInstance());

      expect(controller.postVoiceCleanup.mode, CleanupMode.balanced);
    });

    test('updating persists both fields and notifies', () async {
      SharedPreferences.setMockInitialValues({});
      final controller = PostProcessingSettingsController();
      await controller.loadPreferences(await SharedPreferences.getInstance());

      var notified = 0;
      controller.addListener(() => notified++);

      await controller.updatePostVoiceCleanup(
        const VoiceCleanup(enabled: true, mode: CleanupMode.light),
      );

      expect(notified, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('postVoiceCleanupEnabled'), isTrue);
      expect(prefs.getString('postVoiceCleanupMode'), 'light');
    });

    test('setting the same value is a no-op', () async {
      SharedPreferences.setMockInitialValues({});
      final controller = PostProcessingSettingsController();
      await controller.loadPreferences(await SharedPreferences.getInstance());

      var notified = 0;
      controller.addListener(() => notified++);
      await controller.updatePostVoiceCleanup(const VoiceCleanup());

      expect(notified, 0);
    });
  });
}
