import 'package:clingfy/core/timeline/clip_operations.dart';
import 'package:clingfy/core/timeline/clip_timeline.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  List<Clip> whole([int durationMs = 10000]) => [
    ClipTimeline.wholeRecording(durationMs),
  ];

  group('ClipOperations.splitAt', () {
    test('splits a clip into two adjacent pieces at the point', () {
      final out = ClipOperations.splitAt(whole(), 4000, newId: 'c1');
      expect(out, hasLength(2));
      expect(out[0].sourceInMs, 0);
      expect(out[0].sourceOutMs, 4000);
      expect(out[1].id, 'c1');
      expect(out[1].sourceInMs, 4000);
      expect(out[1].sourceOutMs, 10000);
      // Timeline stays contiguous and total is preserved.
      expect(out[1].timelineStartMs, 4000);
      expect(ClipTimeline.totalDurationMs(out), 10000);
    });

    test('is a no-op exactly on a clip boundary', () {
      final out = ClipOperations.splitAt(whole(), 0, newId: 'c1');
      expect(out, hasLength(1));
    });

    test('is a no-op past the end', () {
      final out = ClipOperations.splitAt(whole(), 99999, newId: 'c1');
      expect(out, hasLength(1));
    });

    test('refuses a split that would create a sub-minimum piece', () {
      // 10ms from the start is below the ~33ms minimum.
      final out = ClipOperations.splitAt(whole(), 10, newId: 'c1');
      expect(out, hasLength(1));
    });

    test('splits the correct clip when several exist', () {
      final two = ClipOperations.splitAt(whole(), 4000, newId: 'c1');
      // Split the second clip (timeline 4000..10000) at timeline 7000.
      final three = ClipOperations.splitAt(two, 7000, newId: 'c2');
      expect(three, hasLength(3));
      expect(three.map((c) => c.timelineStartMs), [0, 4000, 7000]);
      expect(ClipTimeline.totalDurationMs(three), 10000);
    });
  });

  group('ClipOperations.remove', () {
    test('drops the clip and ripples the rest left', () {
      final two = ClipOperations.splitAt(whole(), 4000, newId: 'c1');
      final out = ClipOperations.remove(two, 'clip_0');
      expect(out, hasLength(1));
      expect(out.first.id, 'c1');
      // Ripple: the surviving clip now starts the timeline at 0...
      expect(out.first.timelineStartMs, 0);
      // ...but still points at source 4000 — timeline 0 maps to source 4000.
      expect(ClipTimeline.sourceMsForTimelineMs(out, 0), 4000);
      expect(ClipTimeline.totalDurationMs(out), 6000);
    });

    test('removing a middle clip closes the gap', () {
      final two = ClipOperations.splitAt(whole(), 3000, newId: 'b');
      final three = ClipOperations.splitAt(two, 6000, newId: 'c');
      final out = ClipOperations.remove(three, 'b'); // drop the middle
      expect(out.map((c) => c.id), ['clip_0', 'c']);
      expect(out.map((c) => c.timelineStartMs), [0, 3000]);
      expect(ClipTimeline.totalDurationMs(out), 7000);
    });

    test('is a no-op for an unknown id', () {
      final out = ClipOperations.remove(whole(), 'nope');
      expect(out, hasLength(1));
    });
  });

  group('ClipOperations.moveToIndex', () {
    test('reorders clips and re-tiles the timeline', () {
      final two = ClipOperations.splitAt(whole(), 4000, newId: 'c1');
      final out = ClipOperations.moveToIndex(two, 'c1', 0); // c1 to front
      expect(out.map((c) => c.id), ['c1', 'clip_0']);
      // c1 (source 4000..10000) now plays first.
      expect(ClipTimeline.sourceMsForTimelineMs(out, 0), 4000);
      // total unchanged by a reorder
      expect(ClipTimeline.totalDurationMs(out), 10000);
    });

    test('clamps an out-of-range index', () {
      final two = ClipOperations.splitAt(whole(), 4000, newId: 'c1');
      final out = ClipOperations.moveToIndex(two, 'clip_0', 99);
      expect(out.map((c) => c.id), ['c1', 'clip_0']);
    });

    test('is a no-op for an unknown id', () {
      final two = ClipOperations.splitAt(whole(), 4000, newId: 'c1');
      final out = ClipOperations.moveToIndex(two, 'nope', 0);
      expect(out.map((c) => c.id), ['clip_0', 'c1']);
    });
  });

  group('ClipOperations.trim', () {
    test('trims the start inward', () {
      final out = ClipOperations.trim(
        whole(),
        'clip_0',
        sourceInMs: 2000,
        recordingDurationMs: 10000,
      );
      expect(out.first.sourceInMs, 2000);
      expect(out.first.sourceOutMs, 10000);
      expect(ClipTimeline.totalDurationMs(out), 8000);
    });

    test('trims the end inward', () {
      final out = ClipOperations.trim(
        whole(),
        'clip_0',
        sourceOutMs: 8000,
        recordingDurationMs: 10000,
      );
      expect(out.first.sourceOutMs, 8000);
      expect(ClipTimeline.totalDurationMs(out), 8000);
    });

    test('clamps the start so the clip keeps the minimum duration', () {
      final out = ClipOperations.trim(
        whole(),
        'clip_0',
        sourceInMs: 9999, // would leave a 1ms clip
        recordingDurationMs: 10000,
      );
      final clip = out.first;
      expect(clip.sourceOutMs - clip.sourceInMs, greaterThanOrEqualTo(33));
      expect(clip.sourceOutMs, 10000); // the untouched edge stays put
    });

    test('clamps bounds to the captured recording range', () {
      final out = ClipOperations.trim(
        whole(),
        'clip_0',
        sourceOutMs: 99999,
        recordingDurationMs: 10000,
      );
      expect(out.first.sourceOutMs, 10000);
    });

    test('leaves other clips untouched', () {
      final two = ClipOperations.splitAt(whole(), 4000, newId: 'c1');
      final out = ClipOperations.trim(
        two,
        'c1',
        sourceInMs: 5000,
        recordingDurationMs: 10000,
      );
      expect(out[0].sourceInMs, 0); // clip_0 unchanged
      expect(out[1].sourceInMs, 5000);
    });
  });
}
