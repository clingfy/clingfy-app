import 'package:flutter_test/flutter_test.dart';
import 'package:clingfy/core/color/auto_grade_heuristic.dart';
import 'package:clingfy/core/timeline/model/color_grade.dart';

void main() {
  group('autoEnhanceGrade', () {
    test('full intensity returns a gentle positive lift, flagged auto', () {
      final g = autoEnhanceGrade();
      expect(g.autoEnabled, isTrue);
      expect(g.exposure, greaterThan(0));
      expect(g.contrast, greaterThan(0));
      expect(g.saturation, greaterThan(0));
      expect(g.temperature, 0);
      expect(g.tint, 0);
      expect(g.isIdentity, isFalse);
    });

    test('intensity scales the deltas linearly', () {
      final full = autoEnhanceGrade();
      final half = autoEnhanceGrade(intensity: 0.5);
      expect(half.contrast, closeTo(full.contrast / 2, 1e-9));
      expect(half.saturation, closeTo(full.saturation / 2, 1e-9));
      expect(half.exposure, closeTo(full.exposure / 2, 1e-9));
    });

    test('intensity is clamped to [0, 1]', () {
      expect(
        autoEnhanceGrade(intensity: 5).contrast,
        autoEnhanceGrade().contrast,
      );
      final zero = autoEnhanceGrade(intensity: -1);
      expect(zero.exposure, 0);
      expect(zero.contrast, 0);
      expect(zero.autoEnabled, isTrue); // auto-on even at neutral
    });
  });

  group('clampColorGrade', () {
    test('clamps out-of-range fields into [-1, 1] and preserves auto flag', () {
      const wild = ColorGrade(
        autoEnabled: true,
        exposure: 5,
        contrast: -3,
        saturation: 2,
        temperature: -9,
        tint: 1.5,
      );
      final c = clampColorGrade(wild);
      expect(c.autoEnabled, isTrue);
      expect(c.exposure, ColorGradeRanges.max);
      expect(c.contrast, ColorGradeRanges.min);
      expect(c.saturation, ColorGradeRanges.max);
      expect(c.temperature, ColorGradeRanges.min);
      expect(c.tint, ColorGradeRanges.max);
    });

    test('leaves in-range values unchanged', () {
      const grade = ColorGrade(exposure: 0.3, contrast: -0.2, saturation: 0.1);
      final c = clampColorGrade(grade);
      expect(c.exposure, 0.3);
      expect(c.contrast, -0.2);
      expect(c.saturation, 0.1);
    });
  });
}
