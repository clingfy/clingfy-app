import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:uuid/uuid.dart';

abstract class ZoomEditCommand {
  void apply();
  void revert();
}

class AddZoomSegmentCommand implements ZoomEditCommand {
  final ZoomEditorController controller;
  final ZoomSegment segment;

  AddZoomSegmentCommand(this.controller, this.segment);

  @override
  void apply() {
    controller._addManualSegment(segment);
  }

  @override
  void revert() {
    controller._removeManualSegment(segment.id);
  }
}

class MoveZoomSegmentCommand implements ZoomEditCommand {
  final ZoomEditorController controller;
  final ZoomSegment oldSegment;
  final ZoomSegment newSegment;
  late final List<ZoomSegment> _previousManualSegments;

  MoveZoomSegmentCommand(this.controller, this.oldSegment, this.newSegment) {
    _previousManualSegments = List<ZoomSegment>.from(controller.manualSegments);
  }

  @override
  void apply() {
    if (oldSegment.source == 'manual') {
      controller._updateManualSegment(newSegment);
    } else {
      final override = ZoomSegment(
        id: const Uuid().v4(),
        startMs: newSegment.startMs,
        endMs: newSegment.endMs,
        source: 'manual',
        baseId: oldSegment.id,
      );
      controller._addManualSegment(override);
    }
  }

  @override
  void revert() {
    controller._restoreManualSegments(_previousManualSegments);
  }
}

class TrimZoomSegmentCommand implements ZoomEditCommand {
  final ZoomEditorController controller;
  final ZoomSegment oldSegment;
  final ZoomSegment newSegment;
  late final List<ZoomSegment> _previousManualSegments;

  TrimZoomSegmentCommand(this.controller, this.oldSegment, this.newSegment) {
    _previousManualSegments = List<ZoomSegment>.from(controller.manualSegments);
  }

  @override
  void apply() {
    if (oldSegment.source == 'manual') {
      controller._updateManualSegment(newSegment);
    } else {
      final override = ZoomSegment(
        id: const Uuid().v4(),
        startMs: newSegment.startMs,
        endMs: newSegment.endMs,
        source: 'manual',
        baseId: oldSegment.id,
      );
      controller._addManualSegment(override);
    }
  }

  @override
  void revert() {
    controller._restoreManualSegments(_previousManualSegments);
  }
}

class DeleteZoomSegmentCommand implements ZoomEditCommand {
  final ZoomEditorController controller;
  final ZoomSegment segment;
  late final List<ZoomSegment> _previousManualSegments;

  DeleteZoomSegmentCommand(this.controller, this.segment) {
    _previousManualSegments = List<ZoomSegment>.from(controller.manualSegments);
  }

  @override
  void apply() {
    controller._deleteManyNoUndo([segment]);
  }

  @override
  void revert() {
    controller._restoreManualSegments(_previousManualSegments);
  }
}

class DeleteZoomSegmentsCommand implements ZoomEditCommand {
  final ZoomEditorController controller;
  final List<ZoomSegment> segments;
  late final List<ZoomSegment> _previousManualSegments;

  DeleteZoomSegmentsCommand(this.controller, this.segments) {
    _previousManualSegments = List<ZoomSegment>.from(controller.manualSegments);
  }

  @override
  void apply() {
    controller._deleteManyNoUndo(segments);
  }

  @override
  void revert() {
    controller._restoreManualSegments(_previousManualSegments);
  }
}

@Deprecated('Use DeleteZoomSegmentsCommand')
class DeleteManyZoomSegmentsCommand extends DeleteZoomSegmentsCommand {
  DeleteManyZoomSegmentsCommand(super.controller, super.segments);
}

enum TrimHandle { left, right }

enum ZoomAddMode { off, oneShot, sticky }

class ZoomEditorController extends ChangeNotifier {
  final NativeBridge _nativeBridge;
  final String videoPath;
  final int durationMs;
  final String? sessionId;

  ZoomEditorController({
    required NativeBridge nativeBridge,
    required this.videoPath,
    required this.durationMs,
    this.sessionId,
  }) : _nativeBridge = nativeBridge;

  List<ZoomSegment> _autoSegments = [];
  List<ZoomSegment> _manualSegments = [];
  List<ZoomSegment> _effectiveSegments = [];

  ZoomSegment? _draftSegment;
  ZoomAddMode _addMode = ZoomAddMode.off;
  bool _snappingEnabled = true;

  // Drag State
  String? _movingSegmentId;
  ZoomSegment? _movingOriginalSegment;
  ZoomSegment? _movingPreviewSegment;
  int _movingPointerOffsetMs = 0;
  Timer? _nativeSyncTimer;

