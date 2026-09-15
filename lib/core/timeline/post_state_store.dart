import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clingfy/core/captions/caption_state_store.dart';
import 'package:clingfy/core/clips/clip_state_store.dart';
import 'package:clingfy/core/logging/logger_service.dart';
import 'package:clingfy/core/timeline/codec/timeline_codec.dart';
import 'package:clingfy/core/timeline/model/canvas_state.dart';
import 'package:clingfy/core/timeline/model/color_grade.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:clingfy/core/timeline/model/timeline.dart';

/// The one durable editor state for a recording: `post/state.json`.
///
/// Replaces three files that each invented their own envelope and version —
/// `clips_state.json`, `captions_state.json` and `editor_state.json`. The
/// manifest has pointed at `post/state.json` since the bundle format was
/// defined and both recorders reserve the slot; nothing had ever written it.
///
/// ## Migrating an existing project
///
/// [load] prefers `post/state.json`. When it is absent it composes a timeline
/// from whichever legacy files exist and returns that, so a project made by
/// 1.0.5 through the caption release opens with every edit intact. The legacy
/// files are only removed by [save], and only after the unified file is safely
/// on disk — see [save] for why that ordering is the whole safety argument.
abstract final class PostStateStore {
  static const String _fileName = 'state.json';
  static const TimelineCodec _codec = TimelineCodec();

  /// Serializes writes per bundle. Two spellings of one path must share a
  /// queue, hence the normalization — otherwise `<bundle>` and `<bundle>/` key
  /// two chains that race on the same file.
  static final Map<String, Future<void>> _writeQueues = {};

  /// Bundles whose legacy files have already been dealt with this session.
  ///
  /// Retirement is a one-time act, but saves are not: a clip drag commits
  /// repeatedly and captions persist on every correction. Re-checking three
  /// paths for existence and deleting on each of those writes is pure I/O on
  /// the edit path, which is exactly where it must not be.
  static final Set<String> _retired = {};

  static String _bundlePath(String projectPath) {
    var end = projectPath.length;
    while (end > 1 &&
        (projectPath[end - 1] == Platform.pathSeparator ||
            projectPath[end - 1] == '/')) {
      end--;
    }
    return projectPath.substring(0, end);
  }

  static Directory _postDir(String projectPath) =>
      Directory('${_bundlePath(projectPath)}${Platform.pathSeparator}post');

  static File file(String projectPath) =>
      File('${_postDir(projectPath).path}${Platform.pathSeparator}$_fileName');

  static File _legacyFile(String projectPath, String name) =>
      File('${_bundlePath(projectPath)}${Platform.pathSeparator}$name');

  /// Reads the unified state, falling back to the legacy trio.
  ///
  /// Never throws: a malformed or unreadable file yields whatever could be
  /// recovered, because refusing to open a project is worse than opening it
  /// with defaults.
  static Timeline load(String projectPath) {
    final unified = file(projectPath);
    try {
      if (unified.existsSync()) {
        final raw = unified.readAsStringSync().trim();
        // Both recorders pre-create the slot with `{}`; that is "not migrated
        // yet", not "an empty timeline the user asked for".
        if (raw.isNotEmpty && raw != '{}') {
          return _codec.decodeJson(raw);
        }
      }
    } catch (e, st) {
      Log.w('PostState', 'failed to read post/state.json', e, st);
    }
    return _loadLegacy(projectPath);
  }

  /// True when this project still has to be migrated. Only meaningful for
  /// tests and diagnostics; [load] handles both cases on its own.
  static bool needsMigration(String projectPath) {
    final unified = file(projectPath);
    if (!unified.existsSync()) return true;
    try {
      final raw = unified.readAsStringSync().trim();
      return raw.isEmpty || raw == '{}';
    } catch (_) {
      return true;
    }
  }

  /// Completes once every queued write has finished.
  ///
  /// Saves are fire-and-forget so an edit is never blocked by the disk, which
  /// leaves writes in flight at moments that care: a test tearing down its temp
  /// bundle (deleting a tree while this recreates `post/` inside it fails with
  /// ENOTEMPTY), and app shutdown, where the last edit should reach the disk.
  static Future<void> settled() async {
    // A pending write can queue another, so drain until the map stops changing
    // rather than awaiting one snapshot of it.
    for (var i = 0; i < 5 && _writeQueues.isNotEmpty; i++) {
      await Future.wait(_writeQueues.values.toList());
    }
  }

  /// Whether this project has canvas/grade state on disk at all.
  ///
  /// The canvas restore must not run when there is nothing to restore: it
  /// clears the colour history, and an edit made during the asynchronous
  /// scene-load window would be thrown away by a "restore" of pure defaults.
  /// The store it replaced expressed this by returning null for a missing file.
  static bool hasStoredCanvas(String projectPath) {
    if (!needsMigration(projectPath)) return true;
    return _legacyFile(projectPath, 'editor_state.json').existsSync();
  }

