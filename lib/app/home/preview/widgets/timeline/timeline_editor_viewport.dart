import 'dart:math' as math;

import 'package:clingfy/app/home/preview/widgets/timeline/markers_timeline_lane.dart';
import 'package:clingfy/app/home/preview/widgets/timeline/timeline_ruler_metrics.dart';
import 'package:clingfy/app/home/preview/widgets/timeline/timeline_viewport_controller.dart';
import 'package:clingfy/app/home/preview/widgets/timeline/zoom_timeline_lane.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/zoom/zoom_editor_controller.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/responsive_shell_scope.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';

class TimelineEditorViewport extends StatefulWidget {
  const TimelineEditorViewport({
    super.key,
    required this.durationMs,
    required this.positionMs,
    required this.viewportController,
    required this.segments,
    required this.editorController,
    required this.showZoomLane,
    required this.showMarkersLane,
    required this.panModeEnabled,
    required this.onSeek,
    required this.onHoverSeek,
    required this.onHoverEnd,
    required this.onHoverChanged,
    required this.hoverPositionMs,
    required this.onFocusRequested,
  });

  final int durationMs;
  final int positionMs;
  final TimelineViewportController viewportController;
  final List<ZoomSegment> segments;
  final ZoomEditorController? editorController;
  final bool showZoomLane;
  final bool showMarkersLane;
  final bool panModeEnabled;
  final ValueChanged<int> onSeek;
  final ValueChanged<int>? onHoverSeek;
  final VoidCallback? onHoverEnd;
  final ValueChanged<int?> onHoverChanged;
  final int? hoverPositionMs;
  final VoidCallback onFocusRequested;

  @override
  State<TimelineEditorViewport> createState() => _TimelineEditorViewportState();
}

