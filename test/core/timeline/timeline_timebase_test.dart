import 'package:flutter_test/flutter_test.dart';
import 'package:clingfy/core/timeline/timeline_timebase.dart';

void main() {
  group('TimelineTimebase', () {
    const durationMs = 10000;
    const tb = TimelineTimebase(durationMs);

    // Mirrors the exact formula that lived in ZoomEditorController before the
    // extraction, so these tests double as an equivalence guard.
    int referenceSnap(int ms) {
      final snapped =
          (ms / TimelineTimebase.frameMs).round() * TimelineTimebase.frameMs;
      return snapped.round().clamp(0, durationMs);
    }

    test('frameMs is one 60fps frame', () {
      expect(TimelineTimebase.frameMs, 1000 / 60);
    });

    test('minDurationMs is two frames', () {
      expect(
        TimelineTimebase.minDurationMs,
        (TimelineTimebase.frameMs * 2).round(),
      );
      expect(TimelineTimebase.minDurationMs, 33);
    });

    test('snapToGrid matches the reference formula across the timeline', () {
      for (var ms = -50; ms <= durationMs + 50; ms += 7) {
        expect(tb.snapToGrid(ms), referenceSnap(ms), reason: 'ms=$ms');
      }
    });

    test('snapToGrid clamps to [0, durationMs]', () {
      expect(tb.snapToGrid(-1000), 0);
      expect(tb.snapToGrid(durationMs + 1000), durationMs);
      expect(tb.snapToGrid(0), 0);
    });

    test('snapToGrid aligns to the frame grid', () {
      // 9ms rounds up to one frame (~17ms); 8ms rounds down to 0.
      expect(tb.snapToGrid(9), 17);
      expect(tb.snapToGrid(8), 0);
      expect(tb.snapToGrid(50), 50);
    });

    test('normalizeEditableMs snaps when snapping is on (default)', () {
      for (var ms = -50; ms <= durationMs + 50; ms += 7) {
        expect(tb.normalizeEditableMs(ms), referenceSnap(ms), reason: 'ms=$ms');
      }
    });

    test('normalizeEditableMs only clamps when snapping is off', () {
      expect(tb.normalizeEditableMs(123, snapping: false), 123);
      expect(tb.normalizeEditableMs(-5, snapping: false), 0);
      expect(
        tb.normalizeEditableMs(durationMs + 5, snapping: false),
        durationMs,
      );
    });

    test('zero-duration timeline clamps everything to 0', () {
      const zero = TimelineTimebase(0);
      expect(zero.snapToGrid(500), 0);
      expect(zero.normalizeEditableMs(500), 0);
      expect(zero.normalizeEditableMs(500, snapping: false), 0);
    });
  });
}
