import 'package:clingfy/app/home/post_processing/widgets/zoom_track.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/zoom/zoom_editor_controller.dart';
import 'package:clingfy/ui/platform/widgets/responsive_shell_scope.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';

class ZoomTimelineLane extends StatelessWidget {
  const ZoomTimelineLane({
    super.key,
    required this.segments,
    required this.durationMs,
    required this.positionMs,
    required this.editorController,
    this.onQuickSeek,
    this.onFocusRequested,
  });

  final List<ZoomSegment> segments;
  final int durationMs;
  final int positionMs;
  final ZoomEditorController? editorController;
  final ValueChanged<int>? onQuickSeek;
  final VoidCallback? onFocusRequested;

  @override
  Widget build(BuildContext context) {
    final tokens = context.appTokens;
    final metrics = context.shellMetricsOrNull;
    final baseLaneHeight =
        metrics?.timelineLaneHeight ??
        context.appEditorChrome.timelineLaneHeight;
    final laneHeight = zoomLaneHeightFor(baseLaneHeight);

    return SizedBox(
      key: const Key('zoom_timeline_lane'),
      height: laneHeight,
      child: ZoomTrack(
        segments: segments,
        durationMs: durationMs,
        positionMs: positionMs,
        onQuickSeek: onQuickSeek,
        editorController: editorController,
        onFocusRequested: onFocusRequested,
        height: laneHeight,
        showSegmentLabels: true,
        shellColor: tokens.timelineLaneSurface,
        shellBorderColor: tokens.panelBorder,
      ),
    );
  }
}

/// Extra vertical room added to the zoom lane on top of the shared
/// timelineLaneHeight token, so the segment thumb has more drag headroom.
const double kZoomLaneHeightBoost = 14;

/// Derives the zoom lane height from the shared timeline lane height,
/// keeping a single source of truth for any caller that needs to size or
/// reserve space for the zoom lane (e.g. viewport sizing math).
double zoomLaneHeightFor(double baseLaneHeight) =>
    baseLaneHeight + kZoomLaneHeightBoost;
