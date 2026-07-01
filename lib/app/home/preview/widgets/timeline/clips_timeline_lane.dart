import 'dart:ui' as ui;

import 'package:clingfy/app/home/preview/widgets/timeline/timeline_viewport_controller.dart';
import 'package:clingfy/core/clips/clip_editor_controller.dart';
import 'package:clingfy/core/timeline/clip_timeline.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:clingfy/ui/platform/widgets/responsive_shell_scope.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';

/// The drag callbacks the clip lane uses to trim a clip edge. Routed to the
/// owner ([_VideoTimelineState]) so each trim is logged and goes through the
/// shared [ClipEditorController] trim lifecycle (one undo entry per drag).
@immutable
class ClipTrimCallbacks {
  const ClipTrimCallbacks({
    required this.onBegin,
    required this.onUpdate,
    required this.onCommit,
    required this.onCancel,
  });

  /// A trim drag started on [edge] of clip [clipId].
  final void Function(String clipId, ClipTrimEdge edge) onBegin;

  /// The dragged edge moved to [timelineMs] on the edited timeline.
  final ValueChanged<int> onUpdate;

  /// The drag ended — commit it as a single undo entry.
  final VoidCallback onCommit;

  /// The drag was cancelled — restore the pre-drag clips.
  final VoidCallback onCancel;
}

/// The drag callbacks the clip lane uses to reorder a clip. Routed to the owner
/// ([_VideoTimelineState]) so each reorder is logged and goes through the shared
/// [ClipEditorController.moveClipToIndex] (one undo entry per drag).
///
/// Unlike trimming, a reorder is committed once on release — there is no live
/// `onUpdate`, so the preview is never re-synced mid-drag (no native thrash, one
/// undo entry). During the drag only the lane's own local state changes.
@immutable
class ClipReorderCallbacks {
  const ClipReorderCallbacks({
    required this.onBegin,
    required this.onCommit,
    required this.onCancel,
  });

  /// A reorder drag started on clip [clipId] (select it + log).
  final void Function(String clipId) onBegin;

  /// The drag ended; move [clipId] to enabled-list index [newIndex] (one undo
  /// entry).
  final void Function(String clipId, int newIndex) onCommit;

  /// The drag was cancelled — no model change happened during the drag.
  final VoidCallback onCancel;
}

/// The clip (split / cut / arrange) lane on the editing timeline.
///
/// Renders the [ClipEditorController]'s enabled clips as contiguous boxes
/// positioned along the *edited* timeline (cumulative kept durations), with the
/// selected clip highlighted. Tapping a box selects it; tapping the empty lane
/// clears the selection. The selected clip also grows a right-edge **trim
/// handle**: dragging it trims the clip's end live in the preview (one undo per
/// drag). Dragging a clip box itself horizontally **reorders** it among the
/// other clips, committed once on release as a single undo entry (no live
/// preview thrash mid-drag — only local lane state moves while dragging).
///
/// Only the END edge is draggable. On this gapless timeline a clip's start is
/// pinned to the previous clip's end, so a left-edge drag could never move the
/// edge it grabs — trimming a clip's start is done with split + delete instead.
///
/// Positioning mirrors [TimelinePlayheadOverlay]: it lives inside the
/// content-width scrollable canvas and maps ms→px via the shared
/// [TimelineViewportController], so it stays pixel-aligned with the ruler,
/// playhead, and zoom lane. Trim drags map px→ms through the lane's own
/// [RenderBox] (a stable frame), not the moving handle, so a live trim can't
/// chase its own tail.
class ClipsTimelineLane extends StatefulWidget {
  const ClipsTimelineLane({
    super.key,
    required this.clips,
    required this.selectedClipId,
    required this.viewportController,
    required this.onSelectClip,
    this.trimCallbacks,
    this.reorderCallbacks,
  });

  /// The current clip list (already normalized: contiguous in timeline order).
  final List<Clip> clips;

  /// The id of the selected clip, or null when nothing is selected.
  final String? selectedClipId;

  final TimelineViewportController viewportController;

  /// Called with a clip id on tap, or null when the empty lane is tapped.
  final ValueChanged<String?> onSelectClip;

