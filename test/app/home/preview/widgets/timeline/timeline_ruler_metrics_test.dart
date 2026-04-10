import 'package:clingfy/app/home/preview/widgets/timeline/timeline_ruler_metrics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sparse marker ticks align to visible major ruler intervals', () {
    final visibleStartMs = 10000;
    final visibleEndMs = 40000;
    final visibleWidth = 760.0;
    final majorStepMs = TimelineRulerMetrics.pickMajorStepMs(
      visibleDurationMs: visibleEndMs - visibleStartMs,
      visibleWidth: visibleWidth,
    );

    final ticks = TimelineRulerMetrics.buildSparseMarkerTicks(
      durationMs: 60000,
      visibleStartMs: visibleStartMs,
      visibleEndMs: visibleEndMs,
      visibleWidth: visibleWidth,
    );

    expect(ticks, isNotEmpty);
    expect(ticks.every((tick) => tick % majorStepMs == 0), isTrue);
  });

  test('sparse marker ticks cap visible pin density', () {
    final ticks = TimelineRulerMetrics.buildSparseMarkerTicks(
      durationMs: 60000,
      visibleStartMs: 0,
      visibleEndMs: 60000,
      visibleWidth: 2000,
    );

    final visibleTicks = ticks.where((tick) => tick >= 0 && tick <= 60000);
    expect(visibleTicks.length, lessThanOrEqualTo(8));
  });
}
