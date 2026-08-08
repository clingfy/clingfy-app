import 'package:flutter/foundation.dart';
import 'package:clingfy/core/timeline/model/canvas_state.dart';
import 'package:clingfy/core/timeline/model/color_grade.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';

/// Version of the `post/state.json` schema this build reads and writes.
/// v3 added [Timeline.canvas], folding what used to be `editor_state.json`
/// into this envelope. A v2 file has no `canvas` block and decodes to the
/// defaults, which is exactly what a project with no canvas edits looked like.
const int kTimelineSchemaVersion = 3;

/// The whole editing state for one recording: an immutable tree of tracks plus
/// the canvas-wide color grade.
///
/// Immutable — edits produce a new [Timeline] via [copyWith], replacing only the
/// changed track so unchanged tracks are shared by reference (cheap 60 Hz drag
/// previews). Serialized via `TimelineCodec`.
@immutable
class Timeline {
  const Timeline({
    this.durationMs = 0,
    this.tracks = const <EditTrack>[],
    this.grade = const ColorGrade(),
    this.canvas = const CanvasState(),
    this.schemaVersion = kTimelineSchemaVersion,
  });

  /// Authoritative recording length. Defined by the clip track once present.
  final int durationMs;
  final List<EditTrack> tracks;
  final ColorGrade grade;

  /// Padding, corner radius and background. Previously `editor_state.json`.
  final CanvasState canvas;
  final int schemaVersion;

  /// The first track of type [T], or `null`. Convenience for callers that
  /// expect a single track of a given kind (zoom / audio / caption / clip).
  T? trackOfType<T extends EditTrack>() {
    for (final track in tracks) {
      if (track is T) return track;
    }
    return null;
  }

  /// Returns a copy with the first track of [replacement]'s runtime type
  /// swapped for [replacement]; appends it if no such track exists yet.
  Timeline withTrack(EditTrack replacement) {
    final next = <EditTrack>[];
    var replaced = false;
    for (final track in tracks) {
      if (!replaced && track.runtimeType == replacement.runtimeType) {
        next.add(replacement);
        replaced = true;
      } else {
        next.add(track);
      }
    }
    if (!replaced) next.add(replacement);
    return copyWith(tracks: next);
  }

  Timeline copyWith({
    int? durationMs,
    List<EditTrack>? tracks,
    ColorGrade? grade,
    CanvasState? canvas,
    int? schemaVersion,
  }) => Timeline(
    durationMs: durationMs ?? this.durationMs,
    tracks: tracks ?? this.tracks,
    grade: grade ?? this.grade,
    canvas: canvas ?? this.canvas,
    schemaVersion: schemaVersion ?? this.schemaVersion,
  );
}
