import 'dart:ui' as ui;

import 'package:clingfy/app/home/preview/widgets/timeline/timeline_viewport_controller.dart';
import 'package:clingfy/core/clips/clip_editor_controller.dart';
import 'package:clingfy/core/timeline/clip_timeline.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:clingfy/ui/platform/widgets/responsive_shell_scope.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';

/// The clip (split / cut / arrange) lane on the editing timeline.
///
/// Renders the [ClipEditorController]'s enabled clips as contiguous boxes
/// positioned along the *edited* timeline (cumulative kept durations), with the
/// selected clip highlighted. Tapping a box selects it; tapping the empty lane
/// clears the selection. Trim handles and drag-to-reorder land in a later PR —
/// this lane is select-only.
///
/// Positioning mirrors [TimelinePlayheadOverlay]: it lives inside the
/// content-width scrollable canvas and maps ms→px via the shared
/// [TimelineViewportController], so it stays pixel-aligned with the ruler,
/// playhead, and zoom lane.
class ClipsTimelineLane extends StatelessWidget {
  const ClipsTimelineLane({
    super.key,
    required this.clips,
    required this.selectedClipId,
    required this.viewportController,
    required this.onSelectClip,
  });

  /// The current clip list (already normalized: contiguous in timeline order).
  final List<Clip> clips;

  /// The id of the selected clip, or null when nothing is selected.
  final String? selectedClipId;

  final TimelineViewportController viewportController;

  /// Called with a clip id on tap, or null when the empty lane is tapped.
  final ValueChanged<String?> onSelectClip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chrome = theme.appEditorChrome;
    final tokens = theme.appTokens;
    final metrics = context.shellMetricsOrNull;
    final laneHeight = metrics?.timelineLaneHeight ?? chrome.timelineLaneHeight;
    final accent = theme.colorScheme.primary;

    final enabled = clips.where((c) => c.enabled).toList(growable: false);
    // Map via the shared viewport controller (same as the ruler and playhead)
    // rather than scaling by the editor's own editedDurationMs. This keeps the
    // boxes pixel-locked to the ruler/playhead in steady state; the cost is a
    // single frame after a delete where the boxes briefly under-fill the canvas
    // until the native tick reports the new edited duration. We accept that
    // one-frame transient over a permanent sub-pixel mismatch (native rounds the
    // edited duration to frame boundaries; the Dart sum does not).
    final contentWidth = viewportController.contentWidth;

    // Build each box with its rendered width, then paint widest-first so the
    // narrowest boxes land on top. That matters only when a sub-pixel-short clip
    // is floored to [_kMinClipBoxWidth] and overlaps a wide neighbour: putting
    // the small box on top keeps it both visible and tappable (otherwise the
    // neighbour — or the background — would steal the tap).
    final boxes = <({double width, Widget widget})>[
      for (var i = 0; i < enabled.length; i++)
        _buildClipBox(
          context,
          clip: enabled[i],
          index: i,
          accent: accent,
          contentWidth: contentWidth,
        ),
    ]..sort((a, b) => b.width.compareTo(a.width));

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
        children: [
          // Background tap target clears the selection.
          Positioned.fill(
            child: GestureDetector(
              key: const Key('clips_timeline_lane_background'),
              behavior: HitTestBehavior.opaque,
              onTap: () => onSelectClip(null),
            ),
          ),
          for (final box in boxes) box.widget,
        ],
      ),
    );
  }

  ({double width, Widget widget}) _buildClipBox(
    BuildContext context, {
    required Clip clip,
    required int index,
    required Color accent,
    required double contentWidth,
  }) {
    final theme = Theme.of(context);
    final startX = viewportController.msToCanvasX(clip.timelineStartMs);
    final endMs = clip.timelineStartMs + ClipTimeline.clipDurationMs(clip);
    final endX = viewportController.msToCanvasX(endMs);
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

    final selected = clip.id == selectedClipId;
    final fill = selected
        ? accent.withValues(alpha: 0.26)
        : accent.withValues(alpha: 0.12);
    final borderColor = selected ? accent : accent.withValues(alpha: 0.32);

    final widget = Positioned(
      key: Key('clips_timeline_lane_clip_pos_${clip.id}'),
      left: left,
      top: 4,
      bottom: 4,
      width: width,
      child: GestureDetector(
        key: Key('clips_timeline_lane_clip_${clip.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: () => onSelectClip(clip.id),
        child: Semantics(
          button: true,
          selected: selected,
          label: 'Clip ${index + 1}',
          child: Container(
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: borderColor, width: selected ? 2 : 1),
            ),
            alignment: Alignment.center,
            child: width >= 22
                ? Text(
                    '${index + 1}',
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

    return (width: width, widget: widget);
  }
}

/// The smallest a clip box may render, so a sub-pixel-short clip stays visible
/// and tappable. Below this the box is floored and painted on top of its
/// neighbour (see [ClipsTimelineLane.build]).
const double _kMinClipBoxWidth = 8.0;
