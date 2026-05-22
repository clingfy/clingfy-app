import CoreGraphics
import Foundation

/// Catalog of procedural-background presets + their color palettes.
///
/// Palettes are plain ARGB color lists; the renderers consume them as
/// gradient stops + wave fills. Adding a palette or a preset here is the
/// only data change needed to expand the catalog (Phase 5). Catalog data
/// is shared by the native renderers and surfaced to Flutter for the
/// preset-picker UI.
enum BackgroundPresetCatalog {

  /// An ordered set of colors driving one procedural background. The first
  /// colors anchor the base gradient; later colors tint the wave layers.
  struct Palette: Equatable {
    let id: String
    let colorsArgb: [Int]
  }

  static let defaultPaletteId = "bluePurple"

  /// All available palettes. Original "macOS-inspired" abstract sets —
  /// deliberately not copies of any system wallpaper.
  static let palettes: [Palette] = [
    Palette(
      id: "bluePurple",
      colorsArgb: [0xFF1B1E3D, 0xFF3B2E78, 0xFF6C4AB6, 0xFF8D72E1, 0xFFB9A7F2]),
    Palette(
      id: "sunset",
      colorsArgb: [0xFF2A1633, 0xFF7A2E5D, 0xFFC94B6B, 0xFFF2785C, 0xFFF7B267]),
    Palette(
      id: "aurora",
      colorsArgb: [0xFF06243B, 0xFF0E5C63, 0xFF1E9E8A, 0xFF4FD1A5, 0xFFA7F0BA]),
    Palette(
      id: "forest",
      colorsArgb: [0xFF10241C, 0xFF1F4D3A, 0xFF2F7D5B, 0xFF5DA47C, 0xFF9CC9A8]),
    Palette(
      id: "mono",
      colorsArgb: [0xFF15171A, 0xFF272B30, 0xFF3C424A, 0xFF5A626C, 0xFF7E8893]),
  ]

  /// Preset ids the renderer dispatch recognizes. Phase 2 ships
  /// `abstractWaves`; later phases append more.
  static let presetIds = ["abstractWaves"]

  /// Returns the palette with `id`, or the default palette when unknown.
  static func palette(_ id: String) -> Palette {
    palettes.first { $0.id == id }
      ?? palettes.first { $0.id == defaultPaletteId }
      ?? palettes[0]
  }
}
