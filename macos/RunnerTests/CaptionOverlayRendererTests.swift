import CoreGraphics
import CoreImage
import ImageIO
import XCTest

@testable import Clingfy

/// Covers caption placement geometry and, more importantly, the render seat.
///
/// `testCaptionColourSurvivesThePostGradeSeat` and
/// `testCaptionColourIsDestroyedAtThePreGradeSeat` are a matched pair and must be
/// read together. The first asserts the shipped behaviour; the second asserts that
/// the *other* seat — the `AVVideoCompositionCoreAnimationTool` layer in
/// `CompositionBuilder` — visibly corrupts the authored colour. Without the second,
/// the first would pass at either seat and would prove nothing, which is exactly
/// the failure mode this repo has hit before with colour tolerances wider than the
/// defects they targeted.
///
/// Deliberate choices in the colour test, each one load-bearing:
/// - the grade is **exposure**, not saturation: white and greys are invariant under
///   `CIColorControls` saturation, so a saturation grade would pass at both seats
/// - the probe colour is **non-neutral and mid-range**: a neutral probe cannot
///   detect a hue shift, and a bright one clips under +EV and hides the difference
/// - the sample is decoded with `ColorTransferFunctions.exportTransferToSrgb`
///   before comparison, because the seat sits upstream of `encodeForExport`
final class CaptionOverlayRendererTests: XCTestCase {

  private var tempDirectory: URL!