class _TimelineEditorViewportState extends State<TimelineEditorViewport> {
  late final ScrollController _scrollController;
  bool _applyingViewportOffset = false;
  bool _isPanDragging = false;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _scrollController.addListener(_handleScroll);
    widget.viewportController.addListener(_handleViewportChanged);
  }

  @override
  void didUpdateWidget(covariant TimelineEditorViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.viewportController, widget.viewportController)) {
      oldWidget.viewportController.removeListener(_handleViewportChanged);
      widget.viewportController.addListener(_handleViewportChanged);
    }
    if (!widget.panModeEnabled) {
      _isPanDragging = false;
    }
  }

  @override
  void dispose() {
    widget.viewportController.removeListener(_handleViewportChanged);
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (_applyingViewportOffset || !_scrollController.hasClients) return;
    widget.viewportController.setScrollOffset(_scrollController.offset);
  }

  void _handleViewportChanged() {
    if (!_scrollController.hasClients) return;
    final target = widget.viewportController.scrollOffset.clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    if ((_scrollController.offset - target).abs() < 0.5) return;
    _applyingViewportOffset = true;
    _scrollController.jumpTo(target);
    _applyingViewportOffset = false;
  }

  void _setPanDragging(bool value) {
    if (_isPanDragging == value) return;
    setState(() => _isPanDragging = value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spacing = theme.appSpacing;
    final chrome = theme.appEditorChrome;
    final tokens = theme.appTokens;
    final metrics = context.shellMetricsOrNull;

    final visibleLaneCount =
        (widget.showZoomLane ? 1 : 0) + (widget.showMarkersLane ? 1 : 0);
    final laneGap = metrics?.timelineLaneGap ?? (spacing.xs + 2);
    final rulerHeight =
        metrics?.timelineRulerHeight ?? chrome.timelineRulerHeight;
    final laneHeight =
        metrics?.timelineLaneHeight ?? chrome.timelineLaneHeight;
    final viewportHeight = rulerHeight +
        (visibleLaneCount * laneHeight) +
        (visibleLaneCount > 0 ? (visibleLaneCount - 1) * laneGap : 0);

    return Container(
      key: const Key('timeline_editor_viewport'),
      padding: EdgeInsets.zero,
      decoration: BoxDecoration(
        color: tokens.timelineViewportSurface,
        borderRadius: BorderRadius.circular(chrome.controlRadius),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.12)),
      ),
      child: SizedBox(
        height: viewportHeight,
        child: Stack(
          children: [
            Row(
              children: [
                TimelineTrackHeaderColumn(
                  showZoomLane: widget.showZoomLane,
                  showMarkersLane: widget.showMarkersLane,
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final geometryChanged = widget.viewportController
                          .configure(
                            durationMs: widget.durationMs,
                            viewportWidth: constraints.maxWidth,
                          );
                      final contentWidth =
                          widget.viewportController.contentWidth;

                      if (geometryChanged) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (!mounted || !_scrollController.hasClients) return;
                          _handleViewportChanged();
                        });
                      }

                      return Scrollbar(
                        controller: _scrollController,
                        thumbVisibility: contentWidth > constraints.maxWidth,
                        child: SingleChildScrollView(
                          controller: _scrollController,
                          scrollDirection: Axis.horizontal,
                          child: RepaintBoundary(
                            child: TimelineScrollableCanvas(
                              width: contentWidth,
                              durationMs: widget.durationMs,
                              positionMs: widget.positionMs,
                              viewportController: widget.viewportController,
                              showZoomLane: widget.showZoomLane,
                              showMarkersLane: widget.showMarkersLane,
                              segments: widget.segments,
                              editorController: widget.editorController,
                              hoverPositionMs: widget.hoverPositionMs,
                              onSeek: widget.onSeek,
                              onHoverSeek: widget.onHoverSeek,
                              onHoverEnd: widget.onHoverEnd,
                              onHoverChanged: widget.onHoverChanged,
                              onFocusRequested: widget.onFocusRequested,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
            if (widget.panModeEnabled)
              Positioned.fill(
                child: MouseRegion(
                  key: const Key('timeline_pan_overlay'),
                  cursor: _isPanDragging
                      ? SystemMouseCursors.grabbing
                      : SystemMouseCursors.grab,
                  opaque: true,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (_) {
                      _setPanDragging(true);
                      widget.onHoverChanged(null);
                      widget.onHoverEnd?.call();
                    },
                    onPanUpdate: (details) {
                      widget.viewportController.panByPixels(-details.delta.dx);
                      widget.onHoverChanged(null);
                    },
                    onPanEnd: (_) => _setPanDragging(false),
                    onPanCancel: () => _setPanDragging(false),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class TimelineTrackHeaderColumn extends StatelessWidget {
  const TimelineTrackHeaderColumn({
    super.key,
    required this.showZoomLane,
    required this.showMarkersLane,
  });

  final bool showZoomLane;
  final bool showMarkersLane;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final spacing = theme.appSpacing;
    final chrome = theme.appEditorChrome;
    final tokens = theme.appTokens;
    final metrics = context.shellMetricsOrNull;
    final headerWidth =
        metrics?.timelineTrackHeaderWidth ?? chrome.timelineTrackHeaderWidth;
    final headerPadX =
        metrics?.timelineTrackHeaderPaddingX ?? spacing.xs;
    final rulerHeight =
        metrics?.timelineRulerHeight ?? chrome.timelineRulerHeight;
    final laneGap = metrics?.timelineLaneGap ?? (spacing.xs + 2);

    return Container(
      key: const Key('timeline_track_header_column'),
      width: headerWidth,
      padding: EdgeInsets.symmetric(horizontal: headerPadX),
      decoration: BoxDecoration(
        color: tokens.timelineTrackHeaderSurface,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(chrome.controlRadius),
          bottomLeft: Radius.circular(chrome.controlRadius),
        ),
      ),
      child: Column(
        children: [
          SizedBox(height: rulerHeight),
          if (showZoomLane) ...[
            _TimelineLaneHeaderCell(
              key: const Key('timeline_lane_header_zoom'),
              icon: Icons.zoom_in_rounded,
              label: l10n.zoom,
              hideLabel: headerWidth <= 64,
            ),
            if (showMarkersLane) SizedBox(height: laneGap),
          ],
          if (showMarkersLane)
            _TimelineLaneHeaderCell(
              key: const Key('timeline_lane_header_markers'),
              icon: Icons.outlined_flag_rounded,
              label: l10n.markers,
              hideLabel: headerWidth <= 64,
            ),
        ],
      ),
    );
  }
}

class TimelineScrollableCanvas extends StatelessWidget {
  const TimelineScrollableCanvas({
    super.key,
    required this.width,
    required this.durationMs,
    required this.positionMs,
    required this.viewportController,
    required this.showZoomLane,
    required this.showMarkersLane,
    required this.segments,
    required this.editorController,
    required this.hoverPositionMs,
    required this.onSeek,
    required this.onHoverSeek,
    required this.onHoverEnd,
    required this.onHoverChanged,
    required this.onFocusRequested,
  });

  final double width;
  final int durationMs;
  final int positionMs;
  final TimelineViewportController viewportController;
  final bool showZoomLane;
  final bool showMarkersLane;
  final List<ZoomSegment> segments;
  final ZoomEditorController? editorController;
  final int? hoverPositionMs;
  final ValueChanged<int> onSeek;
  final ValueChanged<int>? onHoverSeek;
  final VoidCallback? onHoverEnd;
  final ValueChanged<int?> onHoverChanged;
  final VoidCallback onFocusRequested;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spacing = theme.appSpacing;
    final chrome = theme.appEditorChrome;
    final metrics = context.shellMetricsOrNull;
    final laneGap = metrics?.timelineLaneGap ?? (spacing.xs + 2);
    final rulerHeight =
        metrics?.timelineRulerHeight ?? chrome.timelineRulerHeight;
    final laneHeight =
        metrics?.timelineLaneHeight ?? chrome.timelineLaneHeight;
    final laneCount = (showZoomLane ? 1 : 0) + (showMarkersLane ? 1 : 0);
    final totalHeight = rulerHeight +
        (laneCount * laneHeight) +
        (laneCount > 0 ? (laneCount - 1) * laneGap : 0);

    return SizedBox(
      width: width,
      height: totalHeight,
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TimelineRulerStrip(
                durationMs: durationMs,
                viewportController: viewportController,
                onSeek: onSeek,
                onHoverSeek: onHoverSeek,
                onHoverEnd: onHoverEnd,
                onHoverChanged: onHoverChanged,
              ),
              if (showZoomLane) ...[
                ZoomTimelineLane(
                  segments: editorController?.displaySegments ?? segments,
                  durationMs: durationMs,
                  positionMs: positionMs,
                  editorController: editorController,
                  onQuickSeek: onSeek,
                  onFocusRequested: onFocusRequested,
                ),
                if (showMarkersLane) SizedBox(height: laneGap),
              ],
              if (showMarkersLane)
                MarkersTimelineLane(
                  durationMs: durationMs,
                  visibleStartMs: viewportController.visibleStartMs,
                  visibleEndMs: viewportController.visibleEndMs,
                  visibleWidth: viewportController.viewportWidth,
                ),
            ],
          ),
          IgnorePointer(
            child: TimelinePlayheadOverlay(
              durationMs: durationMs,
              positionMs: positionMs,
              hoverPositionMs: hoverPositionMs,
              viewportController: viewportController,
            ),
          ),
        ],
      ),
    );
  }
}

class TimelineRulerStrip extends StatelessWidget {
  const TimelineRulerStrip({
    super.key,
    required this.durationMs,
    required this.viewportController,
    required this.onSeek,
    required this.onHoverSeek,
    required this.onHoverEnd,
    required this.onHoverChanged,
  });

  final int durationMs;
  final TimelineViewportController viewportController;
  final ValueChanged<int> onSeek;
  final ValueChanged<int>? onHoverSeek;
  final VoidCallback? onHoverEnd;
  final ValueChanged<int?> onHoverChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chrome = theme.appEditorChrome;
    final metrics = context.shellMetricsOrNull;
    final tickColor = theme.colorScheme.onSurface.withValues(alpha: 0.24);
    final textColor = theme.colorScheme.onSurface.withValues(alpha: 0.62);
    final height = metrics?.timelineRulerHeight ?? chrome.timelineRulerHeight;

    int msForLocalX(double dx) => viewportController.canvasXToMs(dx);

    return MouseRegion(
      onHover: (event) {
        final ms = msForLocalX(event.localPosition.dx);
        onHoverChanged(ms);
        onHoverSeek?.call(ms);
      },
      onExit: (_) {
        onHoverChanged(null);
        onHoverEnd?.call();
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (details) => onSeek(msForLocalX(details.localPosition.dx)),
        onHorizontalDragUpdate: (details) {
          onHoverChanged(null);
          onSeek(msForLocalX(details.localPosition.dx));
        },
        onHorizontalDragEnd: (_) => onHoverEnd?.call(),
        child: SizedBox(
          key: const Key('timeline_ruler_strip'),
          height: height,
          child: CustomPaint(
            painter: TimelineRulerPainter(
              durationMs: durationMs,
              contentWidth: viewportController.contentWidth,
              visibleDurationMs: viewportController.visibleEndMs -
                  viewportController.visibleStartMs,
              tickColor: tickColor,
              textColor: textColor,
              labelFontSize: metrics?.timelineRulerLabelFontSize ?? 11,
              majorTickHeight: metrics?.timelineRulerMajorTickHeight ?? 15,
              minorTickHeight: metrics?.timelineRulerMinorTickHeight ?? 8,
              majorStrokeWidth:
                  metrics?.timelineRulerMajorStrokeWidth ?? 1.2,
              minorStrokeWidth:
                  metrics?.timelineRulerMinorStrokeWidth ?? 1.0,
              labelTop: metrics?.timelineRulerLabelTop ?? 6,
              minMajorTickSpacing:
                  metrics?.timelineRulerMinMajorTickSpacing ?? 110,
            ),
          ),
        ),
      ),
    );
  }
}

class TimelinePlayheadOverlay extends StatelessWidget {
  const TimelinePlayheadOverlay({
    super.key,
    required this.durationMs,
    required this.positionMs,
    required this.hoverPositionMs,
    required this.viewportController,
  });

  final int durationMs;
  final int positionMs;
  final int? hoverPositionMs;
  final TimelineViewportController viewportController;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final metrics = context.shellMetricsOrNull;
    final accentColor = theme.colorScheme.primary;
    final playheadX = viewportController.msToCanvasX(positionMs);
    final hoverX = hoverPositionMs == null
        ? null
        : viewportController.msToCanvasX(hoverPositionMs!);

    final hoverWidth = metrics?.timelinePlayheadHoverWidth ?? 1.5;
    final lineWidth = metrics?.timelinePlayheadLineWidth ?? 2;
    final capWidth = metrics?.timelinePlayheadCapWidth ?? 8;
    final capHeight = metrics?.timelinePlayheadCapHeight ?? 6;
    final capRadius = metrics?.timelinePlayheadCapRadius ?? 3;
    final capTop = metrics?.timelinePlayheadCapTop ?? 1;
    final shadowBlur = metrics?.timelinePlayheadShadowBlur ?? 5;

    return Stack(
      children: [
        if (hoverX != null)
          Positioned(
            left: hoverX - hoverWidth / 2,
            top: 0,
            bottom: 0,
            child: Container(
              width: hoverWidth,
              color: accentColor.withValues(alpha: 0.28),
            ),
          ),
        Positioned(
          left: playheadX - lineWidth / 2,
          top: 0,
          bottom: 0,
          child: Container(
            key: const Key('timeline_playhead_line'),
            width: lineWidth,
            decoration: BoxDecoration(
              color: accentColor,
              borderRadius: BorderRadius.circular(lineWidth / 2),
              boxShadow: [
                BoxShadow(
                  color: accentColor.withValues(alpha: 0.2),
                  blurRadius: shadowBlur,
                ),
              ],
            ),
          ),
        ),
        Positioned(
          left: playheadX - capWidth / 2,
          top: capTop,
          child: Container(
            key: const Key('timeline_playhead_cap'),
            width: capWidth,
            height: capHeight,
            decoration: BoxDecoration(
              color: accentColor,
              borderRadius: BorderRadius.circular(capRadius),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
                  blurRadius: 2,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class TimelineRulerPainter extends CustomPainter {
  const TimelineRulerPainter({
    required this.durationMs,
    required this.contentWidth,
    required this.visibleDurationMs,
    required this.tickColor,
    required this.textColor,
    this.labelFontSize = 11,
    this.majorTickHeight = 15,
    this.minorTickHeight = 8,
    this.majorStrokeWidth = 1.2,
    this.minorStrokeWidth = 1.0,
    this.labelTop = 6,
    this.minMajorTickSpacing = 110,
  });

  final int durationMs;
  final double contentWidth;
  final int visibleDurationMs;
  final Color tickColor;
  final Color textColor;
  final double labelFontSize;
  final double majorTickHeight;
  final double minorTickHeight;
  final double majorStrokeWidth;
  final double minorStrokeWidth;
  final double labelTop;
  final double minMajorTickSpacing;

  @override
  void paint(Canvas canvas, Size size) {
    if (durationMs <= 0 || contentWidth <= 0) return;

    final majorStepMs = TimelineRulerMetrics.pickMajorStepMs(
      visibleDurationMs:
          visibleDurationMs <= 0 ? durationMs : visibleDurationMs,
      visibleWidth: size.width,
      minMajorTickSpacingPx: minMajorTickSpacing,
    );
    final minorStepMs = TimelineRulerMetrics.pickMinorStepMs(majorStepMs);

    final minorPaint = Paint()
      ..color = tickColor.withValues(alpha: 0.55)
      ..strokeWidth = minorStrokeWidth;
    final majorPaint = Paint()
      ..color = tickColor
      ..strokeWidth = majorStrokeWidth;
    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    );

    for (var ms = 0; ms <= durationMs; ms += minorStepMs) {
      final x = (ms / durationMs) * contentWidth;
      final isMajor = ms % majorStepMs == 0;
      final tickHeight = isMajor ? majorTickHeight : minorTickHeight;

      canvas.drawLine(
        Offset(x, size.height - tickHeight),
        Offset(x, size.height),
        isMajor ? majorPaint : minorPaint,
      );

      if (!isMajor) continue;

      final label = _formatTime(ms);
      textPainter.text = TextSpan(
        text: label,
        style: TextStyle(
          color: textColor,
          fontSize: labelFontSize,
          fontWeight: FontWeight.w600,
        ),
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(
          (x - (textPainter.width / 2)).clamp(
            0.0,
            math.max(0.0, contentWidth - textPainter.width),
          ),
          labelTop,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant TimelineRulerPainter oldDelegate) {
    return oldDelegate.durationMs != durationMs ||
        oldDelegate.contentWidth != contentWidth ||
        oldDelegate.visibleDurationMs != visibleDurationMs ||
        oldDelegate.tickColor != tickColor ||
        oldDelegate.textColor != textColor ||
        oldDelegate.labelFontSize != labelFontSize ||
        oldDelegate.majorTickHeight != majorTickHeight ||
        oldDelegate.minorTickHeight != minorTickHeight ||
        oldDelegate.majorStrokeWidth != majorStrokeWidth ||
        oldDelegate.minorStrokeWidth != minorStrokeWidth ||
        oldDelegate.labelTop != labelTop ||
        oldDelegate.minMajorTickSpacing != minMajorTickSpacing;
  }

  String _formatTime(int ms) {
    final duration = Duration(milliseconds: ms);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:$minutes:$seconds';
    }
    return '${duration.inMinutes}:$seconds';
  }
}

class _TimelineLaneHeaderCell extends StatelessWidget {
  const _TimelineLaneHeaderCell({
    super.key,
    required this.icon,
    required this.label,
    this.hideLabel = false,
  });

  final IconData icon;
  final String label;
  final bool hideLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spacing = theme.appSpacing;
    final chrome = theme.appEditorChrome;
    final typography = theme.appTypography;
    final tokens = theme.appTokens;
    final metrics = context.shellMetricsOrNull;
    final height =
        metrics?.timelineLaneHeight ?? chrome.timelineLaneHeight;
    final padX = metrics?.timelineTrackHeaderPaddingX ?? spacing.sm;
    final iconSize = metrics?.timelineLaneHeaderIconSize ?? 16;
    final iconTextGap = metrics?.timelineLaneHeaderIconTextGap ?? spacing.xs;
    final textScale = metrics?.timelineLaneHeaderTextScale ?? 1.0;

    final baseStyle = typography.value.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.82),
      fontSize: (typography.value.fontSize ?? 12) * textScale,
    );

    return Tooltip(
      message: label,
      child: Container(
        height: height,
        padding: EdgeInsets.symmetric(horizontal: padX),
        decoration: BoxDecoration(
          color: tokens.timelineLaneSurface,
          borderRadius: BorderRadius.circular(chrome.controlRadius),
          border:
              Border.all(color: theme.dividerColor.withValues(alpha: 0.12)),
        ),
        child: Row(
          mainAxisAlignment:
              hideLabel ? MainAxisAlignment.center : MainAxisAlignment.start,
          children: [
            Icon(
              icon,
              size: iconSize,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.82),
              semanticLabel: label,
            ),
            if (!hideLabel) ...[
              SizedBox(width: iconTextGap),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: baseStyle,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
