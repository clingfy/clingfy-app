import 'package:clingfy/core/models/app_models.dart';

/// Flutter-side mirror of the native `BackgroundPresetCatalog`
/// (`macos/Runner/Capture/Background/BackgroundPresetCatalog.swift`).
///
/// The palette ARGB values MUST stay in sync with the native catalog — the
/// UI draws preset/palette thumbnails from these colors, and native renders
/// the actual background from the matching palette id. A drift would make
/// the picker thumbnail misrepresent the rendered result.
class BackgroundPalette {
  const BackgroundPalette({required this.id, required this.colors});

  final String id;

  /// Ordered ARGB colors — anchor colors first, wave-tint colors after.
  final List<int> colors;
}

abstract final class BackgroundPresetCatalog {
  static const String defaultPaletteId = 'bluePurple';

  /// Mirrors `BackgroundPresetCatalog.palettes` in Swift.
  static const List<BackgroundPalette> palettes = [
    BackgroundPalette(
      id: 'bluePurple',
      colors: [0xFF1B1E3D, 0xFF3B2E78, 0xFF6C4AB6, 0xFF8D72E1, 0xFFB9A7F2],
    ),
    BackgroundPalette(
      id: 'sunset',
      colors: [0xFF2A1633, 0xFF7A2E5D, 0xFFC94B6B, 0xFFF2785C, 0xFFF7B267],
    ),
    BackgroundPalette(
      id: 'aurora',
      colors: [0xFF06243B, 0xFF0E5C63, 0xFF1E9E8A, 0xFF4FD1A5, 0xFFA7F0BA],
    ),
    BackgroundPalette(
      id: 'forest',
      colors: [0xFF10241C, 0xFF1F4D3A, 0xFF2F7D5B, 0xFF5DA47C, 0xFF9CC9A8],
    ),
    BackgroundPalette(
      id: 'mono',
      colors: [0xFF15171A, 0xFF272B30, 0xFF3C424A, 0xFF5A626C, 0xFF7E8893],
    ),
  ];

  /// Preset ids the native renderer recognizes. Kept in sync with the
  /// native `BackgroundPresetCatalog.presetIds`.
  static const List<String> presetIds = [
    'abstractWaves',
    'graphicMesh',
    'radialGlow',
  ];

  static const double defaultIntensity = 0.7;
  static const double defaultBlur = 0.35;

  /// Returns the palette with [id], or the default palette when unknown.
  static BackgroundPalette palette(String id) {
    for (final p in palettes) {
      if (p.id == id) return p;
    }
    return palettes.firstWhere((p) => p.id == defaultPaletteId);
  }

  /// A fresh preset for [presetId] with default parameters — applied when
  /// the user first switches the background mode to "Preset".
  static CanvasBackgroundPreset defaultPreset({
    String presetId = 'abstractWaves',
  }) {
    return CanvasBackgroundPreset(
      id: presetId,
      palette: defaultPaletteId,
      intensity: defaultIntensity,
      blur: defaultBlur,
      seed: 1,
    );
  }
}
