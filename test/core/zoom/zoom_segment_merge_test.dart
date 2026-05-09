import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/zoom/zoom_segment_merge.dart';
import 'package:flutter_test/flutter_test.dart';

ZoomSegment _seg(
  String id,
  int start,
  int end, {
  String source = 'manual',
  ZoomFocusMode focusMode = ZoomFocusMode.followCursor,
  NormalizedPoint? fixedTarget,
  String? baseId,
}) => ZoomSegment(
  id: id,
  startMs: start,
  endMs: end,
  source: source,
  baseId: baseId,
  focusMode: focusMode,
  fixedTarget: fixedTarget,
);

void main() {
  group('mergeEditedZoomSegment', () {
    test('non-overlapping edit absorbs nothing and clamps to bounds', () {
      final result = mergeEditedZoomSegment(
        existingSegments: [_seg('a', 0, 1000)],
        editedSegment: _seg('b', 2000, 3000),
        durationMs: 10000,
      );
      expect(result.didMerge, isFalse);
      expect(result.absorbedSegmentIds, isEmpty);
      expect(result.mergedSegment.startMs, 2000);
      expect(result.mergedSegment.endMs, 3000);
    });

    test('absorbs a single overlapping neighbor', () {
      final result = mergeEditedZoomSegment(
        existingSegments: [_seg('a', 1000, 3000)],
        editedSegment: _seg('b', 2500, 5000),
        durationMs: 10000,
      );
      expect(result.absorbedSegmentIds, ['a']);
      expect(result.mergedSegment.startMs, 1000);
      expect(result.mergedSegment.endMs, 5000);
    });

    test('absorbs multiple overlapping neighbors', () {
      final result = mergeEditedZoomSegment(
        existingSegments: [
          _seg('a', 1000, 1500),
          _seg('b', 1800, 2200),
          _seg('c', 2400, 2800),
          _seg('d', 6000, 6500),
        ],
        editedSegment: _seg('e', 1300, 2500),
        durationMs: 10000,
      );
      expect(result.absorbedSegmentIds, containsAll(['a', 'b', 'c']));
      expect(result.absorbedSegmentIds, isNot(contains('d')));
      expect(result.mergedSegment.startMs, 1000);
      expect(result.mergedSegment.endMs, 2800);
    });

    test(
      'expands transitively: an absorbed segment pulls in further neighbors',
      () {
        final result = mergeEditedZoomSegment(
          existingSegments: [
            _seg('a', 800, 1200), // does not overlap edit (1500-2500)
            _seg('b', 1100, 1700), // overlaps edit and a
          ],
          editedSegment: _seg('e', 1500, 2500),
          durationMs: 10000,
        );
        expect(result.absorbedSegmentIds, containsAll(['a', 'b']));
        expect(result.mergedSegment.startMs, 800);
        expect(result.mergedSegment.endMs, 2500);
      },
    );

    test('touching edges merge by default (tolerance = 0)', () {
      final result = mergeEditedZoomSegment(
        existingSegments: [_seg('a', 1000, 2000)],
        editedSegment: _seg('b', 2000, 3000),
        durationMs: 10000,
      );
      expect(result.absorbedSegmentIds, ['a']);
      expect(result.mergedSegment.startMs, 1000);
      expect(result.mergedSegment.endMs, 3000);
    });

    test('a 1ms gap does not merge', () {
      final result = mergeEditedZoomSegment(
        existingSegments: [_seg('a', 1000, 2000)],
        editedSegment: _seg('b', 2001, 3000),
        durationMs: 10000,
      );
      expect(result.absorbedSegmentIds, isEmpty);
      expect(result.mergedSegment.startMs, 2001);
      expect(result.mergedSegment.endMs, 3000);
    });

    test('edited segment fully inside existing absorbs the existing', () {
      final result = mergeEditedZoomSegment(
        existingSegments: [_seg('a', 1000, 4000)],
        editedSegment: _seg('b', 2000, 3000),
        durationMs: 10000,
      );
      expect(result.absorbedSegmentIds, ['a']);
      expect(result.mergedSegment.startMs, 1000);
      expect(result.mergedSegment.endMs, 4000);
    });

    test('existing segment fully inside edited absorbs the existing', () {
      final result = mergeEditedZoomSegment(
        existingSegments: [_seg('a', 2000, 3000)],
        editedSegment: _seg('b', 1000, 4000),
        durationMs: 10000,
      );
      expect(result.absorbedSegmentIds, ['a']);
      expect(result.mergedSegment.startMs, 1000);
      expect(result.mergedSegment.endMs, 4000);
    });

    test('edited metadata wins on focus mode and fixed target', () {
      const fixed = NormalizedPoint(0.7, 0.3);
      final result = mergeEditedZoomSegment(
        existingSegments: [
          _seg('a', 1000, 3000, focusMode: ZoomFocusMode.followCursor),
        ],
        editedSegment: _seg(
          'b',
          2500,
          5000,
          focusMode: ZoomFocusMode.fixedTarget,
          fixedTarget: fixed,
        ),
        durationMs: 10000,
      );
      expect(result.mergedSegment.focusMode, ZoomFocusMode.fixedTarget);
      expect(result.mergedSegment.fixedTarget, fixed);
    });

    test('edited segment is excluded from absorption by id (move/resize)', () {
      // Simulate a move: edited has the same id as a segment already in the
      // existing list (its old position). It must NOT absorb itself.
      final result = mergeEditedZoomSegment(
        existingSegments: [_seg('m1', 1000, 2000)],
        editedSegment: _seg('m1', 3000, 4000),
        durationMs: 10000,
      );
      expect(result.absorbedSegmentIds, isEmpty);
      expect(result.mergedSegment.startMs, 3000);
      expect(result.mergedSegment.endMs, 4000);
    });

    test('clamps the edited range to [0, durationMs]', () {
      final result = mergeEditedZoomSegment(
        existingSegments: const [],
        editedSegment: _seg('b', -500, 12000),
        durationMs: 10000,
      );
      expect(result.mergedSegment.startMs, 0);
      expect(result.mergedSegment.endMs, 10000);
    });

    test('drops degenerate existing segments without absorbing them', () {
      final result = mergeEditedZoomSegment(
        existingSegments: [
          _seg('tomb', 5000, 5000), // tombstone-shaped
          _seg('a', 1000, 2200),
        ],
        editedSegment: _seg('b', 2000, 3000),
        durationMs: 10000,
      );
      expect(result.absorbedSegmentIds, ['a']);
      expect(result.absorbedSegmentIds, isNot(contains('tomb')));
    });
  });

  group('normalizeZoomSegments', () {
    test('drops degenerate ranges and clamps to bounds', () {
      final result = normalizeZoomSegments(
        segments: [
          _seg('a', -200, 1000),
          _seg('b', 5000, 5000),
          _seg('c', 9500, 12000),
        ],
        durationMs: 10000,
      );
      expect(result.map((s) => s.id), ['a', 'c']);
      expect(result.first.startMs, 0);
      expect(result.last.endMs, 10000);
    });

    test('collapses overlapping/touching segments and sorts by start', () {
      final result = normalizeZoomSegments(
        segments: [
          _seg('c', 4000, 5000),
          _seg('a', 1000, 2000),
          _seg('b', 1500, 3000),
          _seg('d', 5000, 6000),
        ],
        durationMs: 10000,
      );
      expect(result, hasLength(2));
      expect(result.first.startMs, 1000);
      expect(result.first.endMs, 3000);
      expect(result.last.startMs, 4000);
      expect(result.last.endMs, 6000);
    });

    test('later segment wins on metadata when overlap collapses', () {
      const fixed = NormalizedPoint(0.2, 0.8);
      final result = normalizeZoomSegments(
        segments: [
          _seg('a', 1000, 2500, focusMode: ZoomFocusMode.followCursor),
          _seg(
            'b',
            2000,
            3000,
            focusMode: ZoomFocusMode.fixedTarget,
            fixedTarget: fixed,
          ),
        ],
        durationMs: 10000,
      );
      expect(result, hasLength(1));
      expect(result.single.focusMode, ZoomFocusMode.fixedTarget);
      expect(result.single.fixedTarget, fixed);
    });
  });
}
