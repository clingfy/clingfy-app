import Foundation

/// Canvas background model — the post-processing canvas renders one of three
/// background kinds:
///   - `.color`  — a solid ARGB color (`colorArgb`; `nil` ⇒ black, the
///     historical default).
///   - `.image`  — a user-picked image file (`imagePath`).
///   - `.preset` — a procedural "Graphic / Abstract Waves" background
///     generated from a `CanvasBackgroundPreset` (palette + intensity +
///     blur + seed). Resolution-independent; rendered identically in the
///     live preview and the export.
///
/// Wire contract: the existing `backgroundColor` / `backgroundImagePath`
/// method-channel keys are unchanged. Preset adds `backgroundKind`,
/// `backgroundPresetId`, `backgroundPresetPalette`,
/// `backgroundPresetIntensity`, `backgroundPresetBlur`,
/// `backgroundPresetSeed`. `from(args:)` is back-compatible: when
/// `backgroundKind` is absent (old Flutter payloads) it infers the kind.
///
/// Engine-domain value type; see `windows-port-inventory.md` §7.
enum CanvasBackgroundKind: String, Codable, Equatable {
  case color
  case image
  case preset
}

/// Parameters for a procedural preset background. Deterministic: the same
/// `(id, palette, intensity, blur, seed)` always renders the same image.
struct CanvasBackgroundPreset: Codable, Equatable {
  /// Catalog id, e.g. `"abstractWaves"`.
  let id: String
  /// Named palette, e.g. `"bluePurple"`.
  let palette: String
  /// Visual strength of the generated detail, clamped to `0...1`.
  let intensity: Double
  /// Softness / blur of the generated detail, clamped to `0...1`.
  let blur: Double
  /// Deterministic randomization seed.
  let seed: Int

  static let defaultIntensity = 0.7
  static let defaultBlur = 0.35

  init(id: String, palette: String, intensity: Double, blur: Double, seed: Int) {
    self.id = id
    self.palette = palette
    self.intensity = min(max(intensity, 0.0), 1.0)
    self.blur = min(max(blur, 0.0), 1.0)
    self.seed = seed
  }

  /// Parses a preset from `processVideo` / `exportVideo` channel args.
  /// Returns `nil` when no `backgroundPresetId` is present.
  static func from(args: [String: Any]?) -> CanvasBackgroundPreset? {
    guard
      let id = args?["backgroundPresetId"] as? String,
      !id.isEmpty
    else {
      return nil
    }
    return CanvasBackgroundPreset(
      id: id,
      palette: (args?["backgroundPresetPalette"] as? String) ?? "default",
      intensity: (args?["backgroundPresetIntensity"] as? Double) ?? defaultIntensity,
      blur: (args?["backgroundPresetBlur"] as? Double) ?? defaultBlur,
      seed: (args?["backgroundPresetSeed"] as? Int) ?? 0
    )
  }
}

/// A fully resolved canvas background. `kind` is the source of truth for
/// which of `colorArgb` / `imagePath` / `preset` the renderer should use.
struct CanvasBackground: Codable, Equatable {
  let kind: CanvasBackgroundKind
  let colorArgb: Int?
  let imagePath: String?
  let preset: CanvasBackgroundPreset?

  /// The historical default — a solid color background with no color set,
  /// which every renderer treats as black.
  static let `default` = CanvasBackground(
    kind: .color, colorArgb: nil, imagePath: nil, preset: nil)

  /// Resolves a `CanvasBackground` from already-parsed pieces. Back-
  /// compatible: if `kindRaw` is absent/unrecognized the kind is inferred
  /// (preset ▸ image ▸ color), reproducing the pre-preset behavior where
  /// the kind was implicit in which field was non-nil. The explicit kind
  /// is honored only when the data it needs is present (defensive against
  /// stale payloads).
  static func resolve(
    kindRaw: String?,
    colorArgb: Int?,
    imagePath: String?,
    preset: CanvasBackgroundPreset?
  ) -> CanvasBackground {
    let normalizedImagePath = imagePath.flatMap { $0.isEmpty ? nil : $0 }
    let explicitKind = kindRaw.flatMap(CanvasBackgroundKind.init(rawValue:))
    let inferredKind: CanvasBackgroundKind = {
      if preset != nil { return .preset }
      if normalizedImagePath != nil { return .image }
      return .color
    }()
    let kind: CanvasBackgroundKind = {
      switch explicitKind {
      case .preset where preset != nil: return .preset
      case .image where normalizedImagePath != nil: return .image
      case .color: return .color
      default: return inferredKind
      }
    }()
    return CanvasBackground(
      kind: kind, colorArgb: colorArgb, imagePath: normalizedImagePath, preset: preset)
  }

  /// Resolves a `CanvasBackground` directly from `processVideo` /
  /// `exportVideo` channel args.
  static func from(args: [String: Any]?) -> CanvasBackground {
    resolve(
      kindRaw: args?["backgroundKind"] as? String,
      colorArgb: args?["backgroundColor"] as? Int,
      imagePath: args?["backgroundImagePath"] as? String,
      preset: CanvasBackgroundPreset.from(args: args))
  }
}
