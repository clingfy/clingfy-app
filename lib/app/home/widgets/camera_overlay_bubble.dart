import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:clingfy/core/models/app_models.dart';

/// Builds the outline [Path] for an [OverlayShape] inside [rect].
///
/// Shared by the live in-app camera preview (clip + border + shadow) so the
/// bubble reflects the recording-overlay style the same way the macOS native
/// overlay does. `roundness` is the 0.0–0.4 corner fraction used by the
/// rounded shapes; it is ignored by circle / hexagon / star.
Path cameraOverlayShapePath(OverlayShape shape, Rect rect, double roundness) {
  final double w = rect.width;
  final double h = rect.height;
  final double shortest = math.min(w, h);
  switch (shape) {
    case OverlayShape.circle:
      return Path()..addOval(rect);
    case OverlayShape.square:
      // A square silhouette centered in the box, with optional corner rounding.
      final double side = shortest;
      final Rect square = Rect.fromCenter(
        center: rect.center,
        width: side,
        height: side,
      );
      final double radius = (roundness.clamp(0.0, 0.4)) * side;
      return Path()
        ..addRRect(RRect.fromRectAndRadius(square, Radius.circular(radius)));
    case OverlayShape.roundedRect:
      final double radius = (roundness.clamp(0.0, 0.4)) * shortest;
      return Path()
        ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));
    case OverlayShape.squircle:
      // Approximated as a strongly-rounded rect (matches the Windows native
      // painter, which renders squircle as a rounded rect).
      final double radius = shortest * 0.32;
      return Path()
        ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));
    case OverlayShape.hexagon:
      return _polygonPath(rect, sides: 6, rotation: math.pi / 6);
    case OverlayShape.star:
      return _starPath(rect, points: 5, innerRatio: 0.5);
  }
}

Path _polygonPath(Rect rect, {required int sides, double rotation = 0}) {
  final Offset center = rect.center;
  final double radius = math.min(rect.width, rect.height) / 2;
  final Path path = Path();
  for (int i = 0; i < sides; i++) {
    final double angle = rotation + (2 * math.pi * i / sides) - math.pi / 2;
    final Offset p = Offset(
      center.dx + radius * math.cos(angle),
      center.dy + radius * math.sin(angle),
    );
    if (i == 0) {
      path.moveTo(p.dx, p.dy);
    } else {
      path.lineTo(p.dx, p.dy);
    }
  }
  return path..close();
}

Path _starPath(Rect rect, {required int points, required double innerRatio}) {
  final Offset center = rect.center;
  final double outer = math.min(rect.width, rect.height) / 2;
  final double inner = outer * innerRatio;
  final Path path = Path();
  final int vertices = points * 2;
  for (int i = 0; i < vertices; i++) {
    final double r = i.isEven ? outer : inner;
    final double angle = (2 * math.pi * i / vertices) - math.pi / 2;
    final Offset p = Offset(
      center.dx + r * math.cos(angle),
      center.dy + r * math.sin(angle),
    );
    if (i == 0) {
      path.moveTo(p.dx, p.dy);
    } else {
      path.lineTo(p.dx, p.dy);
    }
  }
  return path..close();
}

class _CameraOverlayClipper extends CustomClipper<Path> {
  const _CameraOverlayClipper(this.shape, this.roundness);

  final OverlayShape shape;
  final double roundness;

  @override
  Path getClip(Size size) =>
      cameraOverlayShapePath(shape, Offset.zero & size, roundness);

  @override
  bool shouldReclip(covariant _CameraOverlayClipper oldClipper) =>
      oldClipper.shape != shape || oldClipper.roundness != roundness;
}

/// Strokes the shape outline as a border on top of the clipped child.
class _CameraOverlayBorderPainter extends CustomPainter {
  const _CameraOverlayBorderPainter({
    required this.shape,
    required this.roundness,
    required this.color,
    required this.width,
  });

  final OverlayShape shape;
  final double roundness;
  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    if (width <= 0) return;
    // Inset by half the stroke so the border sits fully inside the bubble.
    final Rect rect = (Offset.zero & size).deflate(width / 2);
    final Path path = cameraOverlayShapePath(shape, rect, roundness);
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeJoin = StrokeJoin.round
      ..color = color;
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CameraOverlayBorderPainter old) =>
      old.shape != shape ||
      old.roundness != roundness ||
      old.color != color ||
      old.width != width;
}