  // Trim State
  String? _trimmingSegmentId;
  ZoomSegment? _trimmingOriginalSegment;
  ZoomSegment? _trimmingPreviewSegment;
  TrimHandle? _activeTrimHandle;

  // Selection
  final LinkedHashSet<String> _selectedSegmentIds = LinkedHashSet<String>();
  String? _primarySelectedSegmentId;
  String? _selectionAnchorId;
  Set<String> _bandBaseSelectionIds = <String>{};
  bool _bandAdditive = false;
  bool _bandSelecting = false;

  List<ZoomSegment> get autoSegments => _autoSegments;
  List<ZoomSegment> get manualSegments => _manualSegments;
  List<ZoomSegment> get effectiveZoomSegments => _effectiveSegments;
  ZoomSegment? get draftSegment => _draftSegment;
  ZoomAddMode get addMode => _addMode;
  bool get addModeEnabled => _addMode != ZoomAddMode.off;
  bool get stickyAddModeEnabled => _addMode == ZoomAddMode.sticky;
  bool get snappingEnabled => _snappingEnabled;

  Set<String> get selectedSegmentIds => Set.unmodifiable(_selectedSegmentIds);
  List<ZoomSegment> get selectedSegments {
    if (_selectedSegmentIds.isEmpty) return const [];
    return orderedDisplaySegments
        .where((s) => _selectedSegmentIds.contains(s.id))
        .toList(growable: false);
  }

  ZoomSegment? get primarySelectedSegment {
    return _segmentById(_primarySelectedSegmentId);
  }

  int get selectedCount => _selectedSegmentIds.length;
  bool get hasSelection => _selectedSegmentIds.isNotEmpty;
  bool get hasMultiSelection => _selectedSegmentIds.length > 1;
  bool get canSingleEdit => selectedCount == 1;
  bool isSelected(String id) => _selectedSegmentIds.contains(id);

  @Deprecated('Use primarySelectedSegmentId instead')
  String? get selectedSegmentId => _primarySelectedSegmentId;

  @Deprecated('Use primarySelectedSegment instead')
  ZoomSegment? get selectedSegment => primarySelectedSegment;

  String? get primarySelectedSegmentId => _primarySelectedSegmentId;

  static const double frameMs = 1000 / 60;
  static int get minDurationMs => (frameMs * 2).round();

  bool _isTombstone(ZoomSegment s) =>
      s.baseId != null && (s.endMs <= s.startMs);
  bool _isValidForUi(ZoomSegment s) =>
      (s.endMs - s.startMs) >= minDurationMs && !_isTombstone(s);

  /// Segments to display on the timeline (non-overridden auto + all manual)
  List<ZoomSegment> get displaySegments {
    // Priority: Trimming > Moving > Base
    if (_trimmingSegmentId != null) return _displaySegmentsWithTrimPreview;
    if (_movingSegmentId != null) return _displaySegmentsWithMovingPreview;
    return _displaySegmentsBase;
  }

  List<ZoomSegment> get _displaySegmentsBase {
    // overriddenIds must consider ALL manual segments (including tombstones)
    final overriddenIds = _manualSegments
        .map((s) => s.baseId)
        .whereType<String>()
        .toSet();

    final nonOverriddenAuto = _autoSegments
        .where((s) => !overriddenIds.contains(s.id))
        .toList();

    // Only show manual segments that are valid for UI (not tombstones/too short)
    final manualSegmentsUi = _manualSegments.where(_isValidForUi).toList();

    return [...nonOverriddenAuto, ...manualSegmentsUi];
  }

  List<ZoomSegment> get _displaySegmentsWithMovingPreview {
    if (_movingSegmentId == null || _movingPreviewSegment == null) {
      return _displaySegmentsBase;
    }

    final overriddenIds = _manualSegments
        .where((s) => s.id != _movingSegmentId)
        .map((s) => s.baseId)
        .whereType<String>()
        .toSet();

    if (_movingOriginalSegment?.baseId != null) {
      overriddenIds.add(_movingOriginalSegment!.baseId!);
    }

    final nonOverriddenAuto = _autoSegments
        .where((s) => !overriddenIds.contains(s.id))
        .toList();

    final remainingManual = _manualSegments
        .where((s) => s.id != _movingSegmentId && _isValidForUi(s))
        .toList();

    return [...nonOverriddenAuto, ...remainingManual, _movingPreviewSegment!];
  }

