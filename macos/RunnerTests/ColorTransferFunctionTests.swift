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
}
