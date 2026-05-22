import 'package:clingfy/core/models/app_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CanvasBackgroundPreset', () {
    const preset = CanvasBackgroundPreset(
      id: 'abstractWaves',
      palette: 'bluePurple',
      intensity: 0.7,
      blur: 0.35,
      seed: 42,
    );

    test('copyWith overrides only the provided fields', () {
      final next = preset.copyWith(seed: 99, intensity: 0.5);
      expect(next.id, 'abstractWaves');
      expect(next.palette, 'bluePurple');
      expect(next.intensity, 0.5);
      expect(next.blur, 0.35);
      expect(next.seed, 99);
    });

    test('value equality + hashCode', () {
      expect(preset, preset.copyWith());
      expect(preset.hashCode, preset.copyWith().hashCode);
      expect(preset == preset.copyWith(seed: 1), isFalse);
    });

    test('BackgroundKind.name matches the native wire values', () {
      expect(BackgroundKind.color.name, 'color');
      expect(BackgroundKind.image.name, 'image');
      expect(BackgroundKind.preset.name, 'preset');
    });
  });
}
