import 'dart:async';

import 'package:clingfy/app/home/post_processing/widgets/zoom_segment_behavior_floating_toolbar.dart';
import 'package:clingfy/app/home/preview/widgets/timeline/clips_timeline_lane.dart';
import 'package:clingfy/app/home/preview/widgets/timeline/timeline_editor_viewport.dart';
import 'package:clingfy/app/home/preview/widgets/timeline/timeline_header_bar.dart';
import 'package:clingfy/app/home/preview/widgets/timeline/timeline_transport_bar.dart';
import 'package:clingfy/app/home/preview/widgets/timeline/timeline_viewport_controller.dart';
import 'package:clingfy/app/home/recording/recording_controller.dart';
import 'package:clingfy/app/infrastructure/logging/logger_service.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/clips/clip_editor_controller.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/preview/player_controller.dart';
import 'package:clingfy/core/zoom/zoom_editor_controller.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/responsive_shell_scope.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

class TimelineBar extends StatelessWidget {
  const TimelineBar({super.key});

  @override
  Widget build(BuildContext context) {
    // The timeline stays mounted during export so the user can keep scrubbing
    // the preview; every edit affordance is disabled until the export ends
    // (the export bakes the clips it was started with — mutating them
    // mid-flight would desync the preview from the file being written).
    final isExporting = context.select<RecordingController, bool>(
      (r) => r.isExporting,
    );
    return Selector<PlayerController, (int durMs, int posMs, bool ready)>(
      selector: (_, p) => (p.durationMs, p.positionMs, p.isReady),
      builder: (context, t, _) {
        final player = context.read<PlayerController>();

        return VideoTimeline(
          durationMs: t.$1,
          positionMs: t.$2,
          isReady: t.$3,
          editingEnabled: !isExporting,
          onSeek: (ms) => unawaited(player.seekTo(ms)),
          onHoverSeek: (ms) => unawaited(player.previewPeekTo(ms)),
          onHoverEnd: () => unawaited(player.previewPeekEnd()),
        );
      },
    );
  }
}

class VideoTimeline extends StatefulWidget {
  const VideoTimeline({
    super.key,
    required this.durationMs,
    required this.positionMs,
    required this.isReady,
    required this.onSeek,
    this.editingEnabled = true,
    this.onHoverSeek,
    this.onHoverEnd,
  });

  final int durationMs;
  final int positionMs;
  final bool isReady;

  /// False while an export runs: seek/hover/zoom/play stay live, but every
  /// edit affordance (split/delete/undo/redo, trim, reorder, scissors, zoom
  /// editing, the Delete shortcut) is disabled — the export bakes the clips
  /// it was started with.
  final bool editingEnabled;
  final ValueChanged<int> onSeek;
  final ValueChanged<int>? onHoverSeek;
  final VoidCallback? onHoverEnd;

  @override
  State<VideoTimeline> createState() => _VideoTimelineState();
}

class DeleteSelectedZoomIntent extends Intent {
  const DeleteSelectedZoomIntent();
}

class ClearZoomSelectionIntent extends Intent {
  const ClearZoomSelectionIntent();
}

class SelectAllZoomIntent extends Intent {
  const SelectAllZoomIntent();
}

class _VideoTimelineState extends State<VideoTimeline> {
  late final FocusNode _zoomEditorFocusNode;
  late final TimelineViewportController _viewportController;

  int? _hoverPositionMs;
  bool _showZoomLane = true;
  bool _showMarkersLane = false;
  // Clips lane defaults on (cutting is a core edit); no toggle yet — a later PR
  // adds lane-visibility controls alongside the zoom/markers toggles.
  final bool _showClipsLane = true;
  bool _panModeEnabled = false;
  // Scissors cut tool: armed while Option (Alt) is held alone over the timeline
  // (Alt+Space is pan, which suppresses it). Local view state, like
  // [_panModeEnabled] — it mutates nothing, so it does not belong in the clip
  // editor (a notifyListeners there would rebuild the whole timeline).
  bool _cutModeArmed = false;
  // Cut arming is keyboard-driven, so it must respect focus: arm only while the
  // timeline holds focus (re-synced on focus gain so holding Option then
  // clicking in works without releasing the key first), and never while blurred.
  bool _timelineHasFocus = false;
  // Tracks whether the clip editor was attached on the previous build, so the
  // attach/detach transition is logged once (not on every rebuild).
  bool _clipEditorAttached = false;

