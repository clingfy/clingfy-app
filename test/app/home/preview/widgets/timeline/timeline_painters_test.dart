import 'package:clingfy/app/home/preview/widgets/timeline/markers_timeline_lane.dart';
import 'package:clingfy/app/home/preview/widgets/timeline/timeline_editor_viewport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TimelineRulerPainter.shouldRepaint', () {
    TimelineRulerPainter make({
      double labelFontSize = 11,
      double majorTickHeight = 15,
      double minorTickHeight = 8,
      double labelTop = 6,
      double minMajorTickSpacing = 110,
    }) {
      return TimelineRulerPainter(
        durationMs: 60000,
        contentWidth: 800,
        visibleDurationMs: 60000,
        tickColor: const Color(0xFF000000),
        textColor: const Color(0xFF111111),
        labelFontSize: labelFontSize,
        majorTickHeight: majorTickHeight,
        minorTickHeight: minorTickHeight,
        labelTop: labelTop,
        minMajorTickSpacing: minMajorTickSpacing,
      );
    }

    test('returns false when nothing changed', () {
      expect(make().shouldRepaint(make()), isFalse);
    });
    test('detects labelFontSize change', () {
      expect(make(labelFontSize: 11).shouldRepaint(make(labelFontSize: 10)),
          isTrue);
    });
    test('detects majorTickHeight change', () {
      expect(make(majorTickHeight: 15).shouldRepaint(make(majorTickHeight: 12)),
          isTrue);
    });
    test('detects minorTickHeight change', () {
      expect(make(minorTickHeight: 8).shouldRepaint(make(minorTickHeight: 6)),
          isTrue);
    });
    test('detects labelTop change', () {
      expect(make(labelTop: 6).shouldRepaint(make(labelTop: 4)), isTrue);
    });
    test('detects minMajorTickSpacing change', () {
      expect(
          make(minMajorTickSpacing: 110)
              .shouldRepaint(make(minMajorTickSpacing: 80)),
          isTrue);
    });
  });

  group('MarkersTimelineLanePainter.shouldRepaint', () {
    MarkersTimelineLanePainter make({
      double pinUp = 8,
      double pinDown = 5,
      double markerStrokeWidth = 1.25,
      int maxVisiblePins = 8,
    }) {
      return MarkersTimelineLanePainter(
        durationMs: 60000,
        lineColor: const Color(0xFF222222),
        pinColor: const Color(0xFF333333),
        visibleStartMs: 0,
        visibleEndMs: 60000,
        visibleWidth: 800,
        markerStrokeWidth: markerStrokeWidth,
        pinUp: pinUp,
        pinDown: pinDown,
        maxVisiblePins: maxVisiblePins,
      );
    }

    test('returns false when nothing changed', () {
      expect(make().shouldRepaint(make()), isFalse);
    });
    test('detects pinUp change', () {
      expect(make(pinUp: 8).shouldRepaint(make(pinUp: 5)), isTrue);
    });
    test('detects pinDown change', () {
      expect(make(pinDown: 5).shouldRepaint(make(pinDown: 3)), isTrue);
    });
    test('detects markerStrokeWidth change', () {
      expect(
          make(markerStrokeWidth: 1.25)
              .shouldRepaint(make(markerStrokeWidth: 1.0)),
          isTrue);
    });
    test('detects maxVisiblePins change', () {
      expect(make(maxVisiblePins: 8).shouldRepaint(make(maxVisiblePins: 6)),
          isTrue);
    });
  });
}