  static Timeline _loadLegacy(String projectPath) {
    final tracks = <EditTrack>[];

    final clips = ClipStateStore.load(projectPath);
    if (clips != null && clips.clips.isNotEmpty) {
      tracks.add(ClipTrack(clips: clips.clips));
    }

    final captions = CaptionStateStore.load(projectPath);
    if (captions != null && captions.captions.isNotEmpty) {
      tracks.add(CaptionTrack(captions: captions.captions));
    }

    var canvas = const CanvasState();
    var grade = const ColorGrade();
    final editorState = _readLegacyEditorState(projectPath);
    if (editorState != null) {
      canvas = CanvasState.fromMap(editorState);
      final rawGrade = editorState['colorGrade'];
      if (rawGrade is Map) grade = ColorGrade.fromMap(rawGrade);
    }

    return Timeline(tracks: tracks, grade: grade, canvas: canvas);
  }

  /// `editor_state.json` is parsed here rather than through the `lib/app`
  /// store that used to own it: `lib/core` cannot import `lib/app`, and the
  /// shape is plain JSON whose types were always core.
  static Map<String, dynamic>? _readLegacyEditorState(String projectPath) {
    try {
      final f = _legacyFile(projectPath, 'editor_state.json');
      if (!f.existsSync()) return null;
      final decoded = jsonDecode(f.readAsStringSync());
      if (decoded is! Map) return null;
      return decoded.cast<String, dynamic>();
    } catch (e, st) {
      Log.w('PostState', 'failed to read legacy editor_state.json', e, st);
      return null;
    }
  }

  /// Writes the unified state, then retires the legacy files.
  ///
  /// The order is the safety argument, and it is worth stating plainly: the new
  /// file is written to a temp sibling and renamed into place, so a crash
  /// leaves either the old content or the new content and never a truncated
  /// file. Only once that rename has returned are the legacy files deleted.
  ///
  /// They are deleted rather than left behind because [load] falls back to them
  /// whenever the unified file is missing or unreadable. Leaving stale copies
  /// would mean one failed write silently reverts the project to whatever those
  /// files last held — the user's edits would vanish with nothing logged.
  static Future<void> save(String projectPath, Timeline timeline) =>
      update(projectPath, (_) => timeline);

  /// Read, modify, write — with the READ inside the same queue as the write.
  ///
  /// This is the API the three editors must use, and the reason it exists is
  /// the one hazard unification introduces. Clips, captions and canvas are
  /// written by independent controllers that now share a file. If each did
  /// `load()` then `save()`, two edits landing together would both read the
  /// same state and the second write would drop the first — a user trims a clip
  /// and corrects a cue in the same second, and one of them silently reverts.
  /// Doing the read here means every mutation sees the previous one's result.
  static Future<void> update(
    String projectPath,
    Timeline Function(Timeline current) mutate,
  ) {
    final key = _bundlePath(projectPath);
    Future<void> run() async {
      final Timeline next;
      try {
        next = mutate(load(projectPath));
      } catch (e, st) {
        Log.w(
          'PostState',
          'caption/clip/canvas mutation threw; state left as-is',
          e,
          st,
        );
        return;
      }
      await _write(projectPath, next);
    }

    final queued = (_writeQueues[key] ?? Future<void>.value()).then(
      (_) => run(),
      onError: (Object _) => run(),
    );
    _writeQueues[key] = queued;
    queued.whenComplete(() {
      if (identical(_writeQueues[key], queued)) _writeQueues.remove(key);
    });
    return queued;
  }

  static Future<void> _write(String projectPath, Timeline timeline) async {
    final target = file(projectPath);
    try {
      // Write into an existing bundle only. A store must not conjure a project
      // directory at an arbitrary path: if the bundle is gone (deleted while
      // open, or an unmounted volume) the honest outcome is "the save did not
      // happen", not a new tree of state somewhere the user has no project.
      // `post/` itself is ours to create — a recording with no captions and no
      // edits has never needed one.
      if (!Directory(_bundlePath(projectPath)).existsSync()) {
        Log.w(
          'PostState',
          'skipped writing post/state.json: the project bundle is not there',
        );
        return;
      }
      await _postDir(projectPath).create(recursive: true);
      final temp = File('${target.path}.tmp');
      await temp.writeAsString(_codec.encodeJson(timeline), flush: true);
      await temp.rename(target.path);
    } catch (e, st) {
      Log.w('PostState', 'failed to write post/state.json', e, st);
      // Leave the legacy files alone: they are now the only surviving copy.
      return;
    }
    final key = _bundlePath(projectPath);
    if (_retired.add(key)) await _retireLegacyFiles(projectPath);
  }

  static Future<void> _retireLegacyFiles(String projectPath) async {
    for (final name in const [
      'clips_state.json',
      'captions_state.json',
      'editor_state.json',
    ]) {
      try {
        final f = _legacyFile(projectPath, name);
        if (await f.exists()) await f.delete();
      } catch (e, st) {
        // Best effort. A leftover is harmless now that the unified file exists
        // and load() prefers it.
        Log.w('PostState', 'failed to retire $name', e, st);
      }
    }
  }
}
