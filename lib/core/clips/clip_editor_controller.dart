import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/timeline/post_state_store.dart';
import 'package:clingfy/core/logging/logger_service.dart';
import 'package:clingfy/core/timeline/clip_operations.dart';
import 'package:clingfy/core/timeline/clip_timeline.dart';
import 'package:clingfy/core/timeline/commands/set_clips_command.dart';
import 'package:clingfy/core/timeline/edit_session.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';

/// Which edge of a clip a trim drag is moving.
enum ClipTrimEdge { start, end }

/// Owns the editable clip list for one recording — split, cut, trim, and
/// arrange — over the shared [EditSession] undo/redo history, and pushes every
/// change to the live macOS preview via `previewSetClips`.
///
/// Mirrors [ZoomEditorController]'s shape (a `ChangeNotifier` created by
/// `PlayerController`, driven by the timeline lane), but clips are simpler: one
/// ordered list, single selection, no auto/manual merge. Built on the pure
/// PR-3a primitives ([ClipOperations] / [ClipTimeline] / [SetClipsCommand]) so
/// the logic stays testable without any UI or native player.
class ClipEditorController extends ChangeNotifier {
  ClipEditorController({
    required NativeBridge nativeBridge,
    required int durationMs,
    required String? sessionId,
    String? projectPath,
    Duration liveSyncInterval = const Duration(milliseconds: 16),
  }) : _nativeBridge = nativeBridge,
       _durationMs = durationMs < 0 ? 0 : durationMs,
       _sessionId = sessionId,
       _projectPath = projectPath,
       _liveSyncInterval = liveSyncInterval {
    final restored = _loadPersistedClipsOrSeed();
    _clips = restored;
    _session = EditSession(
      onFlush: (_) {
        unawaited(_syncToNative());
        _persistClips();
      },
    );
    // A restored edit must reach the native preview so the reopened recording
    // plays back its cuts. The default (whole recording) is native's starting
    // state, so only a non-trivial restore needs pushing.
    if (!ClipTimeline.isWholeRecording(_clips, _durationMs)) {
      unawaited(_syncToNative());
    }
  }

  final NativeBridge _nativeBridge;
  final int _durationMs;
  final String? _sessionId;
  final String? _projectPath;
  final Duration _liveSyncInterval;

  late List<Clip> _clips;
  late final EditSession _session;
  int _idCounter = 1;

  String? _selectedClipId;

  // Live trim-drag state — the pre-drag snapshot lets a whole drag collapse
  // into one undo entry, and lets every delta recompute from the original
  // (not the partially-dragged) clips so the trim never drifts.
  List<Clip>? _trimOriginalClips;
  String? _trimmingClipId;
  ClipTrimEdge? _trimEdge;
  Timer? _liveSyncTimer;

  // --- Getters ---

  /// The current clip list (read-only view).
  List<Clip> get clips => List<Clip>.unmodifiable(_clips);

  /// The original captured recording length — the trim ceiling.
  int get recordingDurationMs => _durationMs;

  /// The edited-timeline length (sum of kept clip durations).
  int get editedDurationMs => ClipTimeline.totalDurationMs(_clips);

  /// True once the user has split/trimmed away from the untouched recording.
  bool get hasCuts => !ClipTimeline.isWholeRecording(_clips, _durationMs);

  bool get canUndo => _session.canUndo;
  bool get canRedo => _session.canRedo;
  String? get selectedClipId => _selectedClipId;
  bool get isTrimming => _trimmingClipId != null;

  /// At least one enabled clip must always survive, so the last clip can't be
  /// deleted.
  bool get canDeleteSelected =>
      _selectedClipId != null &&
      _clips.where((c) => c.enabled).length > 1 &&
      _clips.any((c) => c.id == _selectedClipId);

  // --- Selection ---

  void selectClip(String? id) {
    if (_selectedClipId == id) return;
    _selectedClipId = id;
    notifyListeners();
  }

  // --- Discrete edits (each one undo entry) ---

