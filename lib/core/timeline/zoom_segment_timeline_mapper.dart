import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';

/// Maps SOURCE-time zoom segments onto the EDITED timeline defined by [clips]
/// (doc §5.8: under cuts the zoom lane used to draw its segments in recording
/// time against the edited-time ruler, so pills sat at the wrong x and ran
/// past the timeline end).
///
/// Each segment is intersected with every enabled clip's source window and
/// re-based to that clip's timeline position, so:
///   * a segment inside a cut gap disappears from the lane,
///   * a segment straddling a cut is clamped to the kept part(s),
///   * a segment spanning multiple kept ranges splits into one pill per range
///     (each keeps the original id with a `#<n>` suffix so keys stay unique),
///   * reordered clips place their segments at the clip's new position.
///
/// The identity timeline (one whole-recording clip at 0, or an empty list)
/// maps 1:1, so callers can apply this unconditionally. Pure — display-side
/// only; the underlying zoom model stays in source time (the native
/// compositor and export consume source-time segments and do their own
/// edited-time mapping).
List<ZoomSegment> mapZoomSegmentsToEditedTimeline(
  List<ZoomSegment> segments,
  List<Clip> clips,
) {
  if (clips.isEmpty) return segments;
  final enabled = [
    for (final c in clips)
      if (c.enabled) c,
  ];
  if (enabled.isEmpty) return const [];

  final mapped = <ZoomSegment>[];
  for (final segment in segments) {
    var piece = 0;
    for (final clip in enabled) {
      final overlapStart = segment.startMs > clip.sourceInMs
          ? segment.startMs
          : clip.sourceInMs;
      final overlapEnd = segment.endMs < clip.sourceOutMs
          ? segment.endMs
          : clip.sourceOutMs;
      if (overlapEnd <= overlapStart) continue;
      final editedStart =
          clip.timelineStartMs + (overlapStart - clip.sourceInMs);
      final editedEnd = clip.timelineStartMs + (overlapEnd - clip.sourceInMs);
      mapped.add(
        ZoomSegment(
          // First piece keeps the original id (the common no-split case stays
          // key-stable); later pieces get a suffix so lane keys never collide.
          id: piece == 0 ? segment.id : '${segment.id}#$piece',
          startMs: editedStart,
          endMs: editedEnd,
          source: segment.source,
          baseId: segment.baseId,
          focusMode: segment.focusMode,
          fixedTarget: segment.fixedTarget,
        ),
      );
      piece++;
    }
  }
  mapped.sort((a, b) => a.startMs.compareTo(b.startMs));
  return mapped;
}