  /// Trim drag hooks. When null, no trim handles are shown (trim disabled).
  final ClipTrimCallbacks? trimCallbacks;

  /// Reorder drag hooks. When null, drag-to-reorder is disabled (no drag
  /// handlers are wired, so a horizontal drag bubbles to the scroll view).
  final ClipReorderCallbacks? reorderCallbacks;

  @override
  State<ClipsTimelineLane> createState() => _ClipsTimelineLaneState();
}

class _ClipsTimelineLaneState extends State<ClipsTimelineLane> {
  // Stable across rebuilds so a live trim drag maps the pointer through the
  // lane's fixed coordinate space (the handle itself moves while trimming).
  final GlobalKey _stackKey = GlobalKey();

  // Live reorder-drag state. The reorder is committed once on release, so during
  // the drag only this local state changes — a floating box that follows the
  // pointer plus a drop indicator — with no native sync or history churn until
  // the pointer is lifted.
  String? _reorderingClipId;
  double _reorderDx = 0;
  int? _reorderTargetIndex;

  /// Maps a global pointer position to a timeline ms via the lane's RenderBox,
  /// or null if the lane is not laid out yet.
  int? _timelineMsFromGlobal(Offset global) {
    final renderObject = _stackKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox) return null;
    final localX = renderObject.globalToLocal(global).dx;
    return widget.viewportController.canvasXToMs(localX);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chrome = theme.appEditorChrome;
    final tokens = theme.appTokens;
    final metrics = context.shellMetricsOrNull;
    final laneHeight = metrics?.timelineLaneHeight ?? chrome.timelineLaneHeight;
    final accent = theme.colorScheme.primary;

    final enabled = widget.clips
        .where((c) => c.enabled)
        .toList(growable: false);
    // Map via the shared viewport controller (same as the ruler and playhead)
    // rather than scaling by the editor's own editedDurationMs. This keeps the
    // boxes pixel-locked to the ruler/playhead in steady state; the cost is a
    // single frame after a delete where the boxes briefly under-fill the canvas
    // until the native tick reports the new edited duration. We accept that
    // one-frame transient over a permanent sub-pixel mismatch (native rounds the
    // edited duration to frame boundaries; the Dart sum does not).
    final contentWidth = widget.viewportController.contentWidth;

    final geometries = <_ClipGeometry>[
      for (var i = 0; i < enabled.length; i++)
        _geometryFor(enabled[i], index: i, contentWidth: contentWidth),
    ];

    // Reorder is wired only with a real handler and at least two clips to swap
    // between. Every clip is enabled today (the per-clip-mute path is unused),
    // so a clip's index among the enabled boxes equals its index in the full
    // list — exactly the [newIndex] [ClipEditorController.moveClipToIndex]
    // expects. If muting ever lands, the target index must be remapped from the
    // enabled order back to the full list before committing.
    final canReorder = widget.reorderCallbacks != null && enabled.length >= 2;

    // Paint widest-first so the narrowest boxes land on top. That matters only
    // when a sub-pixel-short clip is floored to [_kMinClipBoxWidth] and overlaps
    // a wide neighbour: putting the small box on top keeps it both visible and
    // tappable (otherwise the neighbour — or the background — would steal it).
    final ordered = [...geometries]..sort((a, b) => b.width.compareTo(a.width));
    // A lifted (dragging) clip floats above every other box regardless of width,
    // so re-append it last in paint order while a reorder drag is in flight.
    if (_reorderingClipId != null) {
      final draggedAt = ordered.indexWhere(
        (g) => g.clip.id == _reorderingClipId,
      );
      if (draggedAt >= 0) ordered.add(ordered.removeAt(draggedAt));
    }

    _ClipGeometry? selectedGeometry;
    for (final g in geometries) {
      if (g.clip.id == widget.selectedClipId) {
        selectedGeometry = g;
        break;
      }
    }

