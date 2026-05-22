import 'dart:convert';
import 'dart:io';

import 'package:clingfy/app/infrastructure/logging/logger_service.dart';
import 'package:clingfy/core/models/app_models.dart';

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
class CanvasAppearanceState {
  const CanvasAppearanceState({
    required this.padding,
    required this.cornerRadius,
    required this.backgroundKind,
    required this.backgroundColorArgb,
    required this.backgroundImagePath,
    required this.backgroundPreset,
  });

  /// Bump when the on-disk shape changes incompatibly.
  static const int version = 1;

  final double padding;
  final double cornerRadius;
  final BackgroundKind backgroundKind;
  final int? backgroundColorArgb;
  final String? backgroundImagePath;
  final CanvasBackgroundPreset? backgroundPreset;

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
    );
  }
}

/// Reads/writes [CanvasAppearanceState] as `editor_state.json` inside a
/// recording project bundle. All I/O is best-effort: a failure logs and
/// is swallowed — persistence must never break editing or playback.
abstract final class CanvasAppearanceStore {
  static const String _fileName = 'editor_state.json';

  static File _file(String projectPath) =>
      File('$projectPath${Platform.pathSeparator}$_fileName');

  static Future<void> save(
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