  List<ZoomSegment> get _displaySegmentsWithTrimPreview {
    if (_trimmingSegmentId == null || _trimmingPreviewSegment == null) {
      return _displaySegmentsBase;
    }

    final overriddenIds = _manualSegments
        .where((s) => s.id != _trimmingSegmentId)
        .map((s) => s.baseId)
        .whereType<String>()
        .toSet();

    if (_trimmingOriginalSegment?.baseId != null) {
      overriddenIds.add(_trimmingOriginalSegment!.baseId!);
    }

    final nonOverriddenAuto = _autoSegments
        .where((s) => !overriddenIds.contains(s.id))
        .toList();

    final remainingManual = _manualSegments
        .where((s) => s.id != _trimmingSegmentId && _isValidForUi(s))
        .toList();

    return [...nonOverriddenAuto, ...remainingManual, _trimmingPreviewSegment!];
  }

  List<ZoomSegment> get orderedDisplaySegments {
    final sorted = List<ZoomSegment>.from(displaySegments);
    sorted.sort((a, b) {
      final byStart = a.startMs.compareTo(b.startMs);
      if (byStart != 0) return byStart;
      final byEnd = a.endMs.compareTo(b.endMs);
      if (byEnd != 0) return byEnd;
      return a.id.compareTo(b.id);
    });
    return sorted;
  }

  @Deprecated('Use orderedDisplaySegments')
  List<ZoomSegment> get selectableSegmentsSorted => orderedDisplaySegments;

  ZoomSegment? segmentById(String id) {
    return _findDisplaySegmentById(id);
  }

  ZoomSegment? _findDisplaySegmentById(String id) {
    for (final segment in displaySegments) {
      if (segment.id == id) return segment;
    }
    return null;
  }

  ZoomSegment? _segmentById(String? id) {
    if (id == null) return null;
    return _findDisplaySegmentById(id);
  }

  int indexOfVisibleSegment(String id) {
    return orderedDisplaySegments.indexWhere((s) => s.id == id);
  }

  void _setSelection(
    Iterable<String> ids, {
    String? primaryId,
    String? anchorId,
    bool notify = true,
  }) {
    _selectedSegmentIds
      ..clear()
      ..addAll(ids);

    if (_selectedSegmentIds.isEmpty) {
      _primarySelectedSegmentId = null;
      _selectionAnchorId = null;
    } else {
      _primarySelectedSegmentId =
          (primaryId != null && _selectedSegmentIds.contains(primaryId))
          ? primaryId
          : _selectedSegmentIds.first;

      _selectionAnchorId =
          (anchorId != null && _selectedSegmentIds.contains(anchorId))
          ? anchorId
          : _primarySelectedSegmentId;
    }

    if (notify) notifyListeners();
  }

  bool get isMoving => _movingSegmentId != null;
  String? get movingSegmentId => _movingSegmentId;
  bool get isTrimming => _trimmingSegmentId != null;
  TrimHandle? get activeTrimHandle => _activeTrimHandle;
  bool get isBandSelecting => _bandSelecting;

  final List<ZoomEditCommand> _history = [];
  bool get canUndo => _history.isNotEmpty;

  Future<void> init() async {
    final rawAuto = await _nativeBridge.getZoomSegments(videoPath);
    // Normalize auto segment IDs so manual overrides remain stable across reloads.
    _autoSegments = rawAuto.asMap().entries.map((e) {
      final idx = e.key;
      final s = e.value;
      final id = (s.id.startsWith("auto_")) ? s.id : "auto_$idx";
      return s.copyWith(id: id, source: "auto", clearBaseId: true);
    }).toList();

    _manualSegments = await _nativeBridge.getManualZoomSegments(videoPath);
    _computeEffective();
    _reconcileSelection();
    _syncToNative();
    notifyListeners();
  }

  void toggleAddMode() {
    if (_addMode == ZoomAddMode.off) {
      enterOneShotAddMode();
      return;
    }
    exitAddMode();
  }

  void setAddMode(bool enabled) {
    if (enabled) {
      enterOneShotAddMode();
    } else {
      exitAddMode();
    }
  }

  void enterOneShotAddMode() {
    if (_addMode == ZoomAddMode.oneShot) return;
    _setAddMode(ZoomAddMode.oneShot);
  }

  void enterStickyAddMode() {
    if (_addMode == ZoomAddMode.sticky) return;
    _setAddMode(ZoomAddMode.sticky);
  }

  void toggleStickyAddMode() {
    if (_addMode == ZoomAddMode.sticky) {
      enterOneShotAddMode();
      return;
    }
    enterStickyAddMode();
  }

  void exitAddMode() {
    if (_addMode == ZoomAddMode.off && _draftSegment == null) return;
    _setAddMode(ZoomAddMode.off);
  }

