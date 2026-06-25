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

/// The clip (split / cut / arrange) lane on the editing timeline.
///
/// Renders the [ClipEditorController]'s enabled clips as contiguous boxes
/// positioned along the *edited* timeline (cumulative kept durations), with the
/// selected clip highlighted. Tapping a box selects it; tapping the empty lane
/// clears the selection. The selected clip also grows a right-edge **trim
/// handle**: dragging it trims the clip's end live in the preview (one undo per
/// drag). Drag-to-reorder lands in a later PR.
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

  @override
  State<ClipsTimelineLane> createState() => _ClipsTimelineLaneState();
}

class _ClipsTimelineLaneState extends State<ClipsTimelineLane> {
  // Stable across rebuilds so a live trim drag maps the pointer through the
  // lane's fixed coordinate space (the handle itself moves while trimming).
  final GlobalKey _stackKey = GlobalKey();

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

    // Paint widest-first so the narrowest boxes land on top. That matters only
    // when a sub-pixel-short clip is floored to [_kMinClipBoxWidth] and overlaps
    // a wide neighbour: putting the small box on top keeps it both visible and
    // tappable (otherwise the neighbour — or the background — would steal it).
    final ordered = [...geometries]..sort((a, b) => b.width.compareTo(a.width));

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
            _buildClipBox(context, geometry: geometry, accent: accent),
          // The end-trim handle paints on top of every box, for the selected
          // clip only. (Start-trim is intentionally not a drag — see the class
          // doc — so only the end edge gets a handle.)
          if (widget.trimCallbacks != null && selectedGeometry != null)
            _buildTrimHandle(
              geometry: selectedGeometry,
              edge: ClipTrimEdge.end,
              accent: accent,
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
    required Color accent,
  }) {
    final theme = Theme.of(context);
    final clip = geometry.clip;
    final selected = clip.id == widget.selectedClipId;
    final fill = selected
        ? accent.withValues(alpha: 0.26)
        : accent.withValues(alpha: 0.12);
    final borderColor = selected ? accent : accent.withValues(alpha: 0.32);

    return Positioned(
      key: Key('clips_timeline_lane_clip_pos_${clip.id}'),
      left: geometry.left,
      top: 4,
      bottom: 4,
      width: geometry.width,
      child: GestureDetector(
        key: Key('clips_timeline_lane_clip_${clip.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.onSelectClip(clip.id),
        child: Semantics(
          button: true,
          selected: selected,
          label: 'Clip ${geometry.index + 1}',
          child: Container(
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: borderColor, width: selected ? 2 : 1),
            ),
            alignment: Alignment.center,
            child: geometry.width >= 22
                ? Text(
                    '${geometry.index + 1}',
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
                      fontWeight: FontWeight.w600,
                    ),
                  )
                : null,
          ),
        ),
      ),
    );
  }

  Widget _buildTrimHandle({
    required _ClipGeometry geometry,
    required ClipTrimEdge edge,
    required Color accent,
  }) {
    final clip = geometry.clip;
    final edgeX = edge == ClipTrimEdge.start
        ? geometry.left
        : geometry.left + geometry.width;

    // Clamp the grab area fully inside the hard-clipped lane so an edge sitting
    // at x=0 or x=contentWidth (e.g. the last clip's end) is still grabbable
    // across its whole width — the box layout makes the same clamp.
    final contentWidth = widget.viewportController.contentWidth;
    final maxLeft = (contentWidth - _kTrimHandleHitWidth).clamp(
      0.0,
      double.infinity,
    );
    final handleLeft = (edgeX - _kTrimHandleHitWidth / 2).clamp(0.0, maxLeft);
    // Keep the visible bar on the true edge even when the hit area was shifted
    // inward to stay on-canvas.
    final barLeft = (edgeX - handleLeft - _kTrimHandleBarWidth / 2).clamp(
      0.0,
      _kTrimHandleHitWidth - _kTrimHandleBarWidth,
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
      width: _kTrimHandleHitWidth,
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
/// targeting) and the visible bar width.
const double _kTrimHandleHitWidth = 14.0;
const double _kTrimHandleBarWidth = 4.0;
