import 'dart:math' as math;

import 'package:clingfy/core/zoom/cursor_samples.dart';

/// Threshold below which cursor movement inside a segment is considered
/// static enough to fall back to a fixed target. Pixel space matches
/// [CursorSample.x]/[CursorSample.y].
const double kZoomCursorMotionThresholdPx = 12.0;

/// Result of [chooseZoomFocusModeForRange]. When [mode] is
/// [ZoomFocusMode.fixedTarget], [fixedTarget] is non-null and clamped to
/// `[0, 1]`. When [mode] is [ZoomFocusMode.followCursor], [fixedTarget]
/// is null.
class ZoomFocusDecision {
  final ZoomFocusMode mode;
  final NormalizedPoint? fixedTarget;

  const ZoomFocusDecision({required this.mode, this.fixedTarget});
}

/// Picks a zoom focus mode for a newly created segment.
///
/// Rules:
///   - No visible samples in `[startMs, endMs]` → fixedTarget.
///   - Movement distance across the segment ≤
///     [kZoomCursorMotionThresholdPx] → fixedTarget.
///   - Otherwise → followCursor.
///
/// Fixed-target selection (only when the mode resolves to fixedTarget):
///   - Use the playhead sample if it is visible and inside bounds.
///   - Else use the visible sample closest to `playheadMs`.
///   - Else use [NormalizedPoint.center].
ZoomFocusDecision chooseZoomFocusModeForRange({
  required int startMs,
  required int endMs,
  required int playheadMs,
  required CursorSamplesResult samples,
}) {
  final width = samples.width;
  final height = samples.height;
  final hasBounds = width > 0 && height > 0;

  final inRange = <CursorSample>[];
  for (final s in samples.samples) {
    if (s.tMs < startMs || s.tMs > endMs) continue;
    if (!s.visible) continue;
    if (hasBounds && !_inBounds(s, width, height)) continue;
    inRange.add(s);
  }

  if (inRange.isEmpty) {
    return ZoomFocusDecision(
      mode: ZoomFocusMode.fixedTarget,
      fixedTarget: _resolveFixedTarget(
        playheadMs: playheadMs,
        playheadSample: samples.playheadSample,
        rangeSamples: const <CursorSample>[],
        width: width,
        height: height,
      ),
    );
  }

  final motionPx = _maxPairwiseDistance(inRange);
  if (motionPx <= kZoomCursorMotionThresholdPx) {
    return ZoomFocusDecision(
      mode: ZoomFocusMode.fixedTarget,
      fixedTarget: _resolveFixedTarget(
        playheadMs: playheadMs,
        playheadSample: samples.playheadSample,
        rangeSamples: inRange,
        width: width,
        height: height,
      ),
    );
  }

  return const ZoomFocusDecision(mode: ZoomFocusMode.followCursor);
}

NormalizedPoint _resolveFixedTarget({
  required int playheadMs,
  required CursorSample? playheadSample,
  required List<CursorSample> rangeSamples,
  required double width,
  required double height,
}) {
  final hasBounds = width > 0 && height > 0;

  if (playheadSample != null &&
      playheadSample.visible &&
      (!hasBounds || _inBounds(playheadSample, width, height))) {
    return _normalize(playheadSample, width, height);
  }

  if (rangeSamples.isNotEmpty) {
    CursorSample? best;
    int bestDelta = -1;
    for (final s in rangeSamples) {
      final delta = (s.tMs - playheadMs).abs();
      if (best == null || delta < bestDelta) {
        best = s;
        bestDelta = delta;
      }
    }
    if (best != null) {
      return _normalize(best, width, height);
    }
  }

  return NormalizedPoint.center;
}

NormalizedPoint _normalize(CursorSample s, double width, double height) {
  if (width <= 0 || height <= 0) return NormalizedPoint.center;
  return NormalizedPoint(s.x / width, s.y / height).clamped();
}

bool _inBounds(CursorSample s, double width, double height) {
  return s.x >= 0 && s.x <= width && s.y >= 0 && s.y <= height;
}

double _maxPairwiseDistance(List<CursorSample> samples) {
  // Cheap O(n) bounding-box diagonal — close enough to true max
  // pairwise distance for the heuristic, and avoids O(n^2).
  if (samples.length < 2) return 0;
  var minX = samples.first.x;
  var maxX = samples.first.x;
  var minY = samples.first.y;
  var maxY = samples.first.y;
  for (final s in samples) {
    if (s.x < minX) minX = s.x;
    if (s.x > maxX) maxX = s.x;
    if (s.y < minY) minY = s.y;
    if (s.y > maxY) maxY = s.y;
  }
  final dx = maxX - minX;
  final dy = maxY - minY;
  return math.sqrt(dx * dx + dy * dy);
}
