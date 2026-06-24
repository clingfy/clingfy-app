import 'package:clingfy/core/timeline/clip_timeline.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:clingfy/core/timeline/timeline_timebase.dart';

/// Pure transforms over a clip list — split, remove (ripple), trim, and move
/// (arrange/reorder). Every method takes a clip list and returns a new
/// normalized list (see [ClipTimeline.normalized]); none mutate their input.
///
/// These are the building blocks the undo/redo [SetClipsCommand] wraps and the
/// clip-lane UI drives. Keeping them pure makes the tricky edge cases (boundary
/// splits, minimum durations, ripple) exhaustively unit testable with no native
/// or UI in the loop.
class ClipOperations {
  const ClipOperations._();

  /// Splits the enabled clip covering [timelineMs] into two adjacent clips at
  /// that point, giving the right-hand piece [newId].
  ///
  /// Returns the input normalized (no new clip) when the split would not
  /// produce two valid clips: the point sits on a clip boundary, lands in no
  /// enabled clip, or either resulting piece would be shorter than
  /// [minDurationMs].
  static List<Clip> splitAt(
    List<Clip> clips,
    int timelineMs, {
    required String newId,
    int? minDurationMs,
  }) {
    final minDur = minDurationMs ?? TimelineTimebase.minDurationMs;
    final norm = ClipTimeline.normalized(clips);

    for (var i = 0; i < norm.length; i++) {
      final clip = norm[i];
      if (!clip.enabled) continue;
      final start = clip.timelineStartMs;
      final end = start + ClipTimeline.clipDurationMs(clip);

      // Strictly inside this clip (boundaries are no-ops — nothing to split).
      if (timelineMs <= start || timelineMs >= end) continue;

      final offset = timelineMs - start; // into the source window
      final splitSource = clip.sourceInMs + offset;

      final leftDur = splitSource - clip.sourceInMs;
      final rightDur = clip.sourceOutMs - splitSource;
      if (leftDur < minDur || rightDur < minDur) {
        return norm; // too short on one side — refuse
      }

      final left = clip.copyWith(sourceOutMs: splitSource);
      final right = clip.copyWith(id: newId, sourceInMs: splitSource);
      final next = <Clip>[
        ...norm.sublist(0, i),
        left,
        right,
        ...norm.sublist(i + 1),
      ];
      return ClipTimeline.normalized(next);
    }
    return norm;
  }

  /// Removes the clip with [id] and ripples the rest left. No-op (normalized
  /// input) when [id] is unknown.
  static List<Clip> remove(List<Clip> clips, String id) =>
      ClipTimeline.normalized(
        clips.where((c) => c.id != id).toList(growable: false),
      );

  /// Moves the clip with [id] to [newIndex] in list order (arrange/reorder),
  /// then re-tiles contiguously. [newIndex] is clamped into range. No-op when
  /// [id] is unknown.
  static List<Clip> moveToIndex(List<Clip> clips, String id, int newIndex) {
    final list = List<Clip>.of(clips);
    final from = list.indexWhere((c) => c.id == id);
    if (from < 0) return ClipTimeline.normalized(list);

    final clip = list.removeAt(from);
    final to = newIndex.clamp(0, list.length);
    list.insert(to, clip);
    return ClipTimeline.normalized(list);
  }

  /// Trims a clip's source [sourceInMs] / [sourceOutMs] bounds, re-tiling the
  /// timeline afterward. Bounds are clamped to the captured range
  /// `[0, recordingDurationMs]`, kept in order, and held to at least
  /// [minDurationMs]; a trim that would invert or shrink past the minimum is
  /// clamped rather than rejected, so dragging an edge always feels live.
  ///
  /// Both shrinking (cut more) and growing back within the capture (recover
  /// footage) are allowed; undo restores the prior bounds exactly.
  static List<Clip> trim(
    List<Clip> clips,
    String id, {
    int? sourceInMs,
    int? sourceOutMs,
    required int recordingDurationMs,
    int? minDurationMs,
  }) {
    final minDur = minDurationMs ?? TimelineTimebase.minDurationMs;
    final maxSource = recordingDurationMs < 0 ? 0 : recordingDurationMs;

    final out = <Clip>[];
    for (final clip in clips) {
      if (clip.id != id) {
        out.add(clip);
        continue;
      }
      var inMs = (sourceInMs ?? clip.sourceInMs).clamp(0, maxSource);
      var outMs = (sourceOutMs ?? clip.sourceOutMs).clamp(0, maxSource);

      // Keep at least minDur, anchored on whichever edge the caller did not
      // move (so dragging the start edge never silently shoves the end edge).
      if (outMs - inMs < minDur) {
        if (sourceInMs != null && sourceOutMs == null) {
          inMs = (outMs - minDur).clamp(0, maxSource);
        } else if (sourceOutMs != null && sourceInMs == null) {
          outMs = (inMs + minDur).clamp(0, maxSource);
        } else {
          outMs = (inMs + minDur).clamp(0, maxSource);
        }
      }
      out.add(clip.copyWith(sourceInMs: inMs, sourceOutMs: outMs));
    }
    return ClipTimeline.normalized(out);
  }
}
