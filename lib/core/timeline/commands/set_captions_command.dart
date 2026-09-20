import 'package:clingfy/core/timeline/edit_command.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';

/// Undoable replacement of the caption cue list.
///
/// Closure-based like [SetColorGradeCommand], so the command works with any
/// state holder: the holder passes [get] / [set] and the command snapshots the
/// previous list at construction so [revert] restores it.
/// `PostProcessingController` executes these through its captions
/// [EditSession].
///
/// Deliberately whole-list rather than per-cue. A correction is one cue's text
/// today, but the destructive edit users actually hit is "Generate again",
/// which replaces the track wholesale — and a per-cue command cannot revert
/// that. Snapshotting the list keeps both shapes on the same stack, and the
/// lists are small (a cue per sentence, a few hundred at most) and immutable,
/// so the copy costs a pointer array rather than the cues themselves.
class SetCaptionsCommand implements EditCommand {
  SetCaptionsCommand({
    required List<Caption> Function() get,
    required void Function(List<Caption>) set,
    required List<Caption> next,
    this.label = 'Captions',
  }) : _set = set,
       _next = List<Caption>.unmodifiable(next),
       _previous = List<Caption>.unmodifiable(get());

  final void Function(List<Caption>) _set;
  final List<Caption> _next;
  final List<Caption> _previous;

  @override
  final String label;

  @override
  EditDomain get domain => EditDomain.captions;

  @override
  void apply() => _set(List<Caption>.from(_next));

  @override
  void revert() => _set(List<Caption>.from(_previous));
}
