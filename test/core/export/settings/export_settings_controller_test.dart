import 'package:clingfy/core/export/models/export_settings_types.dart';
import 'package:clingfy/core/export/settings/export_settings_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('gifSize defaults to large before any preference is loaded', () {
    final controller = ExportSettingsController();
    expect(controller.gifSize, GifSizePreset.large.wireValue);
    expect(controller.gifSizeType, GifSizePreset.large);
  });

  test('loadPreferences restores a persisted gifSize', () async {
    SharedPreferences.setMockInitialValues({'gifSize': 'small'});
    final controller = ExportSettingsController();
    await controller.loadPreferences(await SharedPreferences.getInstance());
    expect(controller.gifSizeType, GifSizePreset.small);
  });

  test('loadPreferences falls back to large for an unknown gifSize', () async {
    // Corrupt / future value must not throw and must render the shipped default.
    SharedPreferences.setMockInitialValues({'gifSize': 'gigantic'});
    final controller = ExportSettingsController();
    await controller.loadPreferences(await SharedPreferences.getInstance());
    expect(controller.gifSizeType, GifSizePreset.large);
  });

  test(
    'a missing gifSize key loads as large (backward compatibility)',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = ExportSettingsController();
      await controller.loadPreferences(await SharedPreferences.getInstance());
      expect(controller.gifSizeType, GifSizePreset.large);
    },
  );

  test('updateGifSize persists and notifies exactly once per change', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = ExportSettingsController();
    await controller.loadPreferences(await SharedPreferences.getInstance());

    var notifications = 0;
    controller.addListener(() => notifications++);

    await controller.updateGifSizeType(GifSizePreset.medium);
    expect(controller.gifSizeType, GifSizePreset.medium);
    expect(notifications, 1);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('gifSize'), 'medium');

    // Re-setting the same value is a no-op (no extra notification / write).
    await controller.updateGifSizeType(GifSizePreset.medium);
    expect(notifications, 1);
  });

  group('audioQuality', () {
    test('defaults to standard, which is what macOS already exports', () {
      final c = ExportSettingsController();
      expect(c.audioQuality, 'standard');
      expect(c.audioQualityType, AudioQuality.standard);
      c.dispose();
    });

    test('loads a stored value and ignores a bad one', () async {
      SharedPreferences.setMockInitialValues({'audioQuality': 'best'});
      final c = ExportSettingsController();
      await c.loadPreferences(await SharedPreferences.getInstance());
      expect(c.audioQualityType, AudioQuality.best);
      c.dispose();

      SharedPreferences.setMockInitialValues({'audioQuality': 'wat'});
      final d = ExportSettingsController();
      await d.loadPreferences(await SharedPreferences.getInstance());
      expect(d.audioQualityType, AudioQuality.standard);
      d.dispose();
    });

    test('persists under the key the wire uses, and notifies', () async {
      SharedPreferences.setMockInitialValues({});
      final c = ExportSettingsController();
      var notifications = 0;
      c.addListener(() => notifications++);

      await c.updateAudioQualityType(AudioQuality.high);
      expect(c.audioQuality, 'high');
      expect(notifications, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('audioQuality'), 'high');

      // Setting the same value again is a no-op: no notify, no write.
      await c.updateAudioQuality('high');
      expect(notifications, 1);
      c.dispose();
    });
  });
}
