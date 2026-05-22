import CoreGraphics
import CoreImage
import Foundation

/// Procedural renderer for the `abstractWaves` preset — a soft, layered
/// "flowing waves over a gradient" background, in the spirit of macOS
/// "Graphic" wallpapers but generated from scratch (no copied artwork).
///
/// The image is built from:
///   1. a diagonal multi-stop base gradient (palette anchor colors),
///   2. several stacked wavy ribbons (palette tint colors, layered hills),
///   3. a couple of soft radial highlights,
///   4. an optional Gaussian-blur softening pass.
///
/// Fully deterministic: a `SeededGenerator` keyed by `preset.seed` drives
/// every random choice, so the same preset always renders the same image.
/// `intensity` scales the ribbon/highlight strength; `blur` scales the
/// softening pass.
struct AbstractWavesBackgroundRenderer: CanvasBackgroundRendering {

  func render(preset: CanvasBackgroundPreset, pixelSize: CGSize) -> CGImage? {
    let width = Int(pixelSize.width.rounded())
    let height = Int(pixelSize.height.rounded())
    guard width >= 1, height >= 1 else { return nil }

    let colorSpace = VideoColorPipeline.workingColorSpace
    guard
      let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue)
    else {
      return nil
    }

    var rng = SeededGenerator(seed: preset.seed)
    let palette = BackgroundPresetCatalog.palette(preset.palette)
    let colors = palette.colorsArgb.map { VideoColorPipeline.cgColor(fromARGB: $0) }
    guard !colors.isEmpty else { return nil }

    let bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
    let intensity = CGFloat(min(max(preset.intensity, 0.0), 1.0))

    drawBaseGradient(in: ctx, bounds: bounds, colors: colors, colorSpace: colorSpace, rng: &rng)
    drawWaveRibbons(
      in: ctx, bounds: bounds, colors: colors, intensity: intensity, rng: &rng)
    drawHighlights(
      in: ctx, bounds: bounds, colorSpace: colorSpace, intensity: intensity, rng: &rng)

    guard let base = ctx.makeImage() else { return nil }