  /// Splits the clip under [timelineMs] into two. No-op on a boundary or when a
  /// piece would be below the minimum duration.
  void splitAtPlayhead(int timelineMs) {
    final next = ClipOperations.splitAt(_clips, timelineMs, newId: _nextId());
    if (_sameClips(next, _clips)) return;
    _execute(next, 'Split');
  }

  /// Removes the selected clip and ripples the rest left.
  void deleteSelected() {
    final id = _selectedClipId;
    if (id == null || !canDeleteSelected) return;
    final next = ClipOperations.remove(_clips, id);
    _selectedClipId = null;
    _execute(next, 'Cut');
  }

  /// Moves a clip to [newIndex] in timeline order (arrange/reorder).
  void moveClipToIndex(String id, int newIndex) {
    final next = ClipOperations.moveToIndex(_clips, id, newIndex);
    if (_sameClips(next, _clips)) return;
    _execute(next, 'Reorder');
  }

  // --- Trim drag lifecycle (live preview, one undo entry) ---

  void beginTrim(String id, ClipTrimEdge edge) {
    // Self-heal a stranded trim: if a prior drag never committed/cancelled (e.g.
    // its gesture recognizer was disposed mid-drag when the lane rebuilt with
    // trim disabled), cancel it first so its live mutation is reverted instead
    // of being silently baked into this fresh snapshot with no undo entry.
    if (_trimmingClipId != null) cancelTrim();
    _trimOriginalClips = List<Clip>.of(_clips);
    _trimmingClipId = id;
    _trimEdge = edge;
    _selectedClipId = id;
    notifyListeners();
  }

  /// Updates the in-flight trim to the timeline position [timelineMs]. Recasts
  /// the drag point into a source bound for the clip and applies it to the
  /// pre-drag snapshot, so dragging is drift-free and live in the preview.
  void updateTrimTo(int timelineMs) {
    final id = _trimmingClipId;
    final edge = _trimEdge;
    final original = _trimOriginalClips;
    if (id == null || edge == null || original == null) return;

    Clip? orig;
    for (final c in original) {
      if (c.id == id) {
        orig = c;
        break;
      }
    }
    if (orig == null) return;

    // Inside a single clip, timeline time and source time advance 1:1, so the
    // dragged timeline point maps to this source position:
    final sourceAtPoint = orig.sourceInMs + (timelineMs - orig.timelineStartMs);

    final next = edge == ClipTrimEdge.start
        ? ClipOperations.trim(
            original,
            id,
            sourceInMs: sourceAtPoint,
            recordingDurationMs: _durationMs,
          )
        : ClipOperations.trim(
            original,
            id,
            sourceOutMs: sourceAtPoint,
            recordingDurationMs: _durationMs,
          );

    _clips = next;
    notifyListeners();
    _scheduleLiveSync();
  }

  /// Commits the trim as a single undo entry (or syncs without history if the
  /// drag was a no-op). Returns true when the drag actually changed the clips
  /// (an undo entry was pushed), false on a no-op — so callers can log the two
  /// cases distinctly.
  bool commitTrim() {
    final original = _trimOriginalClips;
    if (original == null) {
      _clearTrim();
      return false;
    }
    _liveSyncTimer?.cancel();
    final dragged = _clips;
    // Restore the pre-drag list so the command snapshots the right "previous",
    // then execute — apply() puts the dragged result back.
    _clips = original;
    final changed = !_sameClips(dragged, original);
    if (changed) {
      _execute(dragged, 'Trim');
    } else {
      unawaited(_syncToNative());
    }
    _clearTrim();
    return changed;
  }

  void cancelTrim() {
    final original = _trimOriginalClips;
    _liveSyncTimer?.cancel();
    if (original != null) {
      _clips = original;
      unawaited(_syncToNative());
    }
    _clearTrim();
    notifyListeners();
  }

  // --- History ---

  void undo() {
    if (!_session.canUndo) return;
    _session.undo();
    notifyListeners();
  }

  void redo() {
    if (!_session.canRedo) return;
    _session.redo();
    notifyListeners();
  }

  // --- Internals ---

  void _execute(List<Clip> next, String label) {
    _session.execute(
      SetClipsCommand(
        get: () => _clips,
        set: (v) => _clips = v,
        next: next,
        label: label,
      ),
    );
    notifyListeners();
  }