  void _setAddMode(ZoomAddMode mode) {
    final didChangeMode = _addMode != mode;
    final hadDraft = _draftSegment != null;
    _addMode = mode;
    _draftSegment = null;
    if (didChangeMode || hadDraft) {
      notifyListeners();
    }
  }

  void updateDraft(int startMs, int endMs) {
    if (!addModeEnabled) return;

    int s = _normalizeEditableMs(startMs);
    int e = _normalizeEditableMs(endMs);

    // Normalize
    if (s > e) {
      final tmp = s;
      s = e;
      e = tmp;
    }

    _draftSegment = ZoomSegment(
      id: 'draft',
      startMs: s,
      endMs: e,
      source: 'manual',
    );
    notifyListeners();
  }

  void commitDraft() {
    if (_draftSegment == null) return;

    final draft = _draftSegment!;
    final duration = draft.endMs - draft.startMs;

    if (duration < minDurationMs) {
      _draftSegment = null;
      notifyListeners();
      return;
    }

    final newSegment = ZoomSegment(
      id: const Uuid().v4(),
      startMs: draft.startMs,
      endMs: draft.endMs,
      source: 'manual',
    );

    execute(AddZoomSegmentCommand(this, newSegment));
    _draftSegment = null;
    if (_addMode == ZoomAddMode.oneShot) {
      _addMode = ZoomAddMode.off;
    }
    selectOnly(newSegment);
  }

  /// Default duration (ms) used when the timeline lane creates a new segment
  /// from the ghost template (click-to-add).
  static const int defaultNewSegmentDurationMs = 1200;

  /// Returns true when adding a default-sized segment centered around
  /// [centerMs] would either fail to fit or overlap an existing display
  /// segment. Used by the lane to decide whether to show the ghost.
  bool canAddDefaultSegmentAt(int centerMs, {int durationMs = defaultNewSegmentDurationMs}) {
    if (this.durationMs <= 0) return false;
    final span = _resolveDefaultSpan(centerMs, durationMs);
    if (span == null) return false;
    return !_spanOverlapsExisting(span.$1, span.$2);
  }

  /// Resolved (start, end) for a default-sized segment centered around
  /// [centerMs], clamped to the timeline. Returns null when the resulting
  /// span cannot satisfy [minDurationMs] or fits inside the timeline.
  (int, int)? defaultSpanFor(int centerMs, {int durationMs = defaultNewSegmentDurationMs}) {
    return _resolveDefaultSpan(centerMs, durationMs);
  }

  /// Adds a default-sized segment centered around [centerMs]. Selects the
  /// new segment. Returns the segment, or null when the span cannot be
  /// placed (overlap, invalid duration, etc.).
  ZoomSegment? addDefaultSegmentAt(
    int centerMs, {
    int durationMs = defaultNewSegmentDurationMs,
  }) {
    if (this.durationMs <= 0) return null;
    final span = _resolveDefaultSpan(centerMs, durationMs);
    if (span == null) return null;
    final start = span.$1;
    final end = span.$2;
    if (end - start < minDurationMs) return null;
    if (_spanOverlapsExisting(start, end)) return null;

    final newSegment = ZoomSegment(
      id: const Uuid().v4(),
      startMs: start,
      endMs: end,
      source: 'manual',
    );
    execute(AddZoomSegmentCommand(this, newSegment));
    selectOnly(newSegment);
    return newSegment;
  }

  (int, int)? _resolveDefaultSpan(int centerMs, int requestedDurationMs) {
    if (durationMs <= 0) return null;
    final clampedDuration = requestedDurationMs.clamp(
      minDurationMs,
      durationMs,
    );
    final half = clampedDuration ~/ 2;
    var start = (centerMs - half).clamp(0, durationMs - clampedDuration);
    if (start < 0) start = 0;
    var end = start + clampedDuration;
    if (end > durationMs) {
      end = durationMs;
      start = (end - clampedDuration).clamp(0, end);
    }
    final normStart = _normalizeEditableMs(start);
    final normEnd = _normalizeEditableMs(end);
    if (normEnd - normStart < minDurationMs) return null;
    return (normStart, normEnd);
  }

  bool _spanOverlapsExisting(int start, int end) {
    for (final segment in displaySegments) {
      if (_isTombstone(segment)) continue;
      if (segment.startMs < end && segment.endMs > start) {
        return true;
      }
    }
    return false;
  }

  void execute(ZoomEditCommand cmd) {
    cmd.apply();
    _history.add(cmd);
    _persistManualSegments();
    _syncToNative();
  }

  void undo() {
    if (_history.isEmpty) return;
    final cmd = _history.removeLast();
    cmd.revert();
    _persistManualSegments();
    _syncToNative();
  }

