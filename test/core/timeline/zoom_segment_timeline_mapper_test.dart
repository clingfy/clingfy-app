import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:clingfy/core/timeline/zoom_segment_timeline_mapper.dart';
import 'package:flutter_test/flutter_test.dart';

// §5.8: the zoom lane's SOURCE-time segments must land on the EDITED ruler.

ZoomSegment _seg(String id, int start, int end) =>
    ZoomSegment(id: id, startMs: start, endMs: end);

Clip _clip(
  String id,
  int sourceIn,
  int sourceOut,
  int timelineStart, {
  bool enabled = true,
}) => Clip(
  id: id,
  sourceInMs: sourceIn,
  sourceOutMs: sourceOut,
  timelineStartMs: timelineStart,
  enabled: enabled,
);

void main() {
  test('empty clips (pre-editor) is a pure passthrough', () {
    final segments = [_seg('a', 100, 200)];
    expect(mapZoomSegmentsToEditedTimeline(segments, const []), same(segments));
  });

  test('the whole-recording identity clip maps 1:1', () {
    final mapped = mapZoomSegmentsToEditedTimeline(
      [_seg('a', 1000, 3000)],
      [_clip('c1', 0, 20000, 0)],
    );
    expect(mapped, hasLength(1));
    expect(mapped.single.id, 'a');
    expect(mapped.single.startMs, 1000);
    expect(mapped.single.endMs, 3000);
  });

  test('a segment inside a cut gap disappears from the lane', () {
    // Kept: [0,5000) + [10000,20000); the segment lives in the cut.
    final mapped = mapZoomSegmentsToEditedTimeline(
      [_seg('a', 6000, 9000)],
      [_clip('c1', 0, 5000, 0), _clip('c2', 10000, 20000, 5000)],
    );
    expect(mapped, isEmpty);
  });

  test('a segment straddling a cut clamps to the kept part', () {
    // Cut at 5000: segment [4000,7000) keeps only [4000,5000).
    final mapped = mapZoomSegmentsToEditedTimeline(
      [_seg('a', 4000, 7000)],
      [_clip('c1', 0, 5000, 0), _clip('c2', 10000, 20000, 5000)],
    );
    expect(mapped, hasLength(1));
    expect(mapped.single.startMs, 4000);
    expect(mapped.single.endMs, 5000);
  });

  test('a segment spanning a cut splits into one pill per kept range', () {
    // Kept [0,5000)+[10000,20000); segment [4000,12000) → [4000,5000) and
    // the post-cut part re-based: source 10000..12000 → edited 5000..7000.
    final mapped = mapZoomSegmentsToEditedTimeline(
      [_seg('a', 4000, 12000)],
      [_clip('c1', 0, 5000, 0), _clip('c2', 10000, 20000, 5000)],
    );
    expect(mapped, hasLength(2));
    expect(mapped[0].id, 'a');
    expect(mapped[0].startMs, 4000);
    expect(mapped[0].endMs, 5000);
    expect(mapped[1].id, 'a#1');
    expect(mapped[1].startMs, 5000);
    expect(mapped[1].endMs, 7000);
  });

  test('reordered clips place segments at the clip\'s new position', () {
    // Timeline: later source range first. Segment at source [12500,13000)
    // sits in the FIRST timeline clip → edited [500,1000).
    final mapped = mapZoomSegmentsToEditedTimeline(
      [_seg('a', 12500, 13000), _seg('b', 2500, 3000)],
      [_clip('c1', 12000, 18000, 0), _clip('c2', 2000, 8000, 6000)],
    );
    expect(mapped, hasLength(2));
    // Sorted by edited start: 'a' (500) before 'b' (6500).
    expect(mapped[0].id, 'a');
    expect(mapped[0].startMs, 500);
    expect(mapped[0].endMs, 1000);
    expect(mapped[1].id, 'b');
    expect(mapped[1].startMs, 6500);
    expect(mapped[1].endMs, 7000);
  });

  test('disabled clips contribute nothing', () {
    final mapped = mapZoomSegmentsToEditedTimeline(
      [_seg('a', 1000, 2000)],
      [_clip('c1', 0, 20000, 0, enabled: false)],
    );
    expect(mapped, isEmpty);
  });

  test('segment metadata (focus mode, source, baseId) survives the remap', () {
    const target = NormalizedPoint(0.25, 0.75);
    final mapped = mapZoomSegmentsToEditedTimeline(
      [
        ZoomSegment(
          id: 'm',
          startMs: 1000,
          endMs: 2000,
          source: 'manual',
          baseId: 'auto_3',
          focusMode: ZoomFocusMode.fixedTarget,
          fixedTarget: target,
        ),
      ],
      [_clip('c1', 0, 20000, 0)],
    );
    expect(mapped.single.source, 'manual');
    expect(mapped.single.baseId, 'auto_3');
    expect(mapped.single.focusMode, ZoomFocusMode.fixedTarget);
    expect(mapped.single.fixedTarget, target);
  });
}
