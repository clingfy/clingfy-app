import CoreGraphics
import Foundation

/// Renders a procedural preset background to a `CGImage`.
///
/// Concrete renderers are deterministic: the same `CanvasBackgroundPreset`
/// (id + palette + intensity + blur + seed) and the same pixel size always
/// produce the same image — so the live preview and the export render
/// identical results (at their respective sizes).
protocol CanvasBackgroundRendering {
  /// Renders the preset at `pixelSize` (already in device pixels — the
  /// caller passes preview-canvas size for preview, full output size for
  /// export). Returns `nil` only on allocation failure.
  func render(preset: CanvasBackgroundPreset, pixelSize: CGSize) -> CGImage?
}

/// Shared entry point for preset-background rendering. Dispatches to the
/// renderer for `preset.id` and memoizes results.
///
/// Thread-safe: the only stored state is an `NSCache` (itself thread-safe)
/// and stateless renderer instances, so `shared` is safe to call from the
/// main-actor preview path and from the export's background render queue.
final class CanvasBackgroundRenderer {

  static let shared = CanvasBackgroundRenderer()

  private let cache = NSCache<NSString, CGImage>()
  private let wavesRenderer = AbstractWavesBackgroundRenderer()

  /// Returns the rendered background for `preset` at `pixelSize`, using a
  /// memoized result when one exists. The cache key includes every input
  /// that affects the pixels, so distinct presets/sizes never collide.
  func image(for preset: CanvasBackgroundPreset, pixelSize: CGSize) -> CGImage? {
    let width = Int(pixelSize.width.rounded())
    let height = Int(pixelSize.height.rounded())
    guard width >= 1, height >= 1 else { return nil }

    let key =
      "\(preset.id)|\(preset.palette)|\(preset.intensity)|\(preset.blur)|\(preset.seed)|\(width)x\(height)"
      as NSString
    if let cached = cache.object(forKey: key) {
      return cached
    }

    let renderer = renderer(for: preset.id)
    guard
      let image = renderer.render(
        preset: preset, pixelSize: CGSize(width: width, height: height))
    else {
      return nil
    }
    cache.setObject(image, forKey: key)
    return image
  }

  /// Maps a preset id to its renderer. Unknown ids fall back to the
  /// abstract-waves renderer so a stale/typo'd id still produces a
  /// reasonable background rather than nothing.
  private func renderer(for id: String) -> CanvasBackgroundRendering {
    switch id {
    case "abstractWaves":
      return wavesRenderer
    default:
      return wavesRenderer
    }
  }
}
