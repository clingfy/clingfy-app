import 'package:flutter_test/flutter_test.dart';
import 'package:clingfy/core/color/auto_grade_heuristic.dart';
import 'package:clingfy/core/timeline/commands/set_color_grade_command.dart';
import 'package:clingfy/core/timeline/edit_command.dart';
import 'package:clingfy/core/timeline/edit_session.dart';
import 'package:clingfy/core/timeline/model/color_grade.dart';

void main() {
  group('SetColorGradeCommand', () {
    test('apply sets the next grade, revert restores the previous', () {
      var grade = const ColorGrade();
      final cmd = SetColorGradeCommand(
        get: () => grade,
        set: (g) => grade = g,
        next: autoEnhanceGrade(),
      );

      cmd.apply();
      expect(grade.autoEnabled, isTrue);
      expect(grade.contrast, greaterThan(0));

      cmd.revert();
      expect(grade.autoEnabled, isFalse);
      expect(grade.isIdentity, isTrue);
    });

    test('reports the color domain', () {
      var grade = const ColorGrade();
      final cmd = SetColorGradeCommand(
        get: () => grade,
        set: (g) => grade = g,
        next: const ColorGrade(exposure: 0.2),
      );
      expect(cmd.domain, EditDomain.color);
    });

    test('round-trips through EditSession undo/redo and flushes color', () {
      var grade = const ColorGrade();
      final flushed = <Set<EditDomain>>[];
      final session = EditSession(onFlush: flushed.add);

      session.execute(
        SetColorGradeCommand(
          get: () => grade,
          set: (g) => grade = g,
          next: const ColorGrade(exposure: 0.5, contrast: 0.25),
        ),
      );
      expect(grade.exposure, 0.5);
      expect(session.canUndo, isTrue);
      expect(flushed.single, {EditDomain.color});

      session.undo();
      expect(grade.isIdentity, isTrue);
      expect(session.canRedo, isTrue);

      session.redo();
      expect(grade.exposure, 0.5);
      expect(grade.contrast, 0.25);
    });
  });
}
