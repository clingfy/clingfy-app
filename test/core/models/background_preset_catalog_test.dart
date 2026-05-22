import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/models/background_preset_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BackgroundPresetCatalog', () {
    test('palette lookup returns the requested palette', () {
      expect(BackgroundPresetCatalog.palette('sunset').id, 'sunset');
      expect(BackgroundPresetCatalog.palette('mono').id, 'mono');
    });

    test('unknown palette falls back to the default', () {
      expect(
        BackgroundPresetCatalog.palette('does-not-exist').id,
        BackgroundPresetCatalog.defaultPaletteId,
      );
    });

    test('every palette has a non-empty color list', () {
      expect(BackgroundPresetCatalog.palettes, isNotEmpty);
      for (final palette in BackgroundPresetCatalog.palettes) {
        expect(palette.colors, isNotEmpty, reason: palette.id);
      }
    });

    test('defaultPreset is a valid abstractWaves preset', () {
      final preset = BackgroundPresetCatalog.defaultPreset();
      expect(preset, isA<CanvasBackgroundPreset>());
      expect(preset.id, 'abstractWaves');
      expect(BackgroundPresetCatalog.presetIds, contains(preset.id));
      expect(preset.palette, BackgroundPresetCatalog.defaultPaletteId);
      expect(preset.intensity, inInclusiveRange(0.0, 1.0));
      expect(preset.blur, inInclusiveRange(0.0, 1.0));
    });

    test('the default palette id resolves to a real palette', () {
      expect(
        BackgroundPresetCatalog.palette(
          BackgroundPresetCatalog.defaultPaletteId,
        ).id,
        BackgroundPresetCatalog.defaultPaletteId,
      );
    });
  });
}