  void _commitManualMutation({bool notify = true}) {
    _computeEffective();
    if (notify) notifyListeners();
  }

  void _addManualSegment(ZoomSegment seg) {
    _manualSegments.add(seg);
    _commitManualMutation();
  }

  void _updateManualSegment(ZoomSegment seg) {
    final idx = _manualSegments.indexWhere((s) => s.id == seg.id);
    if (idx != -1) {
      _manualSegments[idx] = seg;
      _commitManualMutation();
    }
  }

  void _removeManualSegment(String id) {
    _manualSegments.removeWhere((s) => s.id == id);
    _commitManualMutation();
  }

  void _restoreManualSegments(List<ZoomSegment> segments) {
    _manualSegments = List<ZoomSegment>.from(segments);
    _commitManualMutation();
  }

  void _deleteManyNoUndo(List<ZoomSegment> segments) {
    for (final segment in segments) {
      _applyDeleteMutation(segment);
    }
    _commitManualMutation();
  }

  void _applyDeleteMutation(ZoomSegment segment) {
    if (segment.source == 'manual' && segment.baseId == null) {
      _manualSegments.removeWhere((s) => s.id == segment.id);
      return;
    }

    final baseId = segment.baseId ?? segment.id;
    final tombstoneId = (segment.source == 'manual')
        ? segment.id
        : const Uuid().v4();
    final tombstone = ZoomSegment(
      id: tombstoneId,
      startMs: segment.startMs,
      endMs: segment.startMs,
      source: 'manual',
      baseId: baseId,
    );

    if (segment.source == 'manual') {
      final idx = _manualSegments.indexWhere((s) => s.id == segment.id);
      if (idx != -1) {
        _manualSegments[idx] = tombstone;
      }
    } else {
      _manualSegments.add(tombstone);
    }
  }

  void _reconcileSelection({bool notify = false}) {
    if (_selectedSegmentIds.isEmpty &&
        _primarySelectedSegmentId == null &&
        _selectionAnchorId == null) {
      if (notify) notifyListeners();
      return;
    }

    final visibleIds = displaySegments.map((s) => s.id).toSet();
    _selectedSegmentIds.removeWhere((id) => !visibleIds.contains(id));

    if (_primarySelectedSegmentId != null &&
        !visibleIds.contains(_primarySelectedSegmentId)) {
      _primarySelectedSegmentId = null;
    }
    if (_selectionAnchorId != null &&
        !visibleIds.contains(_selectionAnchorId)) {
      _selectionAnchorId = null;
    }

    if (_selectedSegmentIds.isEmpty) {
      _primarySelectedSegmentId = null;
      _selectionAnchorId = null;
      if (notify) notifyListeners();
      return;
    }

    if (_primarySelectedSegmentId == null ||
        !_selectedSegmentIds.contains(_primarySelectedSegmentId)) {
      _primarySelectedSegmentId = orderedDisplaySegments
          .firstWhere((s) => _selectedSegmentIds.contains(s.id))
          .id;
    }
    _selectionAnchorId ??= _primarySelectedSegmentId;
    if (notify) notifyListeners();
  }

  void selectOnly(ZoomSegment seg) {
    if (_selectedSegmentIds.length == 1 &&
        _selectedSegmentIds.contains(seg.id) &&
        _primarySelectedSegmentId == seg.id) {
      return;
    }
    _setSelection([seg.id], primaryId: seg.id, anchorId: seg.id);
  }

  void addToSelection(ZoomSegment seg) {
    if (_selectedSegmentIds.contains(seg.id)) return;

    _selectedSegmentIds.add(seg.id);
    _primarySelectedSegmentId = seg.id;
    _selectionAnchorId = seg.id;
    notifyListeners();
  }

  void removeFromSelection(String id) {
    final didRemove = _selectedSegmentIds.remove(id);
    if (!didRemove) return;
    if (_selectedSegmentIds.isEmpty) {
      _primarySelectedSegmentId = null;
      _selectionAnchorId = null;
    } else {
      if (_primarySelectedSegmentId == id) {
        _primarySelectedSegmentId = _selectedSegmentIds.first;
      }
      if (_selectionAnchorId == id) {
        _selectionAnchorId = _selectedSegmentIds.first;
      }
    }
    notifyListeners();
  }

  void toggleSelection(ZoomSegment seg) {
    if (_selectedSegmentIds.contains(seg.id)) {
      removeFromSelection(seg.id);
      return;
    }
    addToSelection(seg);
  }

  void clearSelection() {
    if (_selectedSegmentIds.isEmpty) return;
    _setSelection(const []);
  }