  override func setUpWithError() throws {
    tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("caption-overlay-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: tempDirectory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let tempDirectory { try? FileManager.default.removeItem(at: tempDirectory) }
  }

  // MARK: - Placement geometry (pure, no disk)

  func testCentresHorizontally() {
    let placed = CaptionOverlayRenderer.placement(
      bitmapExtent: CGRect(x: 0, y: 0, width: 400, height: 80),
      in: CGRect(x: 0, y: 0, width: 1920, height: 1080),
      bottomMarginFraction: 0.08)
    XCTAssertEqual(placed.midX, 960, accuracy: 0.01)
    XCTAssertEqual(placed.width, 400, accuracy: 0.01)
  }

  /// Core Image's origin is bottom-left, so the margin is a direct `y` offset.
  /// Getting this backwards would put captions at the top of the video.
  func testBottomMarginIsAFractionOfCanvasHeightMeasuredFromTheBottom() {
    let placed = CaptionOverlayRenderer.placement(
      bitmapExtent: CGRect(x: 0, y: 0, width: 400, height: 80),
      in: CGRect(x: 0, y: 0, width: 1920, height: 1080),
      bottomMarginFraction: 0.10)
    XCTAssertEqual(placed.minY, 108, accuracy: 0.01, "10% of 1080, from the bottom")
    XCTAssertLessThan(placed.midY, 540, "must sit in the lower half, not the upper")
  }

  func testHonoursANonZeroCanvasOrigin() {
    let placed = CaptionOverlayRenderer.placement(
      bitmapExtent: CGRect(x: 0, y: 0, width: 100, height: 20),
      in: CGRect(x: 50, y: 30, width: 200, height: 100),
      bottomMarginFraction: 0.10)
    XCTAssertEqual(placed.minX, 100, accuracy: 0.01, "50 + (200-100)/2")
    XCTAssertEqual(placed.minY, 40, accuracy: 0.01, "30 + 10% of 100")
  }

  func testOversizedBitmapScalesDownPreservingAspectRatio() {
    let placed = CaptionOverlayRenderer.placement(
      bitmapExtent: CGRect(x: 0, y: 0, width: 3840, height: 200),
      in: CGRect(x: 0, y: 0, width: 1920, height: 1080),
      bottomMarginFraction: 0.08)
    XCTAssertEqual(placed.width, 1920, accuracy: 0.01)
    XCTAssertEqual(placed.height, 100, accuracy: 0.01, "aspect preserved")
    XCTAssertEqual(placed.minX, 0, accuracy: 0.01)
  }

  func testMarginFractionIsClampedToTheCanvas() {
    let low = CaptionOverlayRenderer.placement(
      bitmapExtent: CGRect(x: 0, y: 0, width: 10, height: 10),
      in: CGRect(x: 0, y: 0, width: 100, height: 100), bottomMarginFraction: -5)
    XCTAssertEqual(low.minY, 0, accuracy: 0.01)

    let high = CaptionOverlayRenderer.placement(
      bitmapExtent: CGRect(x: 0, y: 0, width: 10, height: 10),
      in: CGRect(x: 0, y: 0, width: 100, height: 100), bottomMarginFraction: 5)
    XCTAssertEqual(high.minY, 100, accuracy: 0.01)
  }

  func testDegenerateInputsReturnZeroRatherThanNaN() {
    XCTAssertEqual(
      CaptionOverlayRenderer.placement(
        bitmapExtent: .zero, in: CGRect(x: 0, y: 0, width: 100, height: 100),
        bottomMarginFraction: 0.1), .zero)
    XCTAssertEqual(
      CaptionOverlayRenderer.placement(
        bitmapExtent: CGRect(x: 0, y: 0, width: 10, height: 10), in: .zero,
        bottomMarginFraction: 0.1), .zero)
  }

  // MARK: - The seat (the load-bearing pair)

  /// A mid-range, non-neutral colour. Bright enough to be unambiguous, dark
  /// enough that +0.9 EV cannot clip it and hide the difference.
  private let probe = (r: 150, g: 80, b: 40)

  func testCaptionColourSurvivesThePostGradeSeat() throws {
    let measured = try renderProbe(compositeBeforeGrade: false)
    assertMatchesProbe(measured, tolerance: 6, context: "post-grade seat (shipped)")
  }

  /// The mutation check. Compositing at the pre-grade seat runs the user's grade
  /// over the caption too, so the authored colour cannot come out as authored.
  /// If this ever starts passing, the two seats have become equivalent and the
  /// test above has stopped meaning anything.
  func testCaptionColourIsDestroyedAtThePreGradeSeat() throws {
    let measured = try renderProbe(compositeBeforeGrade: true)
    let delta = channelDelta(measured)
    XCTAssertGreaterThan(
      delta, 20,
      """
      pre-grade compositing changed the caption by only \(delta) code values. \
      Either ColorGradeRenderer stopped affecting this probe, or the two seats \
      are now equivalent — in which case testCaptionColourSurvivesThePostGradeSeat \
      no longer discriminates and both tests need rewriting.
      """)
  }

  /// Renders a grey frame plus a caption bitmap through the real export tail
  /// (`ColorGradeRenderer.apply` then `renderComposedExportFrame`) and returns
  /// the caption's decoded sRGB colour.
  private func renderProbe(compositeBeforeGrade: Bool) throws -> (r: Int, g: Int, b: Int) {
    let canvas = CGRect(x: 0, y: 0, width: 320, height: 180)
    let bitmapName = "probe.png"
    try writeSolidPNG(
      to: tempDirectory.appendingPathComponent(bitmapName),
      size: CGSize(width: 160, height: 40),
      red: probe.r, green: probe.g, blue: probe.b)

    let cue = CaptionCueTrack.Cue(
      id: "probe", startMs: 0, endMs: 1000, bitmapName: bitmapName)
    let renderer = CaptionOverlayRenderer(bitmapDirectory: tempDirectory)

    // A mid grey stand-in for the composed frame arriving from the reader.
    let base = CIImage(color: CIColor(red: 0.35, green: 0.35, blue: 0.35))
      .cropped(to: canvas)
    // Exposure, not saturation: saturation leaves neutrals untouched, so a
    // saturation grade would make both seats agree and the pair would be vacuous.
    let grade = ColorGrade(
      autoEnabled: false, exposure: 0.6, contrast: 0, saturation: 0,
      temperature: 0, tint: 0)

    let composed: CIImage
    if compositeBeforeGrade {
      let withCaption = renderer.composite(
        base, cue: cue, renderBounds: canvas, bottomMarginFraction: 0.1)
      composed = ColorGradeRenderer.apply(withCaption, grade: grade)
    } else {
      let graded = ColorGradeRenderer.apply(base, grade: grade)
      composed = renderer.composite(
        graded, cue: cue, renderBounds: canvas, bottomMarginFraction: 0.1)
    }

    var bufferOut: CVPixelBuffer?
    CVPixelBufferCreate(
      kCFAllocatorDefault, Int(canvas.width), Int(canvas.height),
      kCVPixelFormatType_32BGRA,
      [
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
      ] as CFDictionary, &bufferOut)
    let buffer = try XCTUnwrap(bufferOut)

    VideoColorPipeline.renderComposedExportFrame(
      composed, to: buffer, bounds: canvas, using: VideoColorPipeline.makeCIContext())

    // Sample the middle of where the caption was placed.
    let placed = CaptionOverlayRenderer.placement(
      bitmapExtent: CGRect(x: 0, y: 0, width: 160, height: 40),
      in: canvas, bottomMarginFraction: 0.1)
    let stored = try samplePixel(
      in: buffer, x: Int(placed.midX),
      // CVPixelBuffer rows run top-down; Core Image y runs bottom-up.
      y: Int(canvas.height - placed.midY))

    // The seat is upstream of encodeForExport, so undo it before comparing.
    return (
      r: Int(ColorTransferFunctions.exportTransferToSrgb(stored.r)),
      g: Int(ColorTransferFunctions.exportTransferToSrgb(stored.g)),
      b: Int(ColorTransferFunctions.exportTransferToSrgb(stored.b))
    )
  }

  private func channelDelta(_ measured: (r: Int, g: Int, b: Int)) -> Int {
    max(
      abs(measured.r - probe.r),
      max(abs(measured.g - probe.g), abs(measured.b - probe.b)))
  }

  private func assertMatchesProbe(
    _ measured: (r: Int, g: Int, b: Int), tolerance: Int, context: String
  ) {
    let delta = channelDelta(measured)
    XCTAssertLessThanOrEqual(
      delta, tolerance,
      """
      \(context): authored rgb(\(probe.r), \(probe.g), \(probe.b)) but measured \
      rgb(\(measured.r), \(measured.g), \(measured.b)) after decoding the export \
      transfer — worst channel off by \(delta).
      """)
  }

  // MARK: - Robustness

  func testMissingBitmapLeavesTheFrameUntouchedAndIsRecorded() {
    let renderer = CaptionOverlayRenderer(bitmapDirectory: tempDirectory)
    let canvas = CGRect(x: 0, y: 0, width: 100, height: 100)
    let base = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: canvas)
    let cue = CaptionCueTrack.Cue(
      id: "gone", startMs: 0, endMs: 1000, bitmapName: "does-not-exist.png")

    let out = renderer.composite(
      base, cue: cue, renderBounds: canvas, bottomMarginFraction: 0.1)

    XCTAssertEqual(out.extent, base.extent, "frame passes through unchanged")
    XCTAssertEqual(renderer.missingBitmapCueIds, ["gone"])
  }

