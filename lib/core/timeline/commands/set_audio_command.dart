import 'package:clingfy/core/timeline/edit_command.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';

/// Undoable change of the recording's audio settings.
///
/// Closure-based like [SetColorGradeCommand]: the holder passes [get] / [set]
/// and the command snapshots the previous track at construction so [revert]
/// restores it. `PostProcessingController` executes these through its audio
/// [EditSession].
///
/// One command covers gain, master volume and voice cleanup because they are
/// one value object ([AudioTrack]) and the user thinks of them as one panel.
/// Splitting them would mean three commands racing for the same undo slot on
/// a gesture that touches two of them.
class SetAudioCommand implements EditCommand {
  SetAudioCommand({
    required AudioTrack Function() get,
    required void Function(AudioTrack) set,
    required AudioTrack next,
    this.label = 'Audio',
  }) : _set = set,
       _next = next,
       _previous = get();

  final void Function(AudioTrack) _set;
  final AudioTrack _next;
  final AudioTrack _previous;

  @override
  final String label;

  @override
  EditDomain get domain => EditDomain.audio;

  @override
  void apply() => _set(_next);

  @override
  void revert() => _set(_previous);
}
