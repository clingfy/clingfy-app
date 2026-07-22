import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:clingfy/core/logging/logger_service.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';

/// Persisted per-recording clip edits (split / cut / trim / reorder).
///
/// Stored as `clips_state.json` inside the recording's `.clingfyproj` bundle,
/// right beside the canvas/color `editor_state.json`. Clips get their own file
/// because the clip model lives in `lib/core` and must not depend on the
/// `lib/app` canvas store — the layering rule keeps reusable domain code free
/// of product-shell imports.
///
/// [recordingDurationMs] records the recording length at save time for
/// diagnostics and future migrations. The restore path does not gate on it —
/// it validates the clips against the live recording duration instead, which
/// is the stricter, always-current bound.
@immutable
class ClipPersistState {
  const ClipPersistState({
    required this.recordingDurationMs,
    required this.clips,
  });

  /// Bump when the on-disk shape changes incompatibly.
  static const int version = 1;

  final int recordingDurationMs;
  final List<Clip> clips;

  Map<String, dynamic> toJson() => {
    'version': version,
    'recordingDurationMs': recordingDurationMs,
    'clips': [for (final c in clips) c.toMap()],
  };

  /// Parses persisted state. Returns `null` for any malformed payload (or an
  /// empty clip list) so the caller falls back to the whole-recording seed —
  /// which keeps pre-persistence recordings working.
  static ClipPersistState? fromJson(Map<String, dynamic> json) {
    final raw = json['clips'];
    if (raw is! List || raw.isEmpty) return null;
    final clips = <Clip>[];
    for (final entry in raw) {
      if (entry is! Map) return null;
      clips.add(Clip.fromMap(entry));
    }
    return ClipPersistState(
      recordingDurationMs: (json['recordingDurationMs'] as num?)?.toInt() ?? 0,
      clips: clips,
    );
  }
}

/// Reads/writes [ClipPersistState] as `clips_state.json` inside a recording
/// project bundle. All I/O is best-effort: a failure is logged and swallowed —
/// persistence must never break editing or playback.
abstract final class ClipStateStore {
  static const String _fileName = 'clips_state.json';

  static File _file(String projectPath) =>
      File('$projectPath${Platform.pathSeparator}$_fileName');

  static Future<void> save(String projectPath, ClipPersistState state) async {
    try {
      const encoder = JsonEncoder.withIndent('  ');
      await _file(projectPath).writeAsString(encoder.convert(state.toJson()));
    } catch (e, st) {
      Log.w('Clips', 'failed to persist clips_state.json', e, st);
    }
  }

  /// Synchronous so attaching the clip editor on project open does not add an
  /// extra async hop. The file is tiny and read exactly once per open.
  static ClipPersistState? load(String projectPath) {
    try {
      final file = _file(projectPath);
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return null;
      return ClipPersistState.fromJson(decoded.cast<String, dynamic>());
    } catch (e, st) {
      Log.w('Clips', 'failed to read clips_state.json', e, st);
      return null;
    }
  }
}
