import 'package:clingfy/app/home/preview/widgets/timeline/timeline_ruler_metrics.dart';
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
    final controlFill =
        theme.inputDecorationTheme.fillColor ??
        theme.colorScheme.secondaryContainer;

    return Container(
      key: const Key('markers_timeline_lane'),
      height: chrome.timelineLaneHeight,
      decoration: BoxDecoration(
        color: controlFill,
        borderRadius: BorderRadius.circular(chrome.controlRadius),
        border: Border.all(color: tokens.panelBorder),
      ),
      child: CustomPaint(
        key: const Key('markers_timeline_lane_paint'),
        painter: _MarkersTimelineLanePainter(
          durationMs: durationMs,
          lineColor: tokens.timelineTick.withValues(alpha: 0.28),
          pinColor: theme.colorScheme.primary.withValues(alpha: 0.24),
          visibleStartMs: visibleStartMs,
          visibleEndMs: visibleEndMs,
          visibleWidth: visibleWidth,
        ),
      ),
    );
  }
}

class _MarkersTimelineLanePainter extends CustomPainter {
  const _MarkersTimelineLanePainter({
    required this.durationMs,
    required this.lineColor,
    required this.pinColor,
    required this.visibleStartMs,
    required this.visibleEndMs,
    required this.visibleWidth,
  });

  final int durationMs;
  final Color lineColor;
  final Color pinColor;
  final int visibleStartMs;
  final int visibleEndMs;
  final double visibleWidth;

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
    );

    final pinPaint = Paint()
      ..color = pinColor
      ..strokeWidth = 1.25;
    for (final tickMs in ticks) {
      final x = (tickMs / durationMs) * size.width;
      canvas.drawLine(Offset(x, midY - 8), Offset(x, midY + 5), pinPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _MarkersTimelineLanePainter oldDelegate) {
    return oldDelegate.durationMs != durationMs ||
        oldDelegate.lineColor != lineColor ||
        oldDelegate.pinColor != pinColor ||
        oldDelegate.visibleStartMs != visibleStartMs ||
        oldDelegate.visibleEndMs != visibleEndMs ||
        oldDelegate.visibleWidth != visibleWidth;
  }
}
