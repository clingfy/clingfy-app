import 'dart:convert';

import 'package:clingfy/core/timeline/model/canvas_state.dart';
import 'package:clingfy/core/timeline/model/color_grade.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:clingfy/core/timeline/model/timeline.dart';

/// The single read/write path between a [Timeline] and the `post/state.json`
/// envelope.
///
/// Owns the top-level schema version and is deliberately forgiving on decode so
/// projects always open: a missing body yields an empty timeline, unknown track
/// kinds are dropped, and missing fields fall back to defaults. This is the one
/// place to evolve the on-disk format.
class TimelineCodec {
  const TimelineCodec();

  Map<String, dynamic> encode(Timeline timeline) => {
    'schemaVersion': timeline.schemaVersion,
    'timeline': {
      'durationMs': timeline.durationMs,
      'grade': timeline.grade.toMap(),
      // Omitted when untouched, so a recording with no canvas edits writes the
      // same bytes it did before v3 carried this block.
      if (!timeline.canvas.isDefault) 'canvas': timeline.canvas.toMap(),
      'tracks': [for (final track in timeline.tracks) track.toMap()],
    },
  };

  Timeline decode(Map<dynamic, dynamic> root) {
    final body = root['timeline'];
    if (body is! Map) return const Timeline();

    final version =
        (root['schemaVersion'] as num?)?.toInt() ?? kTimelineSchemaVersion;

    final tracks = <EditTrack>[];
    final rawTracks = body['tracks'];
    if (rawTracks is List) {
      for (final raw in rawTracks) {
        if (raw is Map) {
          final track = EditTrack.fromMap(raw);
          // Unknown track kinds are dropped so a project written by a newer or
          // older build still opens instead of crashing.
          if (track != null) tracks.add(track);
        }
      }
    }

    return Timeline(
      schemaVersion: version,
      durationMs: (body['durationMs'] as num?)?.toInt() ?? 0,
      grade: body['grade'] is Map
          ? ColorGrade.fromMap(body['grade'] as Map)
          : const ColorGrade(),
      canvas: body['canvas'] is Map
          ? CanvasState.fromMap(body['canvas'] as Map)
          : const CanvasState(),
      tracks: tracks,
    );
  }

  String encodeJson(Timeline timeline) =>
      const JsonEncoder.withIndent('  ').convert(encode(timeline));

  Timeline decodeJson(String json) {
    final decoded = jsonDecode(json);
    return decoded is Map ? decode(decoded) : const Timeline();
  }
}