/// Maps an [OverlayShadow] preset to a drop-shadow spec (blur sigma, dy, alpha).
({double blur, double dy, double opacity}) _shadowSpec(OverlayShadow shadow) {
  switch (shadow) {
    case OverlayShadow.none:
      return (blur: 0, dy: 0, opacity: 0);
    case OverlayShadow.light:
      return (blur: 6, dy: 2, opacity: 0.25);
    case OverlayShadow.medium:
      return (blur: 11, dy: 4, opacity: 0.35);
    case OverlayShadow.strong:
      return (blur: 18, dy: 7, opacity: 0.45);
  }
}

/// Draws a drop shadow that follows the bubble silhouette (not its bounding
/// box), painted behind the clipped camera content.
class _CameraOverlayShadowPainter extends CustomPainter {
  const _CameraOverlayShadowPainter({
    required this.shape,
    required this.roundness,
    required this.spec,
  });

  final OverlayShape shape;
  final double roundness;
  final ({double blur, double dy, double opacity}) spec;

  @override
  void paint(Canvas canvas, Size size) {
    if (spec.opacity <= 0) return;
    final Path path = cameraOverlayShapePath(
      shape,
      Offset.zero & size,
      roundness,
    ).shift(Offset(0, spec.dy));
    final Paint paint = Paint()
      ..color = Colors.black.withValues(alpha: spec.opacity)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, spec.blur);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CameraOverlayShadowPainter old) =>
      old.shape != shape || old.roundness != roundness || old.spec != spec;
}

/// Identifies the horizontal-mirror [Transform] wrapping the camera child, so
/// tests can assert the mirror independent of framework-inserted transforms.
const Key cameraOverlayMirrorKey = ValueKey('cameraOverlayMirror');

/// Composites the live-camera [child] into the styled recording-overlay bubble:
/// shape clip, optional border, drop shadow, opacity, and horizontal mirror.
///
/// Chroma key is intentionally not applied here — it is an export/inline-preview
/// effect (needs a shader); the live in-app preview shows the un-keyed camera,
/// matching that chroma is baked at composite time.
class CameraOverlayBubble extends StatelessWidget {
  const CameraOverlayBubble({
    super.key,
    required this.shape,
    required this.roundness,
    required this.opacity,
    required this.mirror,
    required this.shadow,
    required this.borderWidth,
    required this.borderColor,
    required this.hasBorder,
    required this.size,
    required this.child,
  });

  final OverlayShape shape;
  final double roundness;
  final double opacity;
  final bool mirror;
  final OverlayShadow shadow;
  final double borderWidth;
  final Color borderColor;
  final bool hasBorder;
  final Size size;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    Widget content = ClipPath(
      clipper: _CameraOverlayClipper(shape, roundness),
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: mirror
            ? Transform(
                key: cameraOverlayMirrorKey,
                alignment: Alignment.center,
                transform: Matrix4.diagonal3Values(-1.0, 1.0, 1.0),
                child: child,
              )
            : child,
      ),
    );

    if (hasBorder && borderWidth > 0) {
      content = Stack(
        fit: StackFit.passthrough,
        children: [
          content,
          Positioned.fill(
            child: CustomPaint(
              painter: _CameraOverlayBorderPainter(
                shape: shape,
                roundness: roundness,
                color: borderColor,
                width: borderWidth,
              ),
            ),
          ),
        ],
      );
    }

    if (opacity < 1.0) {
      content = Opacity(opacity: opacity.clamp(0.0, 1.0), child: content);
    }

    final spec = _shadowSpec(shadow);
    if (spec.opacity > 0) {
      content = Stack(
        fit: StackFit.passthrough,
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _CameraOverlayShadowPainter(
                shape: shape,
                roundness: roundness,
                spec: spec,
              ),
            ),
          ),
          content,
        ],
      );
    }

    return SizedBox(width: size.width, height: size.height, child: content);
  }
}
