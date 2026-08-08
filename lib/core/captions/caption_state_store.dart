import 'dart:convert';
import 'dart:io';

import 'package:clingfy/core/logging/logger_service.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:flutter/foundation.dart';

/// Persisted transcript for one recording, as `captions_state.json` inside the
/// `.clingfyproj` bundle.
///
/// Worth persisting where most editor state is not: a transcript costs minutes
/// of on-device compute and, once corrected, carries the user's own edits.
/// Losing it on close means paying for both again. It lives with the recording
/// rather than in preferences because it describes that recording's audio and
/// nothing else.
///
/// Separate from `editor_state.json` on purpose: that store lives in `lib/app`
/// and this model lives in `lib/core`, the same split that put clips in their
/// own file.
@immutable
class CaptionPersistState {
  const CaptionPersistState({required this.captions, this.language});

  /// Bump when the on-disk shape changes incompatibly.
  static const int version = 1;

  final List<Caption> captions;

  /// What was transcribed, when known. Recorded so a future translation pass
  /// knows the source language without re-detecting it.
  final String? language;

  Map<String, dynamic> toJson() => {
    'version': version,
    if (language != null) 'language': language,
    'captions': [for (final cue in captions) cue.toMap()],
  };

  /// Returns null for anything malformed, so a corrupt or newer file degrades
  /// to "no transcript yet" rather than half a transcript. A partially-restored
  /// track is worse than none: the user would see subtitles that silently stop
  /// partway and have no reason to suspect the file.
  static CaptionPersistState? fromJson(Map<String, dynamic> json) {
    final storedVersion = (json['version'] as num?)?.toInt();
    if (storedVersion == null || storedVersion > version) return null;

    final raw = json['captions'];
    if (raw is! List) return null;

    final captions = <Caption>[];
    for (final entry in raw) {
      if (entry is! Map) return null;
      final map = entry.cast<dynamic, dynamic>();
      // A cue with no id cannot be edited (the edit path addresses cues by id)
      // and one with no times cannot be placed, so a file containing either is
      // treated as corrupt rather than partially loaded.
      if (map['id'] is! String || (map['id'] as String).isEmpty) return null;
      if (map['startMs'] is! num || map['endMs'] is! num) return null;
      captions.add(Caption.fromMap(map));
    }

    return CaptionPersistState(
      captions: captions,
      language: json['language'] is String ? json['language'] as String : null,
    );
  }
}

/// Reads and writes [CaptionPersistState].
abstract final class CaptionStateStore {
  static const String _fileName = 'captions_state.json';

  static File _file(String projectPath) => File(
    '${_normalizeBundlePath(projectPath)}'
    '${Platform.pathSeparator}$_fileName',
  );

  /// Trims trailing separators so two spellings of the same bundle produce one
  /// path.
  ///
  /// `Uri.normalizePath` does NOT collapse a doubled separator, so without this
  /// `<bundle>` and `<bundle>/` yield different write-queue keys while naming
  /// the same file on disk — two chains racing on one file, which is exactly
  /// the interleaving the queue exists to prevent.
  static String _normalizeBundlePath(String projectPath) {
    var end = projectPath.length;
    while (end > 1 &&
        (projectPath[end - 1] == Platform.pathSeparator ||
            projectPath[end - 1] == '/')) {
      end--;
    }
    return projectPath.substring(0, end);
  }

  // Saves are fire-and-forget, and one user action can produce two in the same
  // turn — correcting a cue while a regeneration completes. `writeAsString`
  // truncates with no cross-call serialization, so two overlapping writes can
  // interleave into a short payload followed by the tail of a longer one:
  // unparseable JSON, and the whole transcript is then discarded on load.
  // Chaining per resolved path makes the last writer win intact.
  static final Map<String, Future<void>> _writeQueues =
      <String, Future<void>>{};

  static Future<void> save(String projectPath, CaptionPersistState state) {
    final key = _file(projectPath).absolute.path;
    // `.then` with an onError arm rather than a bare `.then`: a link that
    // rejects must not skip every write queued behind it.
    final queued = (_writeQueues[key] ?? Future<void>.value()).then(
      (_) => _write(projectPath, state),
      onError: (Object _) => _write(projectPath, state),
    );
    _writeQueues[key] = queued;
    return queued.whenComplete(() {
      if (identical(_writeQueues[key], queued)) {
        _writeQueues.remove(key);
      }
    });
  }

  static Future<void> _write(
    String projectPath,
    CaptionPersistState state,
  ) async {
    try {
      // An empty transcript deletes the file rather than writing an empty one.
      // "Never transcribed" and "transcribed and cleared" behave identically on
      // reopen, so keeping a file to represent the second is state nobody reads.
      final file = _file(projectPath);
      if (state.captions.isEmpty) {
        if (await file.exists()) await file.delete();
        return;
      }
      const encoder = JsonEncoder.withIndent('  ');
      await file.writeAsString(encoder.convert(state.toJson()));
    } catch (e, st) {
      Log.w('Captions', 'Failed to persist captions: $e', e, st);
    }
  }

  /// Synchronous so opening a project does not add an async hop to the
  /// scene-load path, matching how the canvas appearance is restored.
  static CaptionPersistState? load(String projectPath) {
    try {
      final file = _file(projectPath);
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return null;
      return CaptionPersistState.fromJson(decoded.cast<String, dynamic>());
    } catch (e, st) {
      Log.w('Captions', 'Failed to read captions: $e', e, st);
      return null;
    }
  }
}