  @Deprecated('Use selectOnly / toggleSelection / selectRangeTo')
  void selectSegment(ZoomSegment? seg) {
    if (seg == null) {
      clearSelection();
    } else {
      selectOnly(seg);
    }
  }

  void selectRangeTo(ZoomSegment seg) {
    final sorted = orderedDisplaySegments;
    if (sorted.isEmpty) {
      clearSelection();
      return;
    }

    final anchorId = _selectionAnchorId;
    if (anchorId == null) {
      selectOnly(seg);
      return;
    }

    final anchorIndex = sorted.indexWhere((s) => s.id == anchorId);
    final targetIndex = sorted.indexWhere((s) => s.id == seg.id);
    if (anchorIndex == -1 || targetIndex == -1) {
      selectOnly(seg);
      return;
    }

    final start = anchorIndex < targetIndex ? anchorIndex : targetIndex;
    final end = anchorIndex < targetIndex ? targetIndex : anchorIndex;
    final ids = sorted.sublist(start, end + 1).map((s) => s.id).toList();
    _setSelection(ids, primaryId: seg.id, anchorId: anchorId);
  }

  void selectAllVisible() {
    final sorted = orderedDisplaySegments;
    if (sorted.isEmpty) {
      clearSelection();
      return;
    }
    final ids = sorted.map((s) => s.id).toList();
    final currentPrimary = _primarySelectedSegmentId;
    final primaryId = (currentPrimary != null && ids.contains(currentPrimary))
        ? currentPrimary
        : ids.first;
    _setSelection(ids, primaryId: primaryId, anchorId: primaryId);
  }

  void selectAllAfter(int ms) {
    final sorted = orderedDisplaySegments
        .where((s) => s.startMs >= ms)
        .toList(growable: false);
    if (sorted.isEmpty) {
      clearSelection();
      return;
    }
    final ids = sorted.map((s) => s.id).toList();
    _setSelection(ids, primaryId: ids.first, anchorId: ids.first);
  }

  void selectAllInRange(
    int startMs,
    int endMs, {
    bool additive = false,
    bool intersect = true,
  }) {
    final minMs = startMs < endMs ? startMs : endMs;
    final maxMs = startMs < endMs ? endMs : startMs;
    final selected = orderedDisplaySegments
        .where((s) {
          if (intersect) {
            return s.endMs > minMs && s.startMs < maxMs;
          }
          return s.startMs >= minMs && s.endMs <= maxMs;
        })
        .toList(growable: false);

    if (selected.isEmpty) {
      if (additive) return;
      clearSelection();
      return;
    }

    final ids = selected.map((s) => s.id).toSet();
    if (additive) {
      ids.addAll(_selectedSegmentIds);
    }
    final orderedIds = orderedDisplaySegments
        .where((s) => ids.contains(s.id))
        .map((s) => s.id)
        .toList(growable: false);
    if (orderedIds.isEmpty) {
      clearSelection();
      return;
    }
    final primaryId =
        (_primarySelectedSegmentId != null &&
            ids.contains(_primarySelectedSegmentId))
        ? _primarySelectedSegmentId
        : orderedIds.first;
    _setSelection(orderedIds, primaryId: primaryId, anchorId: primaryId);
  }

  void beginBandSelection({required bool additive}) {
    _bandSelecting = true;
    _bandAdditive = additive;
    _bandBaseSelectionIds = additive
        ? Set<String>.from(_selectedSegmentIds)
        : <String>{};
  }

  void updateBandSelection(int startMs, int endMs) {
    if (!_bandSelecting) return;
    final rangeStart = startMs < endMs ? startMs : endMs;
    final rangeEnd = startMs < endMs ? endMs : startMs;

    final intersectingIds = orderedDisplaySegments
        .where((s) => s.endMs > rangeStart && s.startMs < rangeEnd)
        .map((s) => s.id)
        .toSet();

    final finalSelection = _bandAdditive
        ? {..._bandBaseSelectionIds, ...intersectingIds}
        : intersectingIds;

    if (finalSelection.isEmpty) {
      _setSelection(const []);
      return;
    }

    final orderedIds = orderedDisplaySegments
        .where((s) => finalSelection.contains(s.id))
        .map((s) => s.id)
        .toList(growable: false);
    final preferredPrimary =
        (_primarySelectedSegmentId != null &&
            finalSelection.contains(_primarySelectedSegmentId))
        ? _primarySelectedSegmentId
        : orderedIds.first;
    final anchorId =
        (_selectionAnchorId != null &&
            finalSelection.contains(_selectionAnchorId))
        ? _selectionAnchorId
        : preferredPrimary;
    _setSelection(orderedIds, primaryId: preferredPrimary, anchorId: anchorId);
  }