    return Container(
      key: const Key('clips_timeline_lane'),
      height: laneHeight,
      decoration: BoxDecoration(
        color: tokens.timelineLaneSurface,
        borderRadius: BorderRadius.circular(chrome.controlRadius),
        border: Border.all(color: tokens.panelBorder),
      ),
      clipBehavior: ui.Clip.hardEdge,
      child: Stack(
        key: _stackKey,
        children: [
          // Background tap target clears the selection.
          Positioned.fill(
            child: GestureDetector(
              key: const Key('clips_timeline_lane_background'),
              behavior: HitTestBehavior.opaque,
              onTap: () => widget.onSelectClip(null),
            ),
          ),
          for (final geometry in ordered)
            _buildClipBox(
              context,
              geometry: geometry,
              geometries: geometries,
              accent: accent,
              canReorder: canReorder,
            ),
          // A drop indicator marks where the lifted clip will land. Drawn over
          // the boxes only while a reorder drag is in flight.
          if (_reorderingClipId != null && _reorderTargetIndex != null)
            _buildReorderIndicator(geometries: geometries, accent: accent),
          // The end-trim handle paints on top of every box, for the selected
          // clip only. (Start-trim is intentionally not a drag — see the class
          // doc — so only the end edge gets a handle.) It is suppressed mid-
          // reorder so it does not float oddly on the lifted clip.
          if (widget.trimCallbacks != null &&
              selectedGeometry != null &&
              _reorderingClipId == null)
            _buildTrimHandle(
              geometry: selectedGeometry,
              edge: ClipTrimEdge.end,
              accent: accent,
              canReorder: canReorder,
            ),
        ],
      ),
    );
  }

  _ClipGeometry _geometryFor(
    Clip clip, {
    required int index,
    required double contentWidth,
  }) {
    final startX = widget.viewportController.msToCanvasX(clip.timelineStartMs);
    final endMs = clip.timelineStartMs + ClipTimeline.clipDurationMs(clip);
    final endX = widget.viewportController.msToCanvasX(endMs);
    final rawWidth = (endX - startX).clamp(0.0, double.infinity);

    // Inset a 1px seam on each side to reveal cut boundaries, but never below a
    // minimum width — a 33ms clip on a 10-minute recording is sub-pixel at
    // zoom 1 and would otherwise vanish (and steal-clear taps) entirely.
    const seam = 1.0;
    double left;
    double width;
    if (rawWidth >= _kMinClipBoxWidth + seam * 2) {
      left = startX + seam;
      width = rawWidth - seam * 2;
    } else {
      width = _kMinClipBoxWidth;
      left = startX;
    }
    // Keep a floored box inside the canvas so a clip at the very end stays
    // visible and hit-testable rather than being clipped past the edge.
    if (contentWidth > 0 && left + width > contentWidth) {
      left = (contentWidth - width).clamp(0.0, double.infinity);
    }

    return _ClipGeometry(clip: clip, index: index, left: left, width: width);
  }

  Widget _buildClipBox(
    BuildContext context, {
    required _ClipGeometry geometry,
    required List<_ClipGeometry> geometries,
    required Color accent,
    required bool canReorder,
  }) {
    final theme = Theme.of(context);
    final clip = geometry.clip;
    final selected = clip.id == widget.selectedClipId;
    final lifted = clip.id == _reorderingClipId;
    final fill = selected
        ? accent.withValues(alpha: 0.26)
        : accent.withValues(alpha: 0.12);
    final borderColor = selected ? accent : accent.withValues(alpha: 0.32);
    // While lifted the box follows the pointer by the accumulated drag delta,
    // and reads as raised (a soft shadow + a touch of transparency).
    final left = lifted ? geometry.left + _reorderDx : geometry.left;

    return Positioned(
      key: Key('clips_timeline_lane_clip_pos_${clip.id}'),
      left: left,
      top: 4,
      bottom: 4,
      width: geometry.width,
      child: GestureDetector(
        key: Key('clips_timeline_lane_clip_${clip.id}'),
        behavior: HitTestBehavior.opaque,
        // Tap still selects; a real horizontal drag (past touch slop) reorders.
        // Flutter's gesture arena separates the two, exactly like the trim
        // handle. The drag handlers are wired only when reorder is enabled, so
        // otherwise a horizontal drag bubbles to the timeline's scroll view.
        onTap: () => widget.onSelectClip(clip.id),
        onHorizontalDragStart: canReorder
            ? (_) {
                setState(() {
                  _reorderingClipId = clip.id;
                  _reorderDx = 0;
                  _reorderTargetIndex = geometry.index;
                });
                widget.reorderCallbacks!.onBegin(clip.id);
              }
            : null,
        onHorizontalDragUpdate: canReorder
            ? (details) {
                setState(() {
                  _reorderDx += details.delta.dx;
                  _reorderTargetIndex = _reorderTargetFor(
                    geometries,
                    geometry.index,
                    _reorderDx,
                  );
                });
              }
            : null,
        onHorizontalDragEnd: canReorder
            ? (_) {
                final id = _reorderingClipId;
                final from = geometry.index;
                final target = _reorderTargetIndex ?? from;
                setState(() {
                  _reorderingClipId = null;
                  _reorderDx = 0;
                  _reorderTargetIndex = null;
                });
                // Commit only a real move; dropping in place is a no-op (the
                // controller would no-op too, but skipping keeps the logs
                // clean and avoids a redundant native push).
                if (id != null && target != from) {
                  widget.reorderCallbacks!.onCommit(id, target);
                }
              }
            : null,
        onHorizontalDragCancel: canReorder
            ? () {
                setState(() {
                  _reorderingClipId = null;
                  _reorderDx = 0;
                  _reorderTargetIndex = null;
                });
                widget.reorderCallbacks!.onCancel();
              }
            : null,
        child: Semantics(
          button: true,
          selected: selected,
          label: 'Clip ${geometry.index + 1}',
          child: Opacity(
            opacity: lifted ? 0.85 : 1,
            child: Container(
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: borderColor, width: selected ? 2 : 1),
                boxShadow: lifted
                    ? [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.32),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ]
                    : null,
              ),
              alignment: Alignment.center,
              child: geometry.width >= 22
                  ? Text(
                      '${geometry.index + 1}',
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.8,
                        ),
                        fontWeight: FontWeight.w600,
                      ),
                    )
                  : null,
            ),
          ),
        ),
      ),
    );
  }

  /// The enabled-list index the dragged clip would land at for the live
  /// horizontal translation [dx]. Counts the other enabled clips whose centre
  /// sits left of the dragged clip's translated centre; that count is exactly
  /// the [newIndex] for [ClipEditorController.moveClipToIndex] on this gapless,
  /// all-enabled timeline (see `canReorder` in [build]).
  int _reorderTargetFor(
    List<_ClipGeometry> geometries,
    int fromIdx,
    double dx,
  ) {
    final draggedCenter =
        geometries[fromIdx].left + geometries[fromIdx].width / 2 + dx;
    var target = 0;
    for (var j = 0; j < geometries.length; j++) {
      if (j == fromIdx) continue;
      final centerJ = geometries[j].left + geometries[j].width / 2;
      if (centerJ < draggedCenter) target += 1;
    }
    return target;
  }

  /// A thin accent line at the boundary where the lifted clip will drop: the
  /// left edge of the target slot, or the right edge of the last clip when the
  /// drop is past the end.
  Widget _buildReorderIndicator({
    required List<_ClipGeometry> geometries,
    required Color accent,
  }) {
    final others = <_ClipGeometry>[
      for (final g in geometries)
        if (g.clip.id != _reorderingClipId) g,
    ];
    if (others.isEmpty) return const SizedBox.shrink();
    final target = (_reorderTargetIndex ?? 0).clamp(0, others.length);
    final edgeX = target < others.length
        ? others[target].left
        : others.last.left + others.last.width;

    const indicatorWidth = 2.0;
    final contentWidth = widget.viewportController.contentWidth;
    final maxLeft = (contentWidth - indicatorWidth).clamp(0.0, double.infinity);
    final left = (edgeX - indicatorWidth / 2).clamp(0.0, maxLeft);

    return Positioned(
      key: const Key('clips_timeline_lane_reorder_indicator'),
      left: left,
      top: 2,
      bottom: 2,
      width: indicatorWidth,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: accent,
            borderRadius: BorderRadius.circular(indicatorWidth / 2),
          ),
        ),
      ),
    );
  }

  Widget _buildTrimHandle({
    required _ClipGeometry geometry,
    required ClipTrimEdge edge,
    required Color accent,
    required bool canReorder,
  }) {
    final clip = geometry.clip;
    final edgeX = edge == ClipTrimEdge.start
        ? geometry.left
        : geometry.left + geometry.width;

    // The end-trim handle is opaque and paints on top of the clip box, so it
    // also captures a body drag that would otherwise reorder. On a wide clip the
    // 22px handle still leaves plenty of body to grab; on a narrow selected clip
    // it can blanket the whole box and trap reorder. When reorder is live, cap
    // the hit width so a [_kReorderBodyStrip]-wide grab strip always survives on
    // the body — wide clips are unaffected (the cap floors at the full width).
    final hitWidth = canReorder
        ? (geometry.width - _kReorderBodyStrip).clamp(
            _kTrimHandleBarWidth,
            _kTrimHandleHitWidth,
          )
        : _kTrimHandleHitWidth;

    // Clamp the grab area fully inside the hard-clipped lane so an edge sitting
    // at x=0 or x=contentWidth (e.g. the last clip's end) is still grabbable
    // across its whole width — the box layout makes the same clamp.
    final contentWidth = widget.viewportController.contentWidth;
    final maxLeft = (contentWidth - hitWidth).clamp(0.0, double.infinity);
    final handleLeft = (edgeX - hitWidth / 2).clamp(0.0, maxLeft);
    // Keep the visible bar on the true edge even when the hit area was shifted
    // inward to stay on-canvas.
    final barLeft = (edgeX - handleLeft - _kTrimHandleBarWidth / 2).clamp(
      0.0,
      hitWidth - _kTrimHandleBarWidth,
    );
    final trim = widget.trimCallbacks!;

    void update(Offset globalPosition) {
      final ms = _timelineMsFromGlobal(globalPosition);
      if (ms != null) trim.onUpdate(ms);
    }

    return Positioned(
      key: Key('clips_timeline_lane_trim_${edge.name}_${clip.id}'),
      left: handleLeft,
      top: 2,
      bottom: 2,
      width: hitWidth,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // Tapping a handle just (re)selects its clip; dragging trims.
          onTap: () => widget.onSelectClip(clip.id),
          onHorizontalDragStart: (_) => trim.onBegin(clip.id, edge),
          onHorizontalDragUpdate: (d) => update(d.globalPosition),
          onHorizontalDragEnd: (_) => trim.onCommit(),
          onHorizontalDragCancel: trim.onCancel,
          child: Stack(
            children: [
              Positioned(
                left: barLeft,
                top: 0,
                bottom: 0,
                width: _kTrimHandleBarWidth,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(
                      _kTrimHandleBarWidth / 2,
                    ),
                    // A light outline + soft shadow so the handle reads as a
                    // distinct grab affordance against the accent-tinted,
                    // accent-bordered selected clip (otherwise it blends in).
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.92),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.28),
                        blurRadius: 3,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Resolved layout for one clip box on the lane.
@immutable
class _ClipGeometry {
  const _ClipGeometry({
    required this.clip,
    required this.index,
    required this.left,
    required this.width,
  });

  final Clip clip;
  final int index;
  final double left;
  final double width;
}

/// The smallest a clip box may render, so a sub-pixel-short clip stays visible
/// and tappable. Below this the box is floored and painted on top of its
/// neighbour (see [ClipsTimelineLane.build]).
const double _kMinClipBoxWidth = 8.0;

/// The grab width of a trim handle (wider than the visible bar for easy
/// targeting) and the visible bar width. The hit area is generous because the
/// handle only shows on the selected clip and must be findable + grabbable with
/// a mouse on a dense timeline; the visible bar is wide enough to actually spot.
const double _kTrimHandleHitWidth = 22.0;
const double _kTrimHandleBarWidth = 6.0;

/// The grab strip kept clear of the trim handle on the body of a selected clip
/// when reorder is enabled, so a narrow clip can still be dragged to reorder
/// instead of the opaque handle swallowing the whole box (see [_buildTrimHandle]).
const double _kReorderBodyStrip = 14.0;
