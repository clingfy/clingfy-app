import 'package:clingfy/core/timeline/edit_command.dart';

/// Owns the editing timeline's undo/redo history.
///
/// Generalizes `ZoomEditorController`'s old private `_history` list into a
/// reusable, track-agnostic session:
///
/// * one **global** undo stack (so a future caption edit and a zoom edit undo
///   in the order the user made them),
/// * **redo** (new — the old controller had none),
/// * **batched transactions** so a drag or a multi-field change collapses into a
///   single history entry, and
/// * a **dirty-domain flush** so only the domains an edit touched are re-synced
///   to the native preview, via the [onFlush] callback.
///
/// Commands are imperative ([EditCommand.apply] / [EditCommand.revert]); this
/// session does not know about any concrete track type.
class EditSession {
  EditSession({void Function(Set<EditDomain> dirtyDomains)? onFlush})
    : _onFlush = onFlush;

  final void Function(Set<EditDomain> dirtyDomains)? _onFlush;

  final List<EditCommand> _undo = <EditCommand>[];
  final List<EditCommand> _redo = <EditCommand>[];

  int _batchDepth = 0;
  final List<EditCommand> _batch = <EditCommand>[];
  final Set<EditDomain> _dirty = <EditDomain>{};

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// True while a [beginBatch]/[endBatch] transaction is open.
  bool get isBatching => _batchDepth > 0;

  /// Applies [cmd] and records it. Inside a batch the command is buffered into
  /// the in-flight transaction instead of pushing its own history entry.
  /// Executing a new command outside a batch clears the redo stack.
  void execute(EditCommand cmd) {
    cmd.apply();
    if (_batchDepth > 0) {
      _batch.add(cmd);
    } else {
      _undo.add(cmd);
      _redo.clear();
    }
    _markDirty(cmd.domain);
    if (_batchDepth == 0) _flush();
  }

  /// Begins a transaction. Commands executed until the matching [endBatch]
  /// collapse into a single [CompositeCommand] history entry. Batches nest;
  /// the entry is recorded only when the outermost batch ends.
  void beginBatch() => _batchDepth++;

  /// Ends a transaction, pushing one composite history entry for everything
  /// executed since the outermost [beginBatch]. A no-op (no history entry) if
  /// nothing was executed in the batch.
  void endBatch({String label = 'edit'}) {
    if (_batchDepth == 0) return;
    _batchDepth--;
    if (_batchDepth > 0) return; // still inside a nested batch
    if (_batch.isEmpty) {
      _flush();
      return;
    }
    final composite = CompositeCommand(
      List<EditCommand>.of(_batch),
      label: label,
    );
    _batch.clear();
    _undo.add(composite);
    _redo.clear();
    _flush();
  }

  /// Cancels the in-flight transaction, reverting everything executed since
  /// [beginBatch] without leaving a history entry.
  void cancelBatch() {
    if (_batchDepth == 0) return;
    _batchDepth = 0;
    if (_batch.isEmpty) return;
    for (final command in _batch.reversed) {
      command.revert();
      _markDirty(command.domain);
    }
    _batch.clear();
    _flush();
  }

  void undo() {
    if (_undo.isEmpty) return;
    final cmd = _undo.removeLast();
    cmd.revert();
    _redo.add(cmd);
    _markDirty(cmd.domain);
    _flush();
  }

  void redo() {
    if (_redo.isEmpty) return;
    final cmd = _redo.removeLast();
    cmd.apply();
    _undo.add(cmd);
    _markDirty(cmd.domain);
    _flush();
  }

  /// Drops all history (e.g. when loading a different project).
  void clear() {
    _undo.clear();
    _redo.clear();
    _batch.clear();
    _batchDepth = 0;
    _dirty.clear();
  }

  void _markDirty(EditDomain domain) => _dirty.add(domain);

  void _flush() {
    if (_dirty.isEmpty) return;
    final dirty = Set<EditDomain>.of(_dirty);
    _dirty.clear();
    _onFlush?.call(dirty);
  }
}