  void endBandSelection() {
    _bandSelecting = false;
    _bandAdditive = false;
    _bandBaseSelectionIds.clear();
  }

  void deleteSelectedSegments() {
    final segments = List<ZoomSegment>.from(selectedSegments)
      ..sort((a, b) {
        final byStart = a.startMs.compareTo(b.startMs);
        if (byStart != 0) return byStart;
        final byEnd = a.endMs.compareTo(b.endMs);
        if (byEnd != 0) return byEnd;
        return a.id.compareTo(b.id);
      });
    if (segments.isEmpty) return;
    execute(DeleteZoomSegmentsCommand(this, segments));
    clearSelection();
  }

  void deleteAllAfter(int ms) {
    final targets = orderedDisplaySegments
        .where((s) => s.startMs >= ms)
        .toList(growable: false);
    if (targets.isEmpty) return;
    execute(DeleteZoomSegmentsCommand(this, targets));
    clearSelection();
  }

  @Deprecated('Use deleteSelectedSegments')
  void deleteSelected() {
    deleteSelectedSegments();
  }

  bool handleEscapeAction() {
    if (_draftSegment != null || addModeEnabled) {
      exitAddMode();
      return true;
    }
    if (isTrimming) {
      cancelTrim();
      return true;
    }
    if (isMoving) {
      cancelMove();
      return true;
    }
    if (hasSelection) {
      clearSelection();
      return true;
    }
    return false;
  }

  // --- Move Logic ---

  ZoomSegment? hitTest(int ms, {int toleranceMs = 0}) {
    final hitToleranceMs = toleranceMs < 0 ? 0 : toleranceMs;

    // Check manual segments first (higher priority)
    for (final seg in _manualSegments.reversed) {
      if (!_isValidForUi(seg)) continue;
      if (ms >= seg.startMs - hitToleranceMs &&
          ms <= seg.endMs + hitToleranceMs) {
        return seg;
      }
    }
    // Then check non-overridden auto segments
    final overriddenIds = _manualSegments
        .map((s) => s.baseId)
        .whereType<String>()
        .toSet();
    for (final seg in _autoSegments) {
      if (overriddenIds.contains(seg.id)) continue;
      if (ms >= seg.startMs - hitToleranceMs &&
          ms <= seg.endMs + hitToleranceMs) {
        return seg;
      }
    }
    return null;
  }

  void beginMoveAt(int ms, ZoomSegment segment) {
    if (hasMultiSelection) return;
    if (!isSelected(segment.id) || _primarySelectedSegmentId != segment.id) {
      selectOnly(segment);
    }
    if (!canSingleEdit) return;
    _movingSegmentId = segment.id;
    _movingOriginalSegment = segment;
    _movingPreviewSegment = segment;
    _movingPointerOffsetMs = ms - segment.startMs;
    notifyListeners();
  }

  void updateMoveTo(int ms) {
    if (_movingSegmentId == null || _movingOriginalSegment == null) return;

    final duration =
        _movingOriginalSegment!.endMs - _movingOriginalSegment!.startMs;
    int newStart = _normalizeEditableMs(ms - _movingPointerOffsetMs);
    int newEnd = newStart + duration;

    // Clamp
    if (newStart < 0) {
      newStart = 0;
      newEnd = duration;
    }
    if (newEnd > durationMs) {
      newEnd = durationMs;
      newStart = newEnd - duration;
    }

    _movingPreviewSegment = _movingOriginalSegment!.copyWith(
      startMs: newStart,
      endMs: newEnd,
    );

    _computeEffective();
    notifyListeners();

    _throttleSync();
  }

  void commitMove() {
    if (_movingSegmentId == null ||
        _movingOriginalSegment == null ||
        _movingPreviewSegment == null) {
      return;
    }

    final newSeg = _movingPreviewSegment!;
    final oldSeg = _movingOriginalSegment!;

    if (newSeg.startMs != oldSeg.startMs || newSeg.endMs != oldSeg.endMs) {
      execute(MoveZoomSegmentCommand(this, oldSeg, newSeg));
    }

    _cancelMoveInternal();
  }

  void cancelMove() {
    _cancelMoveInternal();
    _computeEffective();
    _syncToNative();
    notifyListeners();
  }

  void _cancelMoveInternal() {
    _movingSegmentId = null;
    _movingOriginalSegment = null;
    _movingPreviewSegment = null;
    _nativeSyncTimer?.cancel();
    _nativeSyncTimer = null;
  }

  // --- Trim Logic ---

