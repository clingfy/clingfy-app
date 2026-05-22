import CoreGraphics
import CoreImage
import Foundation

/// Procedural renderer for the `radialGlow` preset — a clean diagonal
/// gradient base lit by a few soft concentric glows. Calmer and more
/// minimal than `abstractWaves` / `graphicMesh`.
///
/// Deterministic: a `SeededGenerator` keyed off `preset.seed` drives the
/// glow positions / radii. `intensity` scales glow brightness; `blur` adds
/// optional softening.
struct RadialGlowBackgroundRenderer: CanvasBackgroundRendering {

  func render(preset: CanvasBackgroundPreset, pixelSize: CGSize) -> CGImage? {
    let width = Int(pixelSize.width.rounded())
    let height = Int(pixelSize.height.rounded())
    guard width >= 1, height >= 1 else { return nil }

    let colorSpace = VideoColorPipeline.workingColorSpace
    guard
      let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: 0, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue)
    else {
      return nil
    }

    var rng = SeededGenerator(seed: preset.seed)
    let colors = BackgroundPresetCatalog.palette(preset.palette).colorsArgb
      .map { VideoColorPipeline.cgColor(fromARGB: $0) }
    guard !colors.isEmpty else { return nil }

    let bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
    let intensity = CGFloat(min(max(preset.intensity, 0.0), 1.0))
    let minDim = min(bounds.width, bounds.height)

    // Base diagonal gradient across the full palette.
    let locations: [CGFloat] = (0..<colors.count).map {
      colors.count <= 1 ? 0.0 : CGFloat($0) / CGFloat(colors.count - 1)
    }
    if let gradient = CGGradient(
      colorsSpace: colorSpace, colors: colors as CFArray, locations: locations)
    {
      ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: bounds.minX, y: bounds.maxY),
        end: CGPoint(x: bounds.maxX, y: bounds.minY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    } else {
      ctx.setFillColor(colors[0])
      ctx.fill(bounds)
    }

    // A few soft glows using the lighter palette colors.
    let glowCount = 3
    for index in 0..<glowCount {
      let color = colors[colors.count - 1 - (index % colors.count)]
      let center = CGPoint(
        x: bounds.width * CGFloat(rng.double(0.15, 0.85)),
        y: bounds.height * CGFloat(rng.double(0.15, 0.85)))
      let radius = minDim * CGFloat(rng.double(0.4, 0.8))
      let alpha = 0.10 + 0.28 * intensity
      let inner = color.copy(alpha: alpha) ?? color
      let outer = color.copy(alpha: 0.0) ?? color
      guard
        let gradient = CGGradient(
          colorsSpace: colorSpace,
          colors: [inner, outer] as CFArray, locations: [0.0, 1.0])
      else {
        continue
      }
      ctx.drawRadialGradient(
        gradient, startCenter: center, startRadius: 0,
        endCenter: center, endRadius: radius, options: [])
    }

    guard let base = ctx.makeImage() else { return nil }

    let blur = CGFloat(min(max(preset.blur, 0.0), 1.0))
    guard blur > 0.001 else { return base }
    let sigma = Double(blur * minDim * 0.05)
    guard sigma > 0.5 else { return base }
    let ciImage = CIImage(cgImage: base)
      .clampedToExtent()
      .applyingGaussianBlur(sigma: sigma)
      .cropped(to: bounds)
    let context = CIContext(options: [.useSoftwareRenderer: false])
    return context.createCGImage(ciImage, from: bounds) ?? base
  }
}
