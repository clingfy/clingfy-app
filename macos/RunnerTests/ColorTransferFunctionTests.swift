import CoreImage
import XCTest

@testable import Clingfy

/// Tests the transfer function in isolation.
///
/// Every previous measurement in this investigation ran through colour
/// conversion, an RGB->YUV matrix, range mapping, chroma subsampling, H.264
/// quantization and a decode — six stages producing one number, which is how
/// three wrong conclusions survived long enough to be reported. This runs in
/// milliseconds and cannot be confounded.
final class ColorTransferFunctionTests: XCTestCase {

  /// Values computed from the published curves, not from any framework.
  private let reference: [(UInt8, UInt8)] = [
    (0, 0), (8, 3), (16, 6), (64, 48), (96, 81), (128, 115),
    (160, 150), (192, 185), (224, 220), (240, 238), (248, 247), (255, 255),
  ]

  func testMatchesThePublishedCurve() {
    for (input, expected) in reference {
      XCTAssertEqual(
        ColorTransferFunctions.srgbToBt709(input), expected,
        "sRGB \(input) should encode to 709 \(expected)")
    }
  }

  /// The property that would have caught every wrong result in this
  /// investigation on the first run: the 709 OETF is steeper than sRGB's, so
  /// a correct encode never raises a code value.
  func testEncodeNeverRaisesAValue() {
    for value in UInt8.min...UInt8.max {
      XCTAssertLessThanOrEqual(
        ColorTransferFunctions.srgbToBt709(value), value,
        "sRGB \(value) encoded UP — that is a decode, not an encode")
    }
  }

  func testEndpointsArePreserved() {
    XCTAssertEqual(ColorTransferFunctions.srgbToBt709(0), 0)
    XCTAssertEqual(ColorTransferFunctions.srgbToBt709(255), 255)
  }

  func testEncodeIsMonotonic() {
    var previous = ColorTransferFunctions.srgbToBt709(0)
    for value in 1...255 {
      let current = ColorTransferFunctions.srgbToBt709(UInt8(value))
      XCTAssertGreaterThanOrEqual(current, previous, "non-monotonic at \(value)")
      previous = current
    }
  }

  /// Round-trips within 8-bit rounding, which pins the two curves as genuine
  /// inverses rather than two independently plausible approximations.
  func testEncodeAndDecodeAreInverses() {
    for value in UInt8.min...UInt8.max {
      let round = ColorTransferFunctions.bt709ToSrgb(
        ColorTransferFunctions.srgbToBt709(value))
      XCTAssertLessThanOrEqual(
        abs(Int(round) - Int(value)), 2,
        "sRGB \(value) round-tripped to \(round)")
    }
  }

  func testTheLinearSegmentsAreUsedNearBlack() {
    // sRGB code 8 linearises to ~0.0024, below 709's 0.018 knee, so the 4.5x
    // linear segment applies — not the power curve. Getting this wrong is
    // invisible at midtone and obvious in shadows.
    XCTAssertEqual(ColorTransferFunctions.srgbToBt709(8), 3)
    XCTAssertEqual(ColorTransferFunctions.srgbToBt709(16), 6)
  }

  // MARK: - GPU parity

  /// A 256-wide ramp where column x holds code value x, authored in sRGB.
  ///
  /// Four rows tall and sampled down the middle so nothing in the pipeline can
  /// be resampling without the test noticing.
  private func makeCodeValueRamp() throws -> CGImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    var pixels = [UInt8](repeating: 0, count: 256 * 4 * 4)
    for y in 0..<4 {
      for x in 0..<256 {
        let offset = (y * 256 + x) * 4
        pixels[offset + 0] = UInt8(x)
        pixels[offset + 1] = UInt8(x)
        pixels[offset + 2] = UInt8(x)
        pixels[offset + 3] = 255
      }
    }
    let context = try XCTUnwrap(
      CGContext(
        data: &pixels, width: 256, height: 4, bitsPerComponent: 8, bytesPerRow: 256 * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    return try XCTUnwrap(context.makeImage())
  }

  /// Runs the ramp through the kernel on the GPU, using the SAME CIContext the
  /// export path builds, and reads the result back in sRGB.
  private func renderRampThroughKernel() throws -> [UInt8] {
    let ramp = try makeCodeValueRamp()
    let encoded = ColorTransferFunctions.encodeToBt709(CIImage(cgImage: ramp))

    let ciContext = VideoColorPipeline.makeCIContext()
    let output = try XCTUnwrap(
      ciContext.createCGImage(
        encoded, from: CGRect(x: 0, y: 0, width: 256, height: 4),
        format: .RGBA8, colorSpace: VideoColorPipeline.workingColorSpace))

    var pixels = [UInt8](repeating: 0, count: 256 * 4 * 4)
    let readback = try XCTUnwrap(
      CGContext(
        data: &pixels, width: 256, height: 4, bitsPerComponent: 8, bytesPerRow: 256 * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    readback.draw(output, in: CGRect(x: 0, y: 0, width: 256, height: 4))

    // Row 1, red channel — the ramp is grey, so any channel will do.
    return (0..<256).map { pixels[(1 * 256 + $0) * 4] }
  }

  func testTheKernelCompiles() {
    // Separated from the parity test on purpose: `encodeToBt709` returns the
    // image UNCHANGED when the kernel fails to compile, so without this a
    // compile failure would surface as a confusing wall of off-by-N parity
    // failures instead of "the kernel did not build".
    XCTAssertNotNil(
      ColorTransferFunctions.srgbToBt709Kernel,
      "the CIColorKernel source failed to compile")
  }

  /// The GPU kernel must agree with the CPU function it was ported from, at
  /// every code value.
  ///
  /// This is also the probe for the load-bearing assumption behind the kernel:
  /// that Core Image hands it sRGB-ENCODED samples because the export context
  /// declares a gamma-encoded sRGB working space. If Core Image linearises on
  /// input instead, the kernel applies an EOTF to already-linear light and
  /// this fails hard and immediately — in milliseconds, on one stage, rather
  /// than as a few levels of drift at the end of a six-stage export.
  func testTheGpuKernelMatchesTheCpuFunction() throws {
    let measured = try renderRampThroughKernel()

    var mismatches: [String] = []
    for value in 0...255 {
      let expected = ColorTransferFunctions.srgbToBt709(UInt8(value))
      // +/-1: the kernel is 32-bit float on the GPU against Double on the CPU,
      // then both round to 8 bits. Anything larger is a real disagreement, not
      // precision — the defect being fixed here is ~11 levels.
      if abs(Int(measured[value]) - Int(expected)) > 1 {
        mismatches.append("\(value): kernel \(measured[value]), function \(expected)")
      }
    }
    XCTAssertEqual(
      mismatches, [],
      "GPU kernel disagrees with ColorTransferFunctions.srgbToBt709")
  }

  /// The midtone the whole investigation turns on, pinned on the GPU path too.
  func testTheKernelMovesMidGreyDown() throws {
    let measured = try renderRampThroughKernel()
    XCTAssertEqual(Int(measured[128]), 115, accuracy: 1, "128 must encode to 115")
  }

  /// The same property the CPU function is held to: an encode never raises a
  /// code value. Every wrong result in this investigation raised them.
  func testTheKernelNeverRaisesAValue() throws {
    let measured = try renderRampThroughKernel()
    for value in 0...255 {
      XCTAssertLessThanOrEqual(
        Int(measured[value]), value + 1,
        "sRGB \(value) encoded UP to \(measured[value]) — that is a decode")
    }
  }
}