    let blur = min(max(preset.blur, 0.0), 1.0)
    guard blur > 0.001 else { return base }
    return blurred(base, bounds: bounds, blur: CGFloat(blur)) ?? base
  }

  // MARK: - Base gradient

  private func drawBaseGradient(
    in ctx: CGContext,
    bounds: CGRect,
    colors: [CGColor],
    colorSpace: CGColorSpace,
    rng: inout SeededGenerator
  ) {
    let stops = colors.count
    let locations: [CGFloat] = (0..<stops).map {
      stops <= 1 ? 0.0 : CGFloat($0) / CGFloat(stops - 1)
    }
    guard
      let gradient = CGGradient(
        colorsSpace: colorSpace, colors: colors as CFArray, locations: locations)
    else {
      ctx.setFillColor(colors[0])
      ctx.fill(bounds)
      return
    }
    // Slightly tilted axis so the gradient reads as diagonal.
    let tilt = CGFloat(rng.double(-0.25, 0.25))
    let start = CGPoint(x: bounds.minX, y: bounds.maxY)
    let end = CGPoint(
      x: bounds.maxX, y: bounds.minY + bounds.height * tilt)
    ctx.drawLinearGradient(
      gradient, start: start, end: end,
      options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
  }

  // MARK: - Wave ribbons

  private func drawWaveRibbons(
    in ctx: CGContext,
    bounds: CGRect,
    colors: [CGColor],
    intensity: CGFloat,
    rng: inout SeededGenerator
  ) {
    let ribbonCount = 4
    // Draw back-to-front: highest baseline first so nearer ribbons overlap.
    for index in 0..<ribbonCount {
      let progress = CGFloat(index) / CGFloat(ribbonCount - 1)  // 0 (back) → 1 (front)
      let baselineFraction = 0.62 - 0.40 * progress
        + CGFloat(rng.double(-0.04, 0.04))
      let amplitudeFraction = CGFloat(rng.double(0.05, 0.12))
      let color = colors[(index + 1) % colors.count]
      let alpha = (0.22 + 0.30 * intensity) * (0.78 + 0.22 * progress)
      drawWaveRibbon(
        in: ctx,
        bounds: bounds,
        color: color.copy(alpha: min(alpha, 0.92)) ?? color,
        baselineFraction: baselineFraction,
        amplitudeFraction: amplitudeFraction,
        rng: &rng)
    }
  }

  private func drawWaveRibbon(
    in ctx: CGContext,
    bounds: CGRect,
    color: CGColor,
    baselineFraction: CGFloat,
    amplitudeFraction: CGFloat,
    rng: inout SeededGenerator
  ) {
    let w = bounds.width
    let h = bounds.height
    let baseline = h * baselineFraction
    let amplitude = h * amplitudeFraction
    let phaseA = CGFloat(rng.double(0, 2 * .pi))
    let phaseB = CGFloat(rng.double(0, 2 * .pi))
    let freqA = CGFloat(rng.double(1.1, 2.3))
    let freqB = CGFloat(rng.double(2.6, 4.6))

    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: 0))
    let steps = max(48, Int(w / 14))
    for i in 0...steps {
      let t = CGFloat(i) / CGFloat(steps)
      let x = t * w
      let wave =
        amplitude * 0.7 * sin(phaseA + t * freqA * 2 * .pi)
        + amplitude * 0.3 * sin(phaseB + t * freqB * 2 * .pi)
      path.addLine(to: CGPoint(x: x, y: baseline + wave))
    }
    path.addLine(to: CGPoint(x: w, y: 0))
    path.closeSubpath()

    ctx.addPath(path)
    ctx.setFillColor(color)
    ctx.fillPath()
  }

  // MARK: - Highlights

  private func drawHighlights(
    in ctx: CGContext,
    bounds: CGRect,
    colorSpace: CGColorSpace,
    intensity: CGFloat,
    rng: inout SeededGenerator
  ) {
    let glowCount = 2
    for _ in 0..<glowCount {
      let center = CGPoint(
        x: bounds.width * CGFloat(rng.double(0.15, 0.85)),
        y: bounds.height * CGFloat(rng.double(0.45, 0.95)))
      let radius = min(bounds.width, bounds.height) * CGFloat(rng.double(0.35, 0.65))
      let alpha = (0.06 + 0.14 * intensity)
      let inner = CGColor(
        srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: alpha)
      let outer = CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.0)
      guard
        let gradient = CGGradient(
          colorsSpace: colorSpace,
          colors: [inner, outer] as CFArray,
          locations: [0.0, 1.0])
      else {
        continue
      }
      ctx.drawRadialGradient(
        gradient,
        startCenter: center, startRadius: 0,
        endCenter: center, endRadius: radius,
        options: [])
    }
  }

  // MARK: - Blur

  private func blurred(_ image: CGImage, bounds: CGRect, blur: CGFloat) -> CGImage? {
    let sigma = blur * min(bounds.width, bounds.height) * 0.05
    guard sigma > 0.5 else { return image }
    let ciImage = CIImage(cgImage: image)
      .clampedToExtent()
      .applyingGaussianBlur(sigma: Double(sigma))
      .cropped(to: bounds)
    let context = CIContext(options: [.useSoftwareRenderer: false])
    return context.createCGImage(ciImage, from: bounds)
  }
}

/// Deterministic SplitMix64 generator — gives every preset `seed` a stable,
/// well-distributed random stream so renders are byte-reproducible.
struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64

  init(seed: Int) {
    state = UInt64(bitPattern: Int64(seed)) &+ 0x9E37_79B9_7F4A_7C15
  }

  mutating func next() -> UInt64 {
    state = state &+ 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  /// Uniform `Double` in `[lower, upper)`.
  mutating func double(_ lower: Double, _ upper: Double) -> Double {
    let unit = Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    return lower + unit * (upper - lower)
  }
}
