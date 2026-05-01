import 'package:clingfy/app/home/preview/widgets/timeline/timeline_ruler_metrics.dart';
import 'package:clingfy/ui/platform/widgets/responsive_shell_scope.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';

class MarkersTimelineLane extends StatelessWidget {
  const MarkersTimelineLane({
    super.key,
    required this.durationMs,
    required this.visibleStartMs,
    required this.visibleEndMs,
    required this.visibleWidth,
  });

  final int durationMs;
  final int visibleStartMs;
  final int visibleEndMs;
  final double visibleWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chrome = theme.appEditorChrome;
    final tokens = theme.appTokens;
    final metrics = context.shellMetricsOrNull;

    return Container(
      key: const Key('markers_timeline_lane'),
      height: metrics?.timelineLaneHeight ?? chrome.timelineLaneHeight,
      decoration: BoxDecoration(
        color: tokens.timelineLaneSurface,
        borderRadius: BorderRadius.circular(chrome.controlRadius),
        border: Border.all(color: tokens.panelBorder),
      ),
      child: CustomPaint(
        key: const Key('markers_timeline_lane_paint'),
        painter: MarkersTimelineLanePainter(
          durationMs: durationMs,
          lineColor: tokens.timelineTick.withValues(alpha: 0.28),
          pinColor: theme.colorScheme.primary.withValues(alpha: 0.24),
          visibleStartMs: visibleStartMs,
          visibleEndMs: visibleEndMs,
          visibleWidth: visibleWidth,
          markerStrokeWidth: metrics?.timelineMarkerStrokeWidth ?? 1.25,
          pinUp: metrics?.timelineMarkerPinUp ?? 8,
          pinDown: metrics?.timelineMarkerPinDown ?? 5,
          maxVisiblePins: metrics?.timelineMarkerMaxVisiblePins ?? 8,
          minMajorTickSpacing:
              metrics?.timelineRulerMinMajorTickSpacing ?? 110,
        ),
      ),
    );
  }
}

class MarkersTimelineLanePainter extends CustomPainter {
  const MarkersTimelineLanePainter({
    required this.durationMs,
    required this.lineColor,
    required this.pinColor,
    required this.visibleStartMs,
    required this.visibleEndMs,
    required this.visibleWidth,
    this.markerStrokeWidth = 1.25,
    this.pinUp = 8,
    this.pinDown = 5,
    this.maxVisiblePins = 8,
    this.minMajorTickSpacing = 110,
  });

  final int durationMs;
  final Color lineColor;
  final Color pinColor;
  final int visibleStartMs;
  final int visibleEndMs;
  final double visibleWidth;
  final double markerStrokeWidth;
  final double pinUp;
  final double pinDown;
  final int maxVisiblePins;
  final double minMajorTickSpacing;

  @override
  void paint(Canvas canvas, Size size) {
    final midY = size.height / 2;
    canvas.drawLine(
      Offset(0, midY),
      Offset(size.width, midY),
      Paint()
        ..color = lineColor
        ..strokeWidth = 1,
    );

    if (durationMs <= 0) return;

    final ticks = TimelineRulerMetrics.buildSparseMarkerTicks(
      durationMs: durationMs,
      visibleStartMs: visibleStartMs,
      visibleEndMs: visibleEndMs,
      visibleWidth: visibleWidth,
      maxVisiblePins: maxVisiblePins,
      minMajorTickSpacingPx: minMajorTickSpacing,
    );

    final pinPaint = Paint()
      ..color = pinColor
      ..strokeWidth = markerStrokeWidth;
    for (final tickMs in ticks) {
      final x = (tickMs / durationMs) * size.width;
      canvas.drawLine(
        Offset(x, midY - pinUp),
        Offset(x, midY + pinDown),
        pinPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant MarkersTimelineLanePainter oldDelegate) {
    return oldDelegate.durationMs != durationMs ||
        oldDelegate.lineColor != lineColor ||
        oldDelegate.pinColor != pinColor ||
        oldDelegate.visibleStartMs != visibleStartMs ||
        oldDelegate.visibleEndMs != visibleEndMs ||
        oldDelegate.visibleWidth != visibleWidth ||
        oldDelegate.markerStrokeWidth != markerStrokeWidth ||
        oldDelegate.pinUp != pinUp ||
        oldDelegate.pinDown != pinDown ||
        oldDelegate.maxVisiblePins != maxVisiblePins ||
        oldDelegate.minMajorTickSpacing != minMajorTickSpacing;
  }
}
