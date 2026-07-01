import 'package:clingfy/core/timeline/model/color_grade.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ColorGrade value equality', () {
    test('two grades with identical fields are equal and hash the same', () {
      const a = ColorGrade(
        autoEnabled: true,
        exposure: 0.2,
        contrast: -0.1,
        saturation: 0.3,
        temperature: 0.05,
        tint: -0.02,
      );
      const b = ColorGrade(
        autoEnabled: true,
        exposure: 0.2,
        contrast: -0.1,
        saturation: 0.3,
        temperature: 0.05,
        tint: -0.02,
      );

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('copyWith that changes a field is not equal to the original', () {
      const base = ColorGrade();
      // This is exactly what the color setters do; the provider Selector relies
      // on this inequality to rebuild the sliders.
      final changed = base.copyWith(exposure: 0.4);

      expect(changed, isNot(equals(base)));
      expect(changed.exposure, 0.4);
    });

    test('copyWith with the same value stays equal to the original', () {
      const base = ColorGrade(exposure: 0.4);
      final same = base.copyWith(exposure: 0.4);

      expect(same, equals(base));
    });

    test('autoEnabled participates in equality', () {
      const off = ColorGrade(exposure: 0.1);
      const on = ColorGrade(exposure: 0.1, autoEnabled: true);

      expect(on, isNot(equals(off)));
    });

    test('round-trips through toMap/fromMap preserving equality', () {
      const grade = ColorGrade(
        autoEnabled: true,
        exposure: -0.5,
        contrast: 0.25,
        saturation: -0.75,
        temperature: 0.6,
        tint: -0.3,
      );

      expect(ColorGrade.fromMap(grade.toMap()), equals(grade));
    });
  });
}