  void _clearTrim() {
    _trimOriginalClips = null;
    _trimmingClipId = null;
    _trimEdge = null;
  }

  String _nextId() => 'clip_${_idCounter++}';

  bool _sameClips(List<Clip> a, List<Clip> b) => listEquals(a, b);

  void _scheduleLiveSync() {
    if (_liveSyncTimer?.isActive ?? false) return;
    unawaited(_syncToNative());
    _liveSyncTimer = Timer(_liveSyncInterval, () {});
  }

  Future<void> _syncToNative() async {
    try {
      await _nativeBridge.previewSetClips(clips: _clips, sessionId: _sessionId);
    } catch (e, st) {
      // Preview-only path: a failed push must not break editing.
      Log.w('Clips', 'previewSetClips push failed', e, st);
    }
  }

  /// Re-push the current clips to a preview session that was rebuilt in
  /// place (Windows `previewInvalidated` — the reopened native session
  /// starts with the uncut timeline).
  Future<void> resyncToNative() => _syncToNative();

  /// Restores the persisted clips for this recording, or seeds the whole
  /// recording when there is nothing valid to restore. Also advances the id
  /// counter past any restored ids so new splits never collide with them.
  List<Clip> _loadPersistedClipsOrSeed() {
    final seed = [ClipTimeline.wholeRecording(_durationMs)];
    final path = _projectPath;
    if (path == null || _durationMs <= 0) return seed;

    final persisted = PostStateStore.load(path).trackOfType<ClipTrack>();
    if (persisted == null) return seed;

    final restored = _sanitizePersistedClips(persisted.clips);
    if (restored == null) return seed;

    _advanceIdCounterPast(restored);
    return restored;
  }

  /// Validates restored clips against the current recording. Rejects (returns
  /// null → fall back to the whole-recording seed) anything that could not have
  /// come from this recording: an empty list, no surviving enabled clip, an
  /// inverted/negative range, or a source bound past the recording length
  /// (beyond a small tolerance for ms rounding).
  ///
  /// The accepted list is re-normalized (gap-free, contiguous `timelineStartMs`
  /// in clip order — the invariant every [ClipOperations] result already
  /// satisfies) so a hand-edited or corrupted file with a stale layout still
  /// restores to a clean, playable timeline. Ids are preserved.
  List<Clip>? _sanitizePersistedClips(List<Clip> clips) {
    if (clips.isEmpty) return null;
    if (!clips.any((c) => c.enabled)) return null;
    const toleranceMs = 250;
    for (final c in clips) {
      if (c.sourceInMs < 0) return null;
      if (c.sourceOutMs <= c.sourceInMs) return null;
      if (c.sourceOutMs > _durationMs + toleranceMs) return null;
    }
    return ClipTimeline.normalized(clips);
  }

  void _advanceIdCounterPast(List<Clip> clips) {
    final pattern = RegExp(r'clip_(\d+)$');
    var maxSuffix = 0;
    for (final c in clips) {
      final match = pattern.firstMatch(c.id);
      if (match == null) continue;
      final suffix = int.tryParse(match.group(1)!) ?? 0;
      if (suffix > maxSuffix) maxSuffix = suffix;
    }
    if (maxSuffix >= _idCounter) _idCounter = maxSuffix + 1;
  }

  /// Persists the current committed clip list. Fire-and-forget, best-effort —
  /// invoked from [EditSession.onFlush], i.e. only on committed history changes
  /// (split / cut / trim-commit / reorder / undo / redo), never on the
  /// high-frequency live-trim ticks.
  void _persistClips() {
    final path = _projectPath;
    if (path == null) return;
    unawaited(
      PostStateStore.update(
        path,
        // Read-modify-write inside the store's queue: this file also holds the
        // transcript and the canvas, and a plain save would drop whichever of
        // those was written in the same moment.
        (state) => state
            .copyWith(durationMs: _durationMs)
            .withTrack(ClipTrack(clips: _clips)),
      ),
    );
  }

  @override
  void dispose() {
    _liveSyncTimer?.cancel();
    super.dispose();
  }
}
