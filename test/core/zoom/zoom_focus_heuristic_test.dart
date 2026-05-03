import 'package:clingfy/core/zoom/cursor_samples.dart';
import 'package:clingfy/core/zoom/zoom_focus_heuristic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const width = 1920.0;
  const height = 1080.0;

  CursorSamplesResult resultWith({
    List<CursorSample> samples = const <CursorSample>[],
    CursorSample? playheadSample,
    double w = width,
    double h = height,
  }) {
    return CursorSamplesResult(
      samples: samples,
      playheadSample: playheadSample,
      width: w,
      height: h,
    );
  }

  group('chooseZoomFocusModeForRange', () {
    test('moving cursor inside range -> followCursor', () {
      final samples = resultWith(
        samples: const [
          CursorSample(tMs: 1000, x: 100, y: 100, visible: true),
          CursorSample(tMs: 1500, x: 400, y: 220, visible: true),
          CursorSample(tMs: 2000, x: 700, y: 480, visible: true),
        ],
        playheadSample:
            const CursorSample(tMs: 1500, x: 400, y: 220, visible: true),
      );

      final decision = chooseZoomFocusModeForRange(
        startMs: 1000,
        endMs: 2000,
        playheadMs: 1500,
        samples: samples,
      );

      expect(decision.mode, ZoomFocusMode.followCursor);
      expect(decision.fixedTarget, isNull);
    });

    test('no samples -> fixedTarget center', () {
      final decision = chooseZoomFocusModeForRange(
        startMs: 1000,
        endMs: 2000,
        playheadMs: 1500,
        samples: resultWith(),
      );

      expect(decision.mode, ZoomFocusMode.fixedTarget);
      expect(decision.fixedTarget, NormalizedPoint.center);
    });

    test('static cursor -> fixedTarget at playhead sample', () {
      final samples = resultWith(
        samples: const [
          CursorSample(tMs: 1000, x: 480, y: 270, visible: true),
          CursorSample(tMs: 1500, x: 482, y: 271, visible: true),
          CursorSample(tMs: 2000, x: 484, y: 272, visible: true),
        ],
        playheadSample:
            const CursorSample(tMs: 1500, x: 482, y: 271, visible: true),
      );

      final decision = chooseZoomFocusModeForRange(
        startMs: 1000,
        endMs: 2000,
        playheadMs: 1500,
        samples: samples,
      );

      expect(decision.mode, ZoomFocusMode.fixedTarget);
      expect(decision.fixedTarget, isNotNull);
      expect(decision.fixedTarget!.dx, closeTo(482 / width, 1e-9));
      expect(decision.fixedTarget!.dy, closeTo(271 / height, 1e-9));
    });

    test('all hidden samples -> fixedTarget center', () {
      final samples = resultWith(
        samples: const [
          CursorSample(tMs: 1000, x: 100, y: 100, visible: false),
          CursorSample(tMs: 1500, x: 400, y: 220, visible: false),
          CursorSample(tMs: 2000, x: 700, y: 480, visible: false),
        ],
        playheadSample:
            const CursorSample(tMs: 1500, x: 400, y: 220, visible: false),
      );

      final decision = chooseZoomFocusModeForRange(
        startMs: 1000,
        endMs: 2000,
        playheadMs: 1500,
        samples: samples,
      );

      expect(decision.mode, ZoomFocusMode.fixedTarget);
      expect(decision.fixedTarget, NormalizedPoint.center);
    });

    test('out-of-bounds samples are ignored, fall back to fixedTarget',
        () {
      final samples = resultWith(
        samples: const [
          CursorSample(tMs: 1000, x: -50, y: -10, visible: true),
          CursorSample(tMs: 1500, x: 5000, y: 5000, visible: true),
        ],
      );

      final decision = chooseZoomFocusModeForRange(
        startMs: 1000,
        endMs: 2000,
        playheadMs: 1500,
        samples: samples,
      );

      expect(decision.mode, ZoomFocusMode.fixedTarget);
      expect(decision.fixedTarget, NormalizedPoint.center);
    });

    test('fixedTarget falls back to nearest visible sample when '
        'playhead sample missing', () {
      final samples = resultWith(
        samples: const [
          CursorSample(tMs: 1100, x: 200, y: 100, visible: true),
          CursorSample(tMs: 1900, x: 205, y: 105, visible: true),
        ],
      );

      final decision = chooseZoomFocusModeForRange(
        startMs: 1000,
        endMs: 2000,
        playheadMs: 1200, // closer to first sample
        samples: samples,
      );

      expect(decision.mode, ZoomFocusMode.fixedTarget);
      expect(decision.fixedTarget!.dx, closeTo(200 / width, 1e-9));
      expect(decision.fixedTarget!.dy, closeTo(100 / height, 1e-9));
    });

    test('exact 12px movement is treated as static', () {
      // Bounding box diagonal == 12 → at threshold → fixedTarget.
      final samples = resultWith(
        samples: const [
          CursorSample(tMs: 1000, x: 100, y: 100, visible: true),
          CursorSample(tMs: 2000, x: 100 + 12, y: 100, visible: true),
        ],
      );

      final decision = chooseZoomFocusModeForRange(
        startMs: 1000,
        endMs: 2000,
        playheadMs: 1500,
        samples: samples,
      );

      expect(decision.mode, ZoomFocusMode.fixedTarget);
    });
  });
}
