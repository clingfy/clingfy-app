import 'dart:ui';

/// Returns the rectangle inside [viewport] that the source content
/// actually occupies after [BoxFit.contain] (aspect-preserving, fits
/// inside, may letterbox / pillarbox). The returned [Rect] is in
/// viewport-local coordinates with origin at `(0, 0)` and width
/// [viewport.width].
///
/// Used by overlays drawn over the preview surface (e.g. the fixed-
/// target zoom marker) so they can map normalized source coordinates
/// onto the actual displayed video pixels — never onto the black
/// letterbox bars.
///
/// Returns [Rect.zero] when the source size or viewport size is
/// degenerate so callers can early-return.
Rect fittedContentRect(Size source, Size viewport) {
  if (source.width <= 0 ||
      source.height <= 0 ||
      viewport.width <= 0 ||
      viewport.height <= 0) {
    return Rect.zero;
  }
  final sourceAspect = source.width / source.height;
  final viewportAspect = viewport.width / viewport.height;

  double width;
  double height;
  if (sourceAspect > viewportAspect) {
    // Source is wider than viewport → letterboxed top/bottom.
    width = viewport.width;
    height = viewport.width / sourceAspect;
  } else {
    // Source is taller (or equal) → pillarboxed left/right.
    height = viewport.height;
    width = viewport.height * sourceAspect;
  }
  final left = (viewport.width - width) / 2.0;
  final top = (viewport.height - height) / 2.0;
  return Rect.fromLTWH(left, top, width, height);
}

/// Maps a normalized point (`dx`,`dy` in `[0, 1]`) inside the source
/// recording onto an [Offset] in viewport-local coordinates.
Offset fittedPointToViewport(double dx, double dy, Rect contentRect) {
  return Offset(
    contentRect.left + dx * contentRect.width,
    contentRect.top + dy * contentRect.height,
  );
}

/// Inverse of [fittedPointToViewport]. Returns a normalized
/// `(dx, dy)` clamped to `[0, 1]` so dragging outside the displayed
/// content rect still produces a valid fixed target.
({double dx, double dy}) viewportPointToNormalized(
  Offset local,
  Rect contentRect,
) {
  if (contentRect.width <= 0 || contentRect.height <= 0) {
    return (dx: 0.5, dy: 0.5);
  }
  final dx = (local.dx - contentRect.left) / contentRect.width;
  final dy = (local.dy - contentRect.top) / contentRect.height;
  return (dx: dx.clamp(0.0, 1.0), dy: dy.clamp(0.0, 1.0));
}
