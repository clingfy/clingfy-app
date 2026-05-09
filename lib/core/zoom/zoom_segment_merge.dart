import 'package:clingfy/core/models/app_models.dart';

/// Result of [mergeEditedZoomSegment]: the new state of the edited segment
/// (with its range expanded to cover any absorbed neighbors and its
/// metadata preserved verbatim) plus the ids of segments that were
/// absorbed.
///
/// Pure data — controller-layer code translates [absorbedSegmentIds] into
/// the appropriate backing-list mutation (remove a manual segment by id,
/// tombstone an auto segment by id, etc).
class MergedZoomEdit {
  final ZoomSegment mergedSegment;
  final List<String> absorbedSegmentIds;

  const MergedZoomEdit({
    required this.mergedSegment,
    required this.absorbedSegmentIds,
  });

  bool get didMerge => absorbedSegmentIds.isNotEmpty;
}

/// Merge [editedSegment] into [existingSegments], collapsing any segments
/// whose range overlaps or touches the edit (within [mergeToleranceMs])
/// into a single merged segment. The merged segment adopts
/// [editedSegment]'s metadata so the user's latest intent — focus mode,
/// fixed target — wins over absorbed neighbors.
///
/// [existingSegments] may include the segment being edited (matched by
/// id); it is excluded from the absorption check so a move/resize is
/// not absorbed by its own previous range.
///
/// The function does not understand the auto/manual override distinction —
/// callers in the editor controller are responsible for translating the
/// absorbed ids into the right mutation (delete manual, tombstone auto,
/// etc).
MergedZoomEdit mergeEditedZoomSegment({
  required List<ZoomSegment> existingSegments,
  required ZoomSegment editedSegment,
  required int durationMs,
  int mergeToleranceMs = 0,
}) {
  final clampedEdit = _clampSegment(editedSegment, durationMs);
  var mergedStart = clampedEdit.startMs;
  var mergedEnd = clampedEdit.endMs;
  final absorbed = <String>[];

  // Iterate to a fixed point: an absorbed segment can extend the merged
  // range and pull in further neighbors that did not overlap initially.
  var changed = true;
  while (changed) {
    changed = false;
    for (final raw in existingSegments) {
      if (raw.id == editedSegment.id) continue;
      if (absorbed.contains(raw.id)) continue;
      final s = _clampSegment(raw, durationMs);
      if (s.endMs <= s.startMs) continue;
      final overlaps =
          s.startMs <= mergedEnd + mergeToleranceMs &&
          mergedStart <= s.endMs + mergeToleranceMs;
      if (!overlaps) continue;
      absorbed.add(raw.id);
      if (s.startMs < mergedStart) {
        mergedStart = s.startMs;
        changed = true;
      }
      if (s.endMs > mergedEnd) {
        mergedEnd = s.endMs;
        changed = true;
      }
    }
  }

  return MergedZoomEdit(
    mergedSegment: clampedEdit.copyWith(startMs: mergedStart, endMs: mergedEnd),
    absorbedSegmentIds: absorbed,
  );
}

/// Defensive normalizer for legacy/loaded segments: clamps to bounds,
/// drops degenerate ranges, and collapses any accidentally overlapping
/// segments into single ranges.
///
/// On metadata conflicts, the segment with the higher startMs wins —
/// matching "later edit wins" semantics used by [mergeEditedZoomSegment].
List<ZoomSegment> normalizeZoomSegments({
  required List<ZoomSegment> segments,
  required int durationMs,
  int mergeToleranceMs = 0,
}) {
  if (segments.isEmpty) return const [];
  final cleaned = <ZoomSegment>[];
  for (final raw in segments) {
    final s = _clampSegment(raw, durationMs);
    if (s.endMs <= s.startMs) continue;
    cleaned.add(s);
  }
  cleaned.sort((a, b) {
    final byStart = a.startMs.compareTo(b.startMs);
    if (byStart != 0) return byStart;
    return a.endMs.compareTo(b.endMs);
  });

  final result = <ZoomSegment>[];
  for (final next in cleaned) {
    if (result.isEmpty) {
      result.add(next);
      continue;
    }
    final last = result.last;
    if (next.startMs <= last.endMs + mergeToleranceMs) {
      result[result.length - 1] = next.copyWith(
        startMs: last.startMs < next.startMs ? last.startMs : next.startMs,
        endMs: last.endMs > next.endMs ? last.endMs : next.endMs,
      );
    } else {
      result.add(next);
    }
  }
  return result;
}

ZoomSegment _clampSegment(ZoomSegment s, int durationMs) {
  if (durationMs <= 0) return s;
  final start = s.startMs.clamp(0, durationMs);
  final end = s.endMs.clamp(0, durationMs);
  if (start == s.startMs && end == s.endMs) return s;
  return s.copyWith(startMs: start, endMs: end);
}
