import CoreGraphics
import ImageIO
import XCTest

@testable import Clingfy

/// Pins the ImageIO GIF writer by encoding real `.gif` files and reading them
/// back: frame count, infinite loop, drift-free unclamped delays, the opaque
/// flatten (no surviving transparency), and the lifecycle guarantees
/// (empty-writes-nothing, cancel-deletes). CPU-only / headless-safe.
final class GifEncoderTests: XCTestCase {
  private var tempDir: URL!

  override func setUpWithError() throws {
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("gif-encoder-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
  }

  // MARK: - helpers

  private func makeSolidImage(
    width: Int = 8, height: Int = 8,
    red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat
  ) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(
      CGColor(colorSpace: colorSpace, components: [red, green, blue, alpha])!)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
  }

  private func gifSource(_ url: URL) throws -> CGImageSource {
    try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
  }

  private func loopCount(_ source: CGImageSource) -> Int? {
    let props = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
    let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
    return gif?[kCGImagePropertyGIFLoopCount] as? Int
  }

  private func unclampedDelay(_ source: CGImageSource, at index: Int) -> Double? {
    let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
    let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
    return gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
  }

  /// Draw `image` over an opaque RED background and return the top-left RGBA.
  /// If the GIF frame is opaque (flatten worked) the pixel is the frame's color;
  /// if transparency survived, red shows through.
  private func topLeftOverRed(_ image: CGImage) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
    let width = image.width
    let height = image.height
    var data = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = data.withUnsafeMutableBytes { raw in
      CGContext(
        data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }
    context.setFillColor(CGColor(colorSpace: colorSpace, components: [1, 0, 0, 1])!)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (data[0], data[1], data[2], data[3])
  }

  // MARK: - tests

  func testEncodesFrameCountLoopAndDriftFreeUnclampedDelays() throws {
    let url = tempDir.appendingPathComponent("out.gif")
    let encoder = try GifEncoder(url: url, frameCountHint: 4)
    let interval = GifExportPolicy.frameIntervalHns()
    // Four frames on a uniform 15 fps grid.
    for i in 0..<4 {
      let image = makeSolidImage(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
      try encoder.append(image, timestampHns: Int64(i) * interval)
    }
    XCTAssertTrue(try encoder.finalize())
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

    let source = try gifSource(url)
    XCTAssertEqual(CGImageSourceGetType(source) as String?, "com.compuserve.gif")
    XCTAssertEqual(CGImageSourceGetCount(source), 4)
    XCTAssertEqual(loopCount(source), 0)  // infinite

    // Lookahead + accumulator: the three measured gaps drift-correct to 7,6,7 cs
    // and the final frame gets the 7 cs default. GIF stores centiseconds exactly.
    let delays = try (0..<4).map { try XCTUnwrap(unclampedDelay(source, at: $0)) }
    let expected = [0.07, 0.06, 0.07, 0.07]
    for (got, want) in zip(delays, expected) {
      XCTAssertEqual(got, want, accuracy: 0.0005)
    }
  }

  func testOpaqueFlattenLeavesNoTransparency() throws {
    let url = tempDir.appendingPathComponent("transparent.gif")
    let encoder = try GifEncoder(url: url)
    // Fully transparent input — if the flatten were skipped, ImageIO would
    // allocate a transparent palette index and red would show through.
    let transparent = makeSolidImage(red: 0.2, green: 0.7, blue: 0.9, alpha: 0)
    try encoder.append(transparent, timestampHns: 0)
    XCTAssertTrue(try encoder.finalize())

    let source = try gifSource(url)
    let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let pixel = topLeftOverRed(frame)
    // Flatten default is opaque black -> not red.
    XCTAssertLessThan(pixel.r, 24, "transparency survived — red background showed through")
    XCTAssertLessThan(pixel.g, 24)
    XCTAssertLessThan(pixel.b, 24)
    XCTAssertEqual(pixel.a, 255)
  }

  func testFinalizeWithNoFramesWritesNothing() throws {
    let url = tempDir.appendingPathComponent("empty.gif")
    let encoder = try GifEncoder(url: url)
    XCTAssertFalse(try encoder.finalize())
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
  }

  func testCancelDeletesPartialFile() throws {
    let url = tempDir.appendingPathComponent("cancelled.gif")
    let encoder = try GifEncoder(url: url)
    try encoder.append(makeSolidImage(red: 1, green: 1, blue: 1, alpha: 1), timestampHns: 0)
    encoder.cancel()
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
  }
}