  @override
  void initState() {
    super.initState();
    _zoomEditorFocusNode = FocusNode(debugLabel: 'zoom-editor-timeline');
    _viewportController = TimelineViewportController(
      durationMs: widget.durationMs > 0 ? widget.durationMs : 1,
    );
  }

  @override
  void didUpdateWidget(covariant VideoTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.durationMs != oldWidget.durationMs) {
      _viewportController.setDurationMs(
        widget.durationMs > 0 ? widget.durationMs : 1,
      );
    }
    if (!oldWidget.isReady && widget.isReady) {
      _viewportController.fitToDuration(centerMs: widget.positionMs);
    }
  }

  @override
  void dispose() {
    _zoomEditorFocusNode.dispose();
    _viewportController.dispose();
    super.dispose();
  }

  String _fmt(int ms) {
    final duration = Duration(milliseconds: ms);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:$minutes:$seconds';
    }
    return '${duration.inMinutes}:$seconds';
  }

  void _requestTimelineFocus() {
    if (!_zoomEditorFocusNode.hasFocus) {
      _zoomEditorFocusNode.requestFocus();
    }
  }

  void _clearHoverPreview() {
    if (_hoverPositionMs != null) {
      setState(() => _hoverPositionMs = null);
    }
    widget.onHoverEnd?.call();
  }

  void _setPanModeEnabled(bool enabled) {
    if (_panModeEnabled == enabled) return;
    if (enabled) {
      _clearHoverPreview();
    }
    setState(() => _panModeEnabled = enabled);
    // Pan (Alt+Space) takes over from the cut tool while it is engaged.
    _syncCutModeFromKeyboard();
  }

  void _setCutModeArmed(bool armed) {
    if (_cutModeArmed == armed) return;
    setState(() => _cutModeArmed = armed);
  }

  /// Recomputes the cut-tool armed state from the live keyboard. The tool is
  /// armed while the timeline has focus and Option (Alt) is held alone — Alt+Space
  /// is pan, which suppresses it. Reading [HardwareKeyboard] (not just tracking
  /// key events) means a missed key-up can't strand the tool armed, and gating on
  /// focus means a sync while blurred can never (re-)arm it.
  void _syncCutModeFromKeyboard() {
    final armed =
        _timelineHasFocus &&
        HardwareKeyboard.instance.isAltPressed &&
        !_panModeEnabled;
    _setCutModeArmed(armed);
  }

  KeyEventResult _handleTimelineKeyEvent(FocusNode node, KeyEvent event) {
    final isSpace = event.logicalKey == LogicalKeyboardKey.space;
    final isAltSpace = isSpace && HardwareKeyboard.instance.isAltPressed;

    if (isAltSpace) {
      if (event is KeyDownEvent || event is KeyRepeatEvent) {
        _setPanModeEnabled(true);
        return KeyEventResult.handled;
      }
      if (event is KeyUpEvent) {
        _setPanModeEnabled(false);
        return KeyEventResult.handled;
      }
    }

    // Self-heal pan if a release broke the Alt+Space combo out of order (e.g.
    // Alt up before Space): pan requires BOTH physically held, else the opaque
    // pan overlay would wedge the timeline until focus loss.
    if (_panModeEnabled &&
        !(HardwareKeyboard.instance.isAltPressed &&
            HardwareKeyboard.instance.isLogicalKeyPressed(
              LogicalKeyboardKey.space,
            ))) {
      _setPanModeEnabled(false);
    }

    // Any other key transition (notably Option down/up) may flip the cut tool.
    final wasArmed = _cutModeArmed;
    _syncCutModeFromKeyboard();
    return _cutModeArmed != wasArmed
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  void _handleDeleteSelected(ZoomEditorController? editor) {
    if (editor == null || !editor.hasSelection) return;
    editor.deleteSelectedSegments();
  }

  void _handleClearOrEscape(ZoomEditorController? editor) {
    if (editor == null) return;
    editor.handleEscapeAction();
  }

  void _handleSelectAllVisible(ZoomEditorController? editor) {
    if (editor == null) return;
    editor.selectAllInRange(
      _viewportController.visibleStartMs,
      _viewportController.visibleEndMs,
    );
  }

  void _handleSelectAfterPlayhead(ZoomEditorController? editor) {
    if (editor == null) return;
    editor.selectAllAfter(widget.positionMs);
  }

  void _toggleSnap(ZoomEditorController? editor) {
    if (editor == null) return;
    editor.setSnappingEnabled(!editor.snappingEnabled);
  }

  // --- Clip (split / cut) handlers ---
  //
  // All clip mutations funnel through here so each one leaves a breadcrumb in
  // the logs (clip edits are a critical new surface; a desynced cut is the
  // exact kind of bug we want a trail for).

  /// Shared split core for both the playhead button and the scissors tool, so
  /// the no-op-vs-success logging stays identical for either entry point.
  /// [source] tags the log line ('playhead' | 'scissors').
  void _performSplit(ClipEditorController clip, int timelineMs, String source) {
    final before = clip.clips.length;
    clip.splitAtPlayhead(timelineMs);
    final after = clip.clips.length;
    if (after == before) {
      // Split rejected: the cut point sits on a clip boundary or a piece would
      // fall below the minimum duration. Surface it distinctly so a no-op is
      // never mistaken for a successful cut in the logs.
      Log.w(
        'ClipsLane',
        'split no-op ($source) at ${timelineMs}ms '
            '(boundary or below min duration); still $after clips',
      );
      return;
    }
    Log.d(
      'ClipsLane',
      'split ($source) at ${timelineMs}ms: $before -> $after clips '
          '(editedDur=${clip.editedDurationMs}ms)',
    );
  }

  void _handleSplitClip(ClipEditorController? clip) {
    if (clip == null) return;
    _performSplit(clip, widget.positionMs, 'playhead');
  }

  /// Scissors tool: cut at the clicked timeline ms. Backstops on the live
  /// modifier so a stranded armed state (missed key-up) self-heals instead of
  /// cutting on a stray click.
  void _handleScissorsCut(ClipEditorController? clip, int timelineMs) {
    if (clip == null) return;
    if (!HardwareKeyboard.instance.isAltPressed) {
      _setCutModeArmed(false);
      return;
    }
    _performSplit(clip, timelineMs, 'scissors');
  }

  void _handleDeleteClip(ClipEditorController? clip) {
    if (clip == null || !clip.canDeleteSelected) return;
    final removed = clip.selectedClipId;
    clip.deleteSelected();
    Log.d(
      'ClipsLane',
      'deleted clip $removed: ${clip.clips.length} clips remain '
          '(editedDur=${clip.editedDurationMs}ms)',
    );
  }

  void _handleSelectClip(ClipEditorController? clip, String? id) {
    if (clip == null || clip.selectedClipId == id) return;
    clip.selectClip(id);
    Log.d('ClipsLane', 'selected clip ${id ?? '(none)'}');
  }

  void _handleBeginTrimClip(
    ClipEditorController? clip,
    String clipId,
    ClipTrimEdge edge,
  ) {
    if (clip == null) return;
    clip.beginTrim(clipId, edge);
    Log.d('ClipsLane', 'begin trim ${edge.name} of clip $clipId');
  }

  void _handleUpdateTrimClip(ClipEditorController? clip, int timelineMs) {
    // High-frequency drag path — no per-update log (begin/commit bracket it).
    clip?.updateTrimTo(timelineMs);
  }

  void _handleCommitTrimClip(ClipEditorController? clip) {
    if (clip == null || !clip.isTrimming) return;
    final changed = clip.commitTrim();
    if (changed) {
      Log.d(
        'ClipsLane',
        'commit trim: editedDur=${clip.editedDurationMs}ms, '
            'canUndo=${clip.canUndo}',
      );
    } else {
      // Grabbed and released with no net move, or dragged entirely within an
      // already min-duration-clamped range — surface it so a no-op trim is
      // never read as a successful edit (mirrors the no-op split log).
      Log.d('ClipsLane', 'commit trim: no-op (edge unchanged or clamped)');
    }
  }

  void _handleCancelTrimClip(ClipEditorController? clip) {
    if (clip == null || !clip.isTrimming) return;
    clip.cancelTrim();
    Log.d('ClipsLane', 'cancel trim');
  }

  void _handleBeginReorderClip(ClipEditorController? clip, String clipId) {
    if (clip == null) return;
    // Selecting the clip the drag started on mirrors _handleSelectClip;
    // selectClip self-guards an already-selected id.
    clip.selectClip(clipId);
    Log.d('ClipsLane', 'begin reorder of clip $clipId');
  }

  void _handleCommitReorderClip(
    ClipEditorController? clip,
    String clipId,
    int newIndex,
  ) {
    if (clip == null) return;
    // Capture the old position before the move re-tiles the list, so the log
    // shows the actual reorder (from -> to).
    final from = clip.clips.indexWhere((c) => c.id == clipId);
    clip.moveClipToIndex(clipId, newIndex);
    Log.d(
      'ClipsLane',
      'reorder clip $clipId from index $from -> $newIndex '
          '(now ${clip.clips.length} clips, canUndo=${clip.canUndo})',
    );
  }

  void _handleCancelReorderClip(ClipEditorController? clip) {
    if (clip == null) return;
    Log.d('ClipsLane', 'cancel reorder');
  }

  void _handleUndoClip(ClipEditorController? clip) {
    if (clip == null || !clip.canUndo) return;
    clip.undo();
    Log.d('ClipsLane', 'undo: now ${clip.clips.length} clips');
  }

  void _handleRedoClip(ClipEditorController? clip) {
    if (clip == null || !clip.canRedo) return;
    clip.redo();
    Log.d('ClipsLane', 'redo: now ${clip.clips.length} clips');
  }

  void _toggleZoomLaneVisibility() {
    if (_showZoomLane && !_showMarkersLane) return;
    setState(() => _showZoomLane = !_showZoomLane);
  }

  void _toggleMarkersLaneVisibility() {
    if (_showMarkersLane && !_showZoomLane) return;
    setState(() => _showMarkersLane = !_showMarkersLane);
  }

  String? _buildModeText(AppLocalizations l10n, ZoomEditorController? editor) {
    if (!widget.isReady || editor == null) return null;
    if (editor.addMode == ZoomAddMode.sticky) return l10n.zoomKeepAddingStatus;
    if (editor.addMode == ZoomAddMode.oneShot) return l10n.zoomAddOneStatus;
    if (editor.isTrimming) {
      return editor.activeTrimHandle == TrimHandle.left
          ? l10n.zoomTrimStartStatus
          : l10n.zoomTrimEndStatus;
    }
    if (editor.isMoving) return l10n.zoomMoveStatus;
    if (editor.isBandSelecting) return l10n.zoomBandSelectStatus;
    return null;
  }

  Future<void> _togglePlayback(PlayerController player) async {
    if (!widget.isReady) return;
    if (player.isPlaying) {
      await player.pause();
    } else {
      await player.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = widget.isReady;
    final totalMs = ready && widget.durationMs > 0 ? widget.durationMs : 1;
    final theme = Theme.of(context);
    final chrome = theme.appEditorChrome;
    final l10n = AppLocalizations.of(context)!;
    final tokens = theme.appTokens;
    final metrics = context.shellMetricsOrNull;
    final shellGap = metrics?.timelineShellGap ?? (theme.appSpacing.xs + 2);
    final rawEditor = context.select<PlayerController, ZoomEditorController?>(
      (player) => player.zoomEditor,
    );
    // Phase 10.3: Windows zoom is display-only — manual segments were never
    // persisted (saveManualZoomSegments is a stub), previewed, or exported,
    // so an editable track was a lie. The lane still RENDERS the real auto
    // segments (playerSegments, fed by the native getZoomSegments); nulling
    // the local editor disables every edit affordance in one move.
    final editor = isWindows() ? null : rawEditor;
    final playerSegments = context.select<PlayerController, List<ZoomSegment>>(
      (player) => player.zoomSegments,
    );
    final isPlaying = context.select<PlayerController, bool>(
      (player) => player.isPlaying,
    );
    // The clip editor attaches once the preview is ready (PR-3c2); null until
    // then. Windows clip editing is live now — the export bakes cuts/reorder and
    // the stitched preview (pacer) honors them — so the clip lane is enabled on
    // both platforms. (Zoom editing, above, stays macOS-only: Windows manual zoom
    // segments are still a stub.) Known Windows gap: clip persistence across app
    // restarts isn't ported yet (macOS #203), so edits are in-session only.
    final clipEditor = context.select<PlayerController, ClipEditorController?>(
      (player) => player.clipEditor,
    );
    // Log the attach/detach edge once so "why is the clip lane missing?" leaves
    // a trail. The editor attaches when the preview becomes ready (PR-3c2) and
    // is absent while loading or on Windows.
    if ((clipEditor != null) != _clipEditorAttached) {
      _clipEditorAttached = clipEditor != null;
      Log.d(
        'ClipsLane',
        _clipEditorAttached
            ? 'clip editor attached '
                  '(${clipEditor!.clips.length} clips, '
                  'dur=${clipEditor.recordingDurationMs}ms)'
            : 'clip editor detached',
      );
    }

    final dockContent = ListenableBuilder(
      listenable: Listenable.merge([
        _viewportController,
        if (editor != null) editor,
        if (clipEditor != null) clipEditor,
      ]),
      builder: (context, _) {
        // widget.editingEnabled is false while an export runs: the lanes stay
        // visible and scrubbing works, but every edit affordance below keys
        // off these two flags and goes inert.
        final canEditZoom =
            ready && editor != null && _showZoomLane && widget.editingEnabled;
        final activeEditor = canEditZoom ? editor : null;
        final modeText = _buildModeText(l10n, editor);

        // The clip lane and its controls appear only with a live editor, so a
        // recording that is still loading (or Windows) shows no clip affordances.
        final showClipsLane = _showClipsLane && clipEditor != null;
        final canEditClips = ready && showClipsLane && widget.editingEnabled;

        return Stack(
          clipBehavior: Clip.none,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                TimelineHeaderBar(
                  snappingEnabled: editor?.snappingEnabled ?? false,
                  canEditZoom: canEditZoom,
                  canDelete: activeEditor?.hasSelection ?? false,
                  canUndo: activeEditor?.canUndo ?? false,
                  canRedo: activeEditor?.canRedo ?? false,
                  showZoomLane: _showZoomLane,
                  showMarkersLane: _showMarkersLane,
                  onToggleSnap: canEditZoom ? () => _toggleSnap(editor) : null,
                  onSelectAllVisible: canEditZoom
                      ? () => _handleSelectAllVisible(editor)
                      : null,
                  onSelectAfterPlayhead: canEditZoom
                      ? () => _handleSelectAfterPlayhead(editor)
                      : null,
                  onDeleteSelected: canEditZoom
                      ? () => _handleDeleteSelected(editor)
                      : null,
                  onUndo: activeEditor?.undo,
                  onRedo: activeEditor?.redo,
                  onToggleZoomLaneVisibility: _toggleZoomLaneVisibility,
                  onToggleMarkersLaneVisibility: _toggleMarkersLaneVisibility,
                  // Keep the clip buttons VISIBLE (but disabled via the can*
                  // flags) while editing is suspended for an export — the bar
                  // shouldn't reflow when an export starts.
                  showClipsControls: showClipsLane && ready,
                  canSplitClip: canEditClips,
                  canDeleteClip: canEditClips && clipEditor.canDeleteSelected,
                  canUndoClips: canEditClips && clipEditor.canUndo,
                  canRedoClips: canEditClips && clipEditor.canRedo,
                  onSplitClip: () => _handleSplitClip(clipEditor),
                  onDeleteClip: () => _handleDeleteClip(clipEditor),
                  onUndoClips: () => _handleUndoClip(clipEditor),
                  onRedoClips: () => _handleRedoClip(clipEditor),
                ),
                SizedBox(height: shellGap),
                TimelineTransportBar(
                  isReady: ready,
                  isPlaying: isPlaying,
                  currentTimeLabel: ready ? _fmt(widget.positionMs) : '--:--',
                  totalTimeLabel: ready ? _fmt(widget.durationMs) : '--:--',
                  modeText: modeText,
                  zoomLevel: _viewportController.zoomLevel,
                  minZoom: _viewportController.minZoom,
                  maxZoom: _viewportController.maxZoom,
                  onZoomLevelChanged: (value) =>
                      _viewportController.setZoomLevel(value),
                  onZoomIn: _viewportController.zoomIn,
                  onZoomOut: _viewportController.zoomOut,
                  onFit: () => _viewportController.fitToDuration(
                    centerMs: widget.positionMs,
                  ),
                  onPlayPause: ready
                      ? () => unawaited(
                          _togglePlayback(context.read<PlayerController>()),
                        )
                      : null,
                ),
                SizedBox(height: shellGap),
                TimelineEditorViewport(
                  durationMs: totalMs,
                  positionMs: widget.positionMs,
                  viewportController: _viewportController,
                  segments: playerSegments,
                  editorController: editor,
                  showClipsLane: showClipsLane,
                  clipEditor: clipEditor,
                  onSelectClip: (id) => _handleSelectClip(clipEditor, id),
                  clipTrimCallbacks: canEditClips
                      ? ClipTrimCallbacks(
                          onBegin: (id, edge) =>
                              _handleBeginTrimClip(clipEditor, id, edge),
                          onUpdate: (ms) =>
                              _handleUpdateTrimClip(clipEditor, ms),
                          onCommit: () => _handleCommitTrimClip(clipEditor),
                          onCancel: () => _handleCancelTrimClip(clipEditor),
                        )
                      : null,
                  clipReorderCallbacks: canEditClips
                      ? ClipReorderCallbacks(
                          onBegin: (id) =>
                              _handleBeginReorderClip(clipEditor, id),
                          onCommit: (id, index) =>
                              _handleCommitReorderClip(clipEditor, id, index),
                          onCancel: () => _handleCancelReorderClip(clipEditor),
                        )
                      : null,
                  showZoomLane: _showZoomLane,
                  showMarkersLane: _showMarkersLane,
                  panModeEnabled: _panModeEnabled,
                  cutModeArmed: _cutModeArmed && canEditClips,
                  onCutAt: (ms) => _handleScissorsCut(clipEditor, ms),
                  onSeek: widget.onSeek,
                  onHoverSeek: widget.onHoverSeek,
                  onHoverEnd: widget.onHoverEnd,
                  onHoverChanged: (value) =>
                      setState(() => _hoverPositionMs = value),
                  hoverPositionMs: _hoverPositionMs,
                  onFocusRequested: _requestTimelineFocus,
                ),
              ],
            ),
            if (canEditZoom)
              Positioned(
                top: 0,
                right: 8,
                child: ZoomSegmentBehaviorFloatingToolbar(
                  key: const Key('zoom_behavior_floating_toolbar'),
                  editor: editor,
                  nativeBridge: NativeBridge.instance,
                  sessionId: editor.sessionId,
                  viewportController: _viewportController,
                  durationMs: totalMs,
                ),
              ),
          ],
        );
      },
    );

    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.delete): DeleteSelectedZoomIntent(),
        SingleActivator(LogicalKeyboardKey.backspace):
            DeleteSelectedZoomIntent(),
        SingleActivator(LogicalKeyboardKey.escape): ClearZoomSelectionIntent(),
        SingleActivator(LogicalKeyboardKey.keyA, meta: true):
            SelectAllZoomIntent(),
        SingleActivator(LogicalKeyboardKey.keyA, control: true):
            SelectAllZoomIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          DeleteSelectedZoomIntent: CallbackAction<DeleteSelectedZoomIntent>(
            onInvoke: (_) {
              // Editing suspended (export in flight): the key must be as
              // inert as the disabled toolbar buttons it mirrors.
              if (!widget.editingEnabled) return null;
              // Backspace/Delete removes the selected CLIP first — that's what
              // the key usually means over the clip lane — falling back to the
              // selected zoom segment when no (deletable) clip is selected.
              if (clipEditor?.canDeleteSelected ?? false) {
                _handleDeleteClip(clipEditor);
              } else {
                _handleDeleteSelected(editor);
              }
              return null;
            },
          ),
          ClearZoomSelectionIntent: CallbackAction<ClearZoomSelectionIntent>(
            onInvoke: (_) {
              _handleClearOrEscape(editor);
              return null;
            },
          ),
          SelectAllZoomIntent: CallbackAction<SelectAllZoomIntent>(
            onInvoke: (_) {
              _handleSelectAllVisible(editor);
              return null;
            },
          ),
        },
        child: Focus(
          focusNode: _zoomEditorFocusNode,
          canRequestFocus: true,
          onFocusChange: (hasFocus) {
            _timelineHasFocus = hasFocus;
            if (!hasFocus) {
              _setPanModeEnabled(false);
            }
            // Re-derive the cut tool from the live keyboard + new focus state:
            // on gain it arms if Option is already held (so hold-then-click works
            // without releasing the key); on loss it disarms (focus gates it).
            _syncCutModeFromKeyboard();
          },
          onKeyEvent: _handleTimelineKeyEvent,
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => _requestTimelineFocus(),
            child: Container(
              key: const Key('timeline_shell'),
              padding: EdgeInsets.zero,
              decoration: BoxDecoration(
                color: tokens.timelineBackground,
                borderRadius: BorderRadius.circular(chrome.panelRadius),
              ),
              child: RepaintBoundary(child: dockContent),
            ),
          ),
        ),
      ),
    );
  }
}
