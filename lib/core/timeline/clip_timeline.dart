import 'package:clingfy/core/timeline/model/edit_track.dart';

/// Pure layout + mapping math over an ordered list of [Clip]s.
///
/// A clip track is an ordered list of source windows tiled contiguously on the
/// edited timeline: enabled clips occupy timeline time in list order with no
/// gaps, so the edited duration is the sum of enabled clip durations. This is
/// the single source of truth for that layout and, critically, for mapping a
/// point on the *edited* timeline back to a point in the *original* recording.
///
/// That map is the load-bearing piece for split/cut: every other effect (zoom
/// segments, cursor samples, camera sync) is keyed to original recording time.
/// Once clips re-time or reorder the video, those effects must be remapped
/// through [sourceMsForTimelineMs] or they silently desync.
///
/// Pure value math — no Flutter, no native, no I/O — so it is fully unit
/// testable and identical on macOS and Windows.
class ClipTimeline {
  const ClipTimeline._();

  /// Duration of a single clip's source window, never negative.
  static int clipDurationMs(Clip clip) {
    final d = clip.sourceOutMs - clip.sourceInMs;
    return d < 0 ? 0 : d;
  }

  /// The single clip covering the whole recording — the default state before
  /// the user makes any cut.
  static Clip wholeRecording(int recordingDurationMs, {String id = 'clip_0'}) =>
      Clip(
        id: id,
        sourceInMs: 0,
        sourceOutMs: recordingDurationMs < 0 ? 0 : recordingDurationMs,
        timelineStartMs: 0,
      );

  /// Re-stacks [clips] contiguously in list order, recomputing each clip's
  /// [Clip.timelineStartMs] as the cumulative duration of the preceding enabled
  /// clips. Disabled clips are retained (so a future per-clip mute is possible)
  /// but occupy no timeline time. This canonical gap-free form is what every
  /// other method here assumes, so operations always return a normalized list.
  static List<Clip> normalized(List<Clip> clips) {
    final out = <Clip>[];
    var cursor = 0;
    for (final clip in clips) {
      out.add(clip.copyWith(timelineStartMs: cursor));
      if (clip.enabled) cursor += clipDurationMs(clip);
    }
    return out;
  }

  /// Total edited-timeline duration: the sum of enabled clip durations.
  static int totalDurationMs(List<Clip> clips) {
    var total = 0;
    for (final clip in clips) {
      if (clip.enabled) total += clipDurationMs(clip);
    }
    return total;
  }

  /// Maps a point on the edited timeline to the corresponding point in the
  /// original recording, or `null` when [timelineMs] falls past the end (or
  /// before the start). Normalizes internally, so callers need not pre-stack.
  ///
  /// A point parked exactly at the timeline end resolves to the source-out of
  /// the last enabled clip, so a scrubber at the very end maps cleanly instead
  /// of returning null.
  static int? sourceMsForTimelineMs(List<Clip> clips, int timelineMs) {
    if (timelineMs < 0) return null;
    final norm = normalized(clips);
    Clip? lastEnabled;
    for (final clip in norm) {
      if (!clip.enabled) continue;
      lastEnabled = clip;
      final start = clip.timelineStartMs;
      final end = start + clipDurationMs(clip);
      if (timelineMs < end) {
        return clip.sourceInMs + (timelineMs - start);
      }
    }
    if (lastEnabled != null && timelineMs == totalDurationMs(norm)) {
      return lastEnabled.sourceOutMs;
    }
    return null;
  }

  /// Maps a point in the original recording to its position on the edited
  /// timeline, or `null` when no enabled clip covers that source point. When
  /// several clips cover the same source moment (possible after arrange), the
  /// first occurrence in timeline order wins.
  static int? timelineMsForSourceMs(List<Clip> clips, int sourceMs) {
    for (final clip in normalized(clips)) {
      if (!clip.enabled) continue;
      if (sourceMs >= clip.sourceInMs && sourceMs < clip.sourceOutMs) {
        return clip.timelineStartMs + (sourceMs - clip.sourceInMs);
      }
    }
    return null;
  }

  /// True when the clip list is just the untouched whole recording: a single
  /// enabled clip starting at source 0. Lets render paths skip clip handling
  /// entirely (a zero-cost passthrough, like an identity color grade).
  static bool isWholeRecording(List<Clip> clips, int recordingDurationMs) {
    final enabled = clips.where((c) => c.enabled).toList();
    if (enabled.length != 1) return false;
    final only = enabled.first;
    return only.sourceInMs == 0 && only.sourceOutMs == recordingDurationMs;
  }
}
