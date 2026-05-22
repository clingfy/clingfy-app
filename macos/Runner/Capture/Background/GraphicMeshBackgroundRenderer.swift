import CoreGraphics
import CoreImage
import Foundation

/// Procedural renderer for the `graphicMesh` preset — a soft "mesh
/// gradient": several large overlapping radial color blobs (one per
/// palette color, scattered) blended over a base fill. The on-trend
/// macOS-"Graphic"-style look, generated from scratch.
///
/// Deterministic: a `SeededGenerator` keyed off `preset.seed` drives every
/// blob position / radius. `intensity` scales blob strength; `blur` adds
/// optional extra softening on top of the already-soft radial blobs.
struct GraphicMeshBackgroundRenderer: CanvasBackgroundRendering {

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

    // Base fill — the darkest (first) palette color.
    ctx.setFillColor(colors[0])
    ctx.fill(bounds)

    // Mesh blobs: at least one per color, scattered, large + soft.
    let blobCount = max(6, colors.count + 2)
    for index in 0..<blobCount {
      let color = colors[(index + 1) % colors.count]
      let center = CGPoint(
        x: bounds.width * CGFloat(rng.double(-0.1, 1.1)),
        y: bounds.height * CGFloat(rng.double(-0.1, 1.1)))
      let radius = minDim * CGFloat(rng.double(0.45, 0.95))
      let alpha = 0.40 + 0.45 * intensity
      let inner = color.copy(alpha: min(alpha, 0.95)) ?? color
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
