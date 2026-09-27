import 'dart:convert';
import 'dart:io';

/// What `post/state.json` actually holds right now, for a `waitUntil` that
/// timed out waiting for a write to land.
///
/// Pass it as `diagnose:`. It exists to settle #534, where a five-second wait
/// on a small write failed with nothing but the timeout — which cannot
/// distinguish the two causes, and they need opposite fixes:
///
///   * **a stall** — the file is there with an OLDER value, or a `.tmp`
///     sibling is still sitting beside it. The write started and has not
///     finished. Windows file I/O under load (Defender scanning freshly
///     created temp files) is the standing suspect. A real fix is about
///     contention, not correctness.
///   * **a lost write** — no file at all, or a bundle directory that is gone.
///     Something dropped or pre-empted the write. That is a bug in the store
///     or in a test tearing its own fixture down early.
///
/// Never throws: see `runTimeoutDiagnosis`. Reading a file another process
/// holds open throws on Windows, which is the platform this fires on.
String describePostStateOnDisk(String projectPath) {
  final parts = <String>[];

  final bundle = Directory(projectPath);
  if (!bundle.existsSync()) {
    return 'bundle $projectPath is GONE (nothing could have been written)';
  }

  final postDir = Directory('${bundle.path}${Platform.pathSeparator}post');
  if (!postDir.existsSync()) {
    parts.add('post/ MISSING');
  }

  final state = File('${postDir.path}${Platform.pathSeparator}state.json');
  if (!state.existsSync()) {
    parts.add('state.json ABSENT');
  } else {
    final stat = state.statSync();
    parts.add(
      'state.json ${stat.size}B '
      'mtime=${stat.modified.toIso8601String()} '
      '(${DateTime.now().difference(stat.modified).inMilliseconds}ms ago)',
    );
    parts.add('grade=${_gradeSummarySafe(state)}');
  }

  // A surviving temp sibling means the atomic write reached the file but not
  // the rename — the single most useful thing to know here, and invisible
  // from the loaded value alone.
  final temp = File('${state.path}.tmp');
  if (temp.existsSync()) {
    parts.add(
      'LEFTOVER ${state.path}.tmp (${temp.statSync().size}B) — the '
      'rename did not complete',
    );
  }

  // The store prefers post/state.json and falls back to these. If a test is
  // reading an unexpectedly old value, a legacy file is one way that happens.
  for (final name in const ['editor_state.json', 'clips_state.json']) {
    final legacy = File('${bundle.path}${Platform.pathSeparator}$name');
    if (legacy.existsSync()) {
      parts.add('legacy $name still present');
    }
  }

  return parts.join('; ');
}

/// [_gradeSummary], with a parse failure turned into a description instead of
/// an exception.
///
/// A corrupt file is a THIRD cause, distinct from both a stall and a lost
/// write, and it deserves to be named. Letting the throw escape would also
/// discard the size and mtime already gathered above — the fields that say
/// how far the write got.
String _gradeSummarySafe(File state) {
  try {
    return _gradeSummary(state);
  } catch (e) {
    return '<UNREADABLE: $e>';
  }
}

/// The grade fields a persistence test is usually waiting on, or why they
/// could not be read.
///
/// Reads the file directly rather than going through `PostStateStore.load`,
/// which never throws and falls back to defaults — exactly the behavior that
/// would turn "the file is corrupt" into "the value is wrong" and hide the
/// difference this whole helper exists to surface.
String _gradeSummary(File state) {
  final raw = state.readAsStringSync();
  if (raw.trim().isEmpty) {
    return '<file is EMPTY — written but not yet flushed>';
  }
  final dynamic decoded = jsonDecode(raw);
  if (decoded is! Map) return '<not a JSON object: ${raw.length} chars>';
  final dynamic grade = decoded['grade'];
  if (grade == null) return '<no "grade" key; keys=${decoded.keys.toList()}>';
  if (grade is! Map) return '<"grade" is ${grade.runtimeType}>';
  final wanted = ['exposure', 'contrast', 'saturation', 'temperature'];
  final shown = [
    for (final k in wanted)
      if (grade.containsKey(k)) '$k=${grade[k]}',
  ];
  return shown.isEmpty ? '<grade present but empty>' : shown.join(' ');
}
