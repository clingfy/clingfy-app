import 'dart:math' as math;

class TimelineRulerMetrics {
  const TimelineRulerMetrics._();

  static int pickMajorStepMs({
    required int visibleDurationMs,
    required double visibleWidth,
    double minMajorTickSpacingPx = 110,
  }) {
    final spacing = minMajorTickSpacingPx <= 0 ? 110.0 : minMajorTickSpacingPx;
    final majorTickCount = math.max(1, (visibleWidth / spacing).floor());
    final rawStepMs = visibleDurationMs / majorTickCount;
    const intervals = <int>[
      250,
      500,
      1000,
      2000,
      5000,
      10000,
      15000,
      30000,
      60000,
      120000,
      300000,
      600000,
      900000,
      1800000,
      3600000,
    ];
    for (final interval in intervals) {
      if (interval >= rawStepMs) {
        return interval;
      }
    }
    return ((rawStepMs / 1000).ceil() * 1000);
  }

  static int pickMinorStepMs(int majorStepMs) {
    return math.max(1, (majorStepMs / 5).round());
  }

  static List<int> buildSparseMarkerTicks({
    required int durationMs,
    required int visibleStartMs,
    required int visibleEndMs,
    required double visibleWidth,
    int maxVisiblePins = 8,
    double minMajorTickSpacingPx = 110,
  }) {
    if (durationMs <= 0 || visibleWidth <= 0 || maxVisiblePins <= 0) {
      return const <int>[];
    }

    final clampedVisibleStart = visibleStartMs.clamp(0, durationMs);
    final clampedVisibleEnd = visibleEndMs.clamp(
      clampedVisibleStart,
      durationMs,
    );
    final visibleDuration = math.max(
      1,
      clampedVisibleEnd - clampedVisibleStart,
    );
    final majorStepMs = pickMajorStepMs(
      visibleDurationMs: visibleDuration,
      visibleWidth: visibleWidth,
      minMajorTickSpacingPx: minMajorTickSpacingPx,
    );
    final firstVisibleTick =
        ((clampedVisibleStart + majorStepMs - 1) ~/ majorStepMs) * majorStepMs;
    final lastVisibleTick = (clampedVisibleEnd ~/ majorStepMs) * majorStepMs;
    final visibleTickCount = firstVisibleTick > lastVisibleTick
        ? 0
        : (((lastVisibleTick - firstVisibleTick) ~/ majorStepMs) + 1);
    final stride = visibleTickCount <= maxVisiblePins
        ? 1
        : (visibleTickCount / maxVisiblePins).ceil();
    final stepMs = majorStepMs * stride;

    final ticks = <int>[];
    for (var ms = 0; ms <= durationMs; ms += stepMs) {
      ticks.add(ms);
    }
    return ticks;
  }
}
