import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/preview/player_controller.dart';
import 'package:clingfy/core/zoom/fitted_content_rect.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// Draggable fixed-target marker drawn on top of the preview surface.
/// Visible only when:
///   - native build supports `fixedTargetPreview`,
///   - exactly one zoom segment is selected,
///   - the selected segment's focus mode is `fixedTarget`,
///   - the source recording dimensions are known,
///   - the player has emitted a duration (preview ready).
///
/// Dragging the marker mutates the selected segment's `fixedTarget`
/// live and pushes the change through the existing
/// `previewSetZoomSegments` flow, so the preview re-renders with the
/// new center on the next tick.
class ZoomTargetOverlay extends StatefulWidget {
  const ZoomTargetOverlay({super.key});

  static const Key overlayKey = Key('zoom_target_overlay');
  static const Key handleKey = Key('zoom_target_handle');

  @override
  State<ZoomTargetOverlay> createState() => _ZoomTargetOverlayState();
}

class _ZoomTargetOverlayState extends State<ZoomTargetOverlay> {
  static const double _markerSize = 32.0;

  final GlobalKey _stackKey = GlobalKey();
  bool _hovering = false;

  ({double dx, double dy})? _normalizedFromGlobal(
    Offset global,
    Rect contentRect,
  ) {
    final stackBox = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (stackBox == null) return null;
    final local = stackBox.globalToLocal(global);
    return viewportPointToNormalized(local, contentRect);
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerController>();
    final editor = player.zoomEditor;
    if (editor == null) return const SizedBox.shrink();
    if (!player.isReady) return const SizedBox.shrink();

    return AnimatedBuilder(
      animation: editor,
      builder: (context, _) {
        if (!editor.capabilities.fixedTargetPreview) {
          return const SizedBox.shrink();
        }
        if (!editor.canSingleEdit) return const SizedBox.shrink();
        final selected = editor.primarySelectedSegment;
        if (selected == null) return const SizedBox.shrink();
        if (selected.focusMode != ZoomFocusMode.fixedTarget) {
          return const SizedBox.shrink();
        }
        final source = editor.sourceSize;
        if (source == null) return const SizedBox.shrink();

        final target = selected.fixedTarget ?? NormalizedPoint.center;

        return LayoutBuilder(
          builder: (context, constraints) {
            final viewport = Size(constraints.maxWidth, constraints.maxHeight);
            final content = fittedContentRect(source, viewport);
            if (content.width <= 0 || content.height <= 0) {
              return const SizedBox.shrink();
            }
            final pos = fittedPointToViewport(target.dx, target.dy, content);
            final l10n = AppLocalizations.of(context)!;
            return Stack(
              key: _stackKey,
              children: [
                Positioned(
                  left: pos.dx - _markerSize / 2,
                  top: pos.dy - _markerSize / 2,
                  width: _markerSize,
                  height: _markerSize,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.move,
                    onEnter: (_) => setState(() => _hovering = true),
                    onExit: (_) => setState(() => _hovering = false),
                    child: Tooltip(
                      message: l10n.dragZoomTargetTooltip,
                      child: GestureDetector(
                        key: ZoomTargetOverlay.handleKey,
                        behavior: HitTestBehavior.opaque,
                        onPanStart: (_) =>
                            editor.beginFixedTargetDrag(selected),
                        onPanUpdate: (details) {
                          final p = _normalizedFromGlobal(
                            details.globalPosition,
                            content,
                          );
                          if (p == null) return;
                          editor.updateFixedTargetDrag(
                            NormalizedPoint(p.dx, p.dy),
                          );
                        },
                        onPanEnd: (_) => editor.commitFixedTargetDrag(),
                        onPanCancel: editor.cancelFixedTargetDrag,
                        child: Semantics(
                          label: l10n.zoomTarget,
                          child: CustomPaint(
                            size: const Size.square(_markerSize),
                            painter: _ZoomTargetPainter(hovering: _hovering),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _ZoomTargetPainter extends CustomPainter {
  const _ZoomTargetPainter({required this.hovering});

  final bool hovering;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final outerRadius = (size.shortestSide / 2) - 2;
    final innerRadius = outerRadius * 0.45;

    // Soft dark halo so the marker reads on bright video.
    canvas.drawCircle(
      center,
      outerRadius + 2,
      Paint()
        ..color = const Color(0x66000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );

    final ringStroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = hovering ? 3.0 : 2.5
      ..color = Colors.white;
    canvas.drawCircle(center, outerRadius, ringStroke);

    final ringDarkStroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = const Color(0xCC000000);
    canvas.drawCircle(center, outerRadius + 0.5, ringDarkStroke);
    canvas.drawCircle(center, outerRadius - 1.5, ringDarkStroke);

    // Crosshair lines.
    final cross = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = Colors.white;
    canvas.drawLine(
      Offset(center.dx - outerRadius, center.dy),
      Offset(center.dx - innerRadius, center.dy),
      cross,
    );
    canvas.drawLine(
      Offset(center.dx + innerRadius, center.dy),
      Offset(center.dx + outerRadius, center.dy),
      cross,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - outerRadius),
      Offset(center.dx, center.dy - innerRadius),
      cross,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy + innerRadius),
      Offset(center.dx, center.dy + outerRadius),
      cross,
    );

    // Center dot.
    canvas.drawCircle(
      center,
      hovering ? 3.5 : 2.5,
      Paint()..color = Colors.white,
    );
    canvas.drawCircle(
      center,
      hovering ? 4.5 : 3.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..color = const Color(0xCC000000),
    );
  }

  @override
  bool shouldRepaint(covariant _ZoomTargetPainter old) =>
      old.hovering != hovering;
}
