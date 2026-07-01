import 'package:clingfy/core/timeline/edit_command.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';

/// Undoable replacement of the clip list (split / cut / trim / arrange).
///
/// Closure-based so it works with any state holder: the holder passes [get] /
/// [set], and the command snapshots the previous clip list at construction so
/// [revert] restores it exactly. The post-processing controller wires these in
/// the macOS render PR; here it is fully unit-testable on its own. Mirrors
/// [SetColorGradeCommand] — every clip operation produces a `next` list and is
/// wrapped in one of these for the shared undo/redo stack.
class SetClipsCommand implements EditCommand {
  SetClipsCommand({
    required List<Clip> Function() get,
    required void Function(List<Clip>) set,
    required List<Clip> next,
    this.label = 'Clips',
  }) : _set = set,
       _next = List<Clip>.unmodifiable(next),
       _previous = List<Clip>.unmodifiable(get());

  final void Function(List<Clip>) _set;
  final List<Clip> _next;
  final List<Clip> _previous;

  @override
  final String label;

  @override
  EditDomain get domain => EditDomain.clips;

  @override
  void apply() => _set(_next);

  @override
  void revert() => _set(_previous);
}
