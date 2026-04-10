import 'package:clingfy/app/home/post_processing/widgets/zoom_track.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/zoom/zoom_editor_controller.dart';
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

    return SizedBox(
      key: const Key('zoom_timeline_lane'),
      height: context.appEditorChrome.timelineLaneHeight,
      child: ZoomTrack(
        segments: segments,
        durationMs: durationMs,
        positionMs: positionMs,
        onQuickSeek: onQuickSeek,
        editorController: editorController,
        onFocusRequested: onFocusRequested,
        height: context.appEditorChrome.timelineLaneHeight,
        showSegmentLabels: true,
        shellColor: tokens.timelineLaneSurface,
        shellBorderColor: tokens.panelBorder,
      ),
    );
  }
}
