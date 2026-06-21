/// The track/domain an [EditCommand] mutates, so the [EditSession] can re-sync
/// only the affected native preview channel after an edit instead of rebuilding
/// everything.
enum EditDomain { zoom, clips, captions, audio, color }

/// A single reversible edit on the editing timeline.
///
/// Generalizes the original zoom-only command pattern so every track shares one
/// undo/redo stack. Commands stay imperative (`apply`/`revert`) for now; a later
/// foundation step migrates them to pure reducers over an immutable timeline.
abstract class EditCommand {
  /// Applies the edit. Called on first `execute` and again on `redo`.
  void apply();

  /// Reverses the edit, restoring the state captured before [apply].
  void revert();

  /// Which domain this edit touches (drives the dirty-domain flush).
  EditDomain get domain;

  /// Short human-readable label (e.g. for an undo menu entry).
  String get label;
}

/// Groups several commands into one undoable/redoable unit — e.g. a drag that
/// produces many intermediate edits, or a multi-field change, collapses into a
/// single history entry.
class CompositeCommand implements EditCommand {
  CompositeCommand(List<EditCommand> commands, {required this.label})
    : commands = List<EditCommand>.unmodifiable(commands);

  final List<EditCommand> commands;

  @override
  final String label;

  @override
  EditDomain get domain =>
      commands.isEmpty ? EditDomain.zoom : commands.first.domain;

  @override
  void apply() {
    for (final command in commands) {
      command.apply();
    }
  }

  @override
  void revert() {
    for (final command in commands.reversed) {
      command.revert();
    }
  }
}