  /// A missing file must be remembered, not re-stat'd for all 18k frames of an
  /// export, and must not accumulate duplicate entries in the report.
  func testMissingBitmapIsRecordedOnceNotPerFrame() {
    let renderer = CaptionOverlayRenderer(bitmapDirectory: tempDirectory)
    let canvas = CGRect(x: 0, y: 0, width: 100, height: 100)
    let base = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: canvas)
    let cue = CaptionCueTrack.Cue(
      id: "gone", startMs: 0, endMs: 1000, bitmapName: "nope.png")

    for _ in 0..<50 {
      _ = renderer.composite(
        base, cue: cue, renderBounds: canvas, bottomMarginFraction: 0.1)
    }
    XCTAssertEqual(renderer.missingBitmapCueIds, ["gone"])
  }

  func testCompositingPlacesTheBitmapWithoutChangingFrameBounds() throws {
    try writeSolidPNG(
      to: tempDirectory.appendingPathComponent("c.png"),
      size: CGSize(width: 60, height: 20), red: 255, green: 0, blue: 0)
    let renderer = CaptionOverlayRenderer(bitmapDirectory: tempDirectory)
    let canvas = CGRect(x: 0, y: 0, width: 200, height: 120)
    let base = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: canvas)
    let cue = CaptionCueTrack.Cue(id: "c", startMs: 0, endMs: 1, bitmapName: "c.png")

    let out = renderer.composite(
      base, cue: cue, renderBounds: canvas, bottomMarginFraction: 0.1)
    XCTAssertEqual(out.extent, canvas, "compositing must not grow the frame")
  }

  func testResetDropsTheCachedBitmap() throws {
    try writeSolidPNG(
      to: tempDirectory.appendingPathComponent("c.png"),
      size: CGSize(width: 10, height: 10), red: 10, green: 20, blue: 30)
    let renderer = CaptionOverlayRenderer(bitmapDirectory: tempDirectory)
    let canvas = CGRect(x: 0, y: 0, width: 100, height: 100)
    let base = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: canvas)
    let cue = CaptionCueTrack.Cue(id: "c", startMs: 0, endMs: 1, bitmapName: "c.png")

    _ = renderer.composite(base, cue: cue, renderBounds: canvas, bottomMarginFraction: 0.1)
    renderer.reset()
    // Still correct after a reset — the bitmap is simply reloaded.
    let out = renderer.composite(
      base, cue: cue, renderBounds: canvas, bottomMarginFraction: 0.1)
    XCTAssertEqual(out.extent, canvas)
  }

  // MARK: - Helpers

  private func writeSolidPNG(
    to url: URL, size: CGSize, red: Int, green: Int, blue: Int
  ) throws {
    let width = Int(size.width)
    let height = Int(size.height)
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: 0, space: VideoColorPipeline.workingColorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(
      red: CGFloat(red) / 255.0, green: CGFloat(green) / 255.0,
      blue: CGFloat(blue) / 255.0, alpha: 1.0)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try XCTUnwrap(context.makeImage())

    // Raw UTI rather than `UTType.png`, which is macOS 11+ while this target
    // still deploys to 10.15.
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination), "failed to write \(url)")
  }

  private func samplePixel(
    in buffer: CVPixelBuffer, x: Int, y: Int
  ) throws -> (r: UInt8, g: UInt8, b: UInt8) {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    let clampedX = min(max(x, 0), CVPixelBufferGetWidth(buffer) - 1)
    let clampedY = min(max(y, 0), CVPixelBufferGetHeight(buffer) - 1)
    let pixel = base.advanced(by: clampedY * bytesPerRow + clampedX * 4)
      .assumingMemoryBound(to: UInt8.self)
    // 32BGRA, little-endian byte order: B G R A.
    return (r: pixel[2], g: pixel[1], b: pixel[0])
  }
}