  void beginTrimAt(int ms, ZoomSegment segment, TrimHandle handle) {
    if (hasMultiSelection) return;
    if (!isSelected(segment.id) || _primarySelectedSegmentId != segment.id) {
      selectOnly(segment);
    }
    if (!canSingleEdit) return;
    _trimmingSegmentId = segment.id;
    _trimmingOriginalSegment = segment;
    _trimmingPreviewSegment = segment;
    _activeTrimHandle = handle;
    notifyListeners();
  }

  void updateTrimTo(int ms) {
    if (_trimmingSegmentId == null || _trimmingOriginalSegment == null) return;

    final snappedMs = _normalizeEditableMs(ms);
    final original = _trimmingOriginalSegment!;

    int newStart = original.startMs;
    int newEnd = original.endMs;

    if (_activeTrimHandle == TrimHandle.left) {
      newStart = snappedMs.clamp(0, original.endMs - minDurationMs);
    } else {
      newEnd = snappedMs.clamp(original.startMs + minDurationMs, durationMs);
    }

    _trimmingPreviewSegment = original.copyWith(
      startMs: newStart,
      endMs: newEnd,
    );

    _computeEffective();
    notifyListeners();

    _throttleSync();
  }

  void commitTrim() {
    if (_trimmingSegmentId == null ||
        _trimmingOriginalSegment == null ||
        _trimmingPreviewSegment == null) {
      return;
    }

    final newSeg = _trimmingPreviewSegment!;
    final oldSeg = _trimmingOriginalSegment!;

    if (newSeg.startMs != oldSeg.startMs || newSeg.endMs != oldSeg.endMs) {
      execute(TrimZoomSegmentCommand(this, oldSeg, newSeg));
    }

    _cancelTrimInternal();
  }

  void cancelTrim() {
    _cancelTrimInternal();
    _computeEffective();
    _syncToNative();
    notifyListeners();
  }

  void _cancelTrimInternal() {
    _trimmingSegmentId = null;
    _trimmingOriginalSegment = null;
    _trimmingPreviewSegment = null;
    _activeTrimHandle = null;
    _nativeSyncTimer?.cancel();
    _nativeSyncTimer = null;
  }

  void _computeEffective() {
    // Only use segments that have a positive duration in the effective timeline
    final validSegments = displaySegments
        .where((s) => s.endMs - s.startMs > 0)
        .toList();
    _effectiveSegments = _normalizeSegments(validSegments);
    _reconcileSelection();
  }

  List<ZoomSegment> _normalizeSegments(List<ZoomSegment> segments) {
    if (segments.isEmpty) return [];

    final sorted = List<ZoomSegment>.from(segments)
      ..sort((a, b) => a.startMs.compareTo(b.startMs));

    final List<ZoomSegment> merged = [];
    if (sorted.isEmpty) return [];

    var currentStart = sorted[0].startMs;
    var currentEnd = sorted[0].endMs;

    for (int i = 1; i < sorted.length; i++) {
      final next = sorted[i];

      if (next.startMs <= currentEnd + 120) {
        currentEnd = currentEnd > next.endMs ? currentEnd : next.endMs;
      } else {
        merged.add(
          ZoomSegment(
            id: 'merged_${merged.length}',
            startMs: currentStart,
            endMs: currentEnd,
            source: 'effective',
          ),
        );
        currentStart = next.startMs;
        currentEnd = next.endMs;
      }
    }

    merged.add(
      ZoomSegment(
        id: 'merged_${merged.length}',
        startMs: currentStart,
        endMs: currentEnd,
        source: 'effective',
      ),
    );

    return merged;
  }

  int _snapToGrid(int ms) {
    final snapped = (ms / frameMs).round() * frameMs;
    return snapped.round().clamp(0, durationMs);
  }

  int _normalizeEditableMs(int ms) {
    final clamped = ms.clamp(0, durationMs);
    if (!_snappingEnabled) return clamped;
    return _snapToGrid(clamped);
  }

  void setSnappingEnabled(bool enabled) {
    if (_snappingEnabled == enabled) return;
    _snappingEnabled = enabled;
    notifyListeners();
  }

  Future<void> _persistManualSegments() async {
    await _nativeBridge.saveManualZoomSegments(videoPath, _manualSegments);
  }

  void _throttleSync() {
    _nativeSyncTimer ??= Timer(const Duration(milliseconds: 33), () {
      _syncToNative();
      _nativeSyncTimer = null;
    });
  }

  Future<void> _syncChain = Future.value();

  Future<void> _syncToNative() {
    final segmentsSnapshot = List<ZoomSegment>.from(_effectiveSegments);
    _syncChain = _syncChain.then(
      (_) => _nativeBridge.previewSetZoomSegments(
        segmentsSnapshot,
        sessionId: sessionId,
      ),
    );
    return _syncChain;
  }
}
