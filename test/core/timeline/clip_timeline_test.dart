import 'package:clingfy/core/timeline/clip_timeline.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:flutter_test/flutter_test.dart';

Clip _clip(
  String id,
  int inMs,
  int outMs, {
  int timelineStartMs = 0,
  bool enabled = true,
}) => Clip(
  id: id,
  sourceInMs: inMs,
  sourceOutMs: outMs,
  timelineStartMs: timelineStartMs,
  enabled: enabled,
);

void main() {
  group('ClipTimeline.clipDurationMs', () {
    test('is out minus in', () {
      expect(ClipTimeline.clipDurationMs(_clip('a', 1000, 4000)), 3000);
    });

    test('never negative for an inverted window', () {
      expect(ClipTimeline.clipDurationMs(_clip('a', 4000, 1000)), 0);
    });
  });

  group('ClipTimeline.wholeRecording', () {
    test('covers the full recording from source 0', () {
      final clip = ClipTimeline.wholeRecording(12000);
      expect(clip.sourceInMs, 0);
      expect(clip.sourceOutMs, 12000);
      expect(clip.timelineStartMs, 0);
    });

    test('clamps a negative duration to 0', () {
      expect(ClipTimeline.wholeRecording(-5).sourceOutMs, 0);
    });
  });

  group('ClipTimeline.normalized', () {
    test('re-stacks timelineStartMs as cumulative enabled duration', () {
      final norm = ClipTimeline.normalized([
        _clip('a', 0, 3000, timelineStartMs: 999),
        _clip('b', 5000, 9000, timelineStartMs: 999),
      ]);
      expect(norm[0].timelineStartMs, 0);
      expect(norm[1].timelineStartMs, 3000); // after a's 3000ms
    });

    test('disabled clips occupy no timeline time but are retained', () {
      final norm = ClipTimeline.normalized([
        _clip('a', 0, 2000),
        _clip('b', 0, 4000, enabled: false),
        _clip('c', 0, 1000),
      ]);
      expect(norm.map((c) => c.timelineStartMs), [0, 2000, 2000]);
      expect(norm.length, 3);
    });
  });

  group('ClipTimeline.totalDurationMs', () {
    test('sums only enabled clips', () {
      final total = ClipTimeline.totalDurationMs([
        _clip('a', 0, 2000),
        _clip('b', 0, 4000, enabled: false),
        _clip('c', 0, 1000),
      ]);
      expect(total, 3000);
    });
  });

  group('ClipTimeline.sourceMsForTimelineMs', () {
    test('maps a point inside the first clip directly', () {
      final clips = [ClipTimeline.wholeRecording(10000)];
      expect(ClipTimeline.sourceMsForTimelineMs(clips, 2500), 2500);
    });

    test('maps across a ripple: second clip starts where first ends', () {
      // Two clips: [0..3000] then source [7000..9000]. Timeline 3000 begins
      // the second clip, so it maps to source 7000 (the gap is removed).
      final clips = [_clip('a', 0, 3000), _clip('b', 7000, 9000)];
      expect(ClipTimeline.sourceMsForTimelineMs(clips, 3000), 7000);
      expect(ClipTimeline.sourceMsForTimelineMs(clips, 4000), 8000);
    });

    test('parked at the exact end maps to the last clip source-out', () {
      final clips = [_clip('a', 0, 3000), _clip('b', 7000, 9000)];
      // total = 3000 + 2000 = 5000.
      expect(ClipTimeline.sourceMsForTimelineMs(clips, 5000), 9000);
    });

    test('past the end and before the start return null', () {
      final clips = [ClipTimeline.wholeRecording(10000)];
      expect(ClipTimeline.sourceMsForTimelineMs(clips, 10001), isNull);
      expect(ClipTimeline.sourceMsForTimelineMs(clips, -1), isNull);
    });

    test('reordered clips produce a non-monotonic source map', () {
      // Timeline order B then A; source order A before B.
      final clips = [
        _clip('b', 6000, 8000), // timeline [0..2000] -> source 6000..8000
        _clip('a', 0, 2000), // timeline [2000..4000] -> source 0..2000
      ];
      expect(ClipTimeline.sourceMsForTimelineMs(clips, 0), 6000);
      expect(ClipTimeline.sourceMsForTimelineMs(clips, 2000), 0);
      expect(ClipTimeline.sourceMsForTimelineMs(clips, 3000), 1000);
    });
  });

  group('ClipTimeline.timelineMsForSourceMs', () {
    test('maps a covered source point back to the timeline', () {
      final clips = [_clip('a', 0, 3000), _clip('b', 7000, 9000)];
      expect(ClipTimeline.timelineMsForSourceMs(clips, 8000), 4000);
    });

    test('returns null for a source point inside a removed gap', () {
      final clips = [_clip('a', 0, 3000), _clip('b', 7000, 9000)];
      // Source 5000 was cut out — it lives in no enabled clip.
      expect(ClipTimeline.timelineMsForSourceMs(clips, 5000), isNull);
    });
  });

  group('ClipTimeline.isWholeRecording', () {
    test('true for the untouched single clip', () {
      final clips = [ClipTimeline.wholeRecording(10000)];
      expect(ClipTimeline.isWholeRecording(clips, 10000), isTrue);
    });

    test('false once trimmed or split', () {
      expect(
        ClipTimeline.isWholeRecording([_clip('a', 1000, 10000)], 10000),
        isFalse,
      );
      expect(
        ClipTimeline.isWholeRecording([
          _clip('a', 0, 4000),
          _clip('b', 4000, 10000),
        ], 10000),
        isFalse,
      );
    });
  });
}
