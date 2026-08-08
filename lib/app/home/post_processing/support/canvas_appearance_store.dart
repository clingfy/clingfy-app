import 'dart:convert';
import 'dart:io';

import 'package:clingfy/core/logging/logger_service.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/timeline/model/color_grade.dart';

/// Persisted per-recording canvas appearance — the post-processing canvas
/// edits that previously reset every time a recording was reopened
/// (padding, corner radius, background color/image/preset).
///
/// Stored as `editor_state.json` inside the recording's `.clingfyproj`
/// bundle. This is editor UI state, not capture metadata, so it lives
/// separate from `RecordingMetadata` (whose `editorSeed` remains the
/// immutable start-time defaults seed).
///
/// Layout / resolution / fit are intentionally NOT persisted here — they
/// are already global app settings (`SettingsController.post`) and do not
/// reset on reopen; making them per-project would be a separate behavior
/// change.
///
/// The color grade (auto-enhance + exposure/contrast/saturation/temperature/
/// tint) rides along in the same file — it is per-project editor state just
/// like the canvas, so it persists and restores together. Clips (split / cut /
/// trim / reorder) persist separately in `clips_state.json` because that model
/// lives in `lib/core` and cannot depend on this `lib/app` store.
class CanvasAppearanceState {
  const CanvasAppearanceState({
    required this.padding,
    required this.cornerRadius,
    required this.backgroundKind,
    required this.backgroundColorArgb,
    required this.backgroundImagePath,
    required this.backgroundPreset,
    this.colorGrade = const ColorGrade(),
  });

  /// Bump when the on-disk shape changes incompatibly. v2 added [colorGrade];
  /// a v1 file (no `colorGrade` key) still reads cleanly and falls back to the
  /// neutral grade, so older recordings keep working.
  static const int version = 2;

  final double padding;
  final double cornerRadius;
  final BackgroundKind backgroundKind;
  final int? backgroundColorArgb;
  final String? backgroundImagePath;
  final CanvasBackgroundPreset? backgroundPreset;
  final ColorGrade colorGrade;

  Map<String, dynamic> toJson() => {
    'version': version,
    'padding': padding,
    'cornerRadius': cornerRadius,
    'background': {
      'kind': backgroundKind.name,
      'colorArgb': backgroundColorArgb,
      'imagePath': backgroundImagePath,
      'preset': backgroundPreset?.toJson(),
    },
    'colorGrade': colorGrade.toMap(),
  };

  /// Parses persisted state. Returns `null` for any malformed/old payload
  /// so the caller falls back to defaults — keeps old recordings working.
  static CanvasAppearanceState? fromJson(Map<String, dynamic> json) {
    final bg = json['background'];
    if (bg is! Map) return null;
    final bgMap = bg.cast<String, dynamic>();
    final kind = BackgroundKind.values.firstWhere(
      (k) => k.name == bgMap['kind'],
      orElse: () => BackgroundKind.color,
    );
    final grade = json['colorGrade'];
    return CanvasAppearanceState(
      padding: (json['padding'] as num?)?.toDouble() ?? 0.0,
      cornerRadius: (json['cornerRadius'] as num?)?.toDouble() ?? 0.0,
      backgroundKind: kind,
      backgroundColorArgb: (bgMap['colorArgb'] as num?)?.toInt(),
      backgroundImagePath: bgMap['imagePath'] is String
          ? bgMap['imagePath'] as String
          : null,
      backgroundPreset: CanvasBackgroundPreset.fromJson(
        (bgMap['preset'] as Map?)?.cast<String, dynamic>(),
      ),
      colorGrade: grade is Map ? ColorGrade.fromMap(grade) : const ColorGrade(),
    );
  }
}

/// Reads/writes [CanvasAppearanceState] as `editor_state.json` inside a
/// recording project bundle. All I/O is best-effort: a failure logs and
/// is swallowed — persistence must never break editing or playback.
abstract final class CanvasAppearanceStore {
  static const String _fileName = 'editor_state.json';

  static File _file(String projectPath) => File(
    '${_normalizeBundlePath(projectPath)}'
    '${Platform.pathSeparator}$_fileName',
  );

  /// Trims trailing separators.
  ///
  /// The write-queue comment below claims two spellings of a bundle share one
  /// queue. Without this they do not: `absolute.path` leaves a doubled
  /// separator in place and `Uri.normalizePath` does not collapse it, so
  /// `<bundle>` and `<bundle>/` key two chains that race on one file.
  static String _normalizeBundlePath(String projectPath) {
    var end = projectPath.length;
    while (end > 1 &&
        (projectPath[end - 1] == Platform.pathSeparator ||
            projectPath[end - 1] == '/')) {
      end--;
    }
    return projectPath.substring(0, end);
  }

  // Callers fire-and-forget these writes (`unawaited`), and a single user
  // action can produce two in the same turn — e.g. committing a color edit and
  // the canvas resync that follows it. `writeAsString` opens truncating with no
  // cross-call serialization, so two overlapping saves can interleave and leave
  // a short payload followed by the tail of a longer one: unparseable JSON, and
  // `load` then discards EVERY persisted setting for that recording, not just
  // the grade. Chaining per project path makes the last writer win intact.
  //
  // Keyed on the resolved file path rather than the caller's string, so two
  // spellings of the same bundle (trailing separator, relative vs absolute)
  // share one queue instead of racing on the same file through two chains.
  static final Map<String, Future<void>> _writeQueues =
      <String, Future<void>>{};

  static Future<void> save(String projectPath, CanvasAppearanceState state) {
    final key = _file(projectPath).absolute.path;
    // `.then` with an onError arm, not a bare `.then`: a link that somehow
    // rejects must not skip every write queued behind it.
    final queued = (_writeQueues[key] ?? Future<void>.value()).then(
      (_) => _write(projectPath, state),
      onError: (Object _) => _write(projectPath, state),
    );
    _writeQueues[key] = queued;
    return queued.whenComplete(() {
      // Drop the entry once this write is the last one queued, so the map does
      // not grow one permanent entry per recording ever opened.
      if (identical(_writeQueues[key], queued)) {
        _writeQueues.remove(key);
      }
    });
  }

  static Future<void> _write(
    String projectPath,
    CanvasAppearanceState state,
  ) async {
    try {
      const encoder = JsonEncoder.withIndent('  ');
      await _file(projectPath).writeAsString(encoder.convert(state.toJson()));
    } catch (e, st) {
      Log.w('PostProcessing', 'Failed to persist canvas appearance: $e', e, st);
    }
  }

  /// Synchronous so a project open does not add an extra async hop to the
  /// scene-load path. The file is tiny and read exactly once per open.
  static CanvasAppearanceState? load(String projectPath) {
    try {
      final file = _file(projectPath);
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return null;
      return CanvasAppearanceState.fromJson(decoded.cast<String, dynamic>());
    } catch (e, st) {
      Log.w('PostProcessing', 'Failed to read canvas appearance: $e', e, st);
      return null;
    }
  }
}
