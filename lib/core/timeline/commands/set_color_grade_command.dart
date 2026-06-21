import 'package:clingfy/core/timeline/edit_command.dart';
import 'package:clingfy/core/timeline/model/color_grade.dart';

/// Undoable change of the canvas-wide color grade.
///
/// Closure-based so it works with any state holder: the holder passes [get] /
/// [set], and the command snapshots the previous grade at construction so
/// [revert] restores it. The post-processing controller wires these in the
/// macOS render PR; here it is fully unit-testable on its own.
class SetColorGradeCommand implements EditCommand {
  SetColorGradeCommand({
    required ColorGrade Function() get,
    required void Function(ColorGrade) set,
    required ColorGrade next,
    this.label = 'Color',
  }) : _set = set,
       _next = next,
       _previous = get();

  final void Function(ColorGrade) _set;
  final ColorGrade _next;
  final ColorGrade _previous;

  @override
  final String label;

  @override
  EditDomain get domain => EditDomain.color;

  @override
  void apply() => _set(_next);

  @override
  void revert() => _set(_previous);
}
