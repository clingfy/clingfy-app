import AVFoundation
import CoreGraphics
import ImageIO
import XCTest

@testable import Clingfy

/// End-to-end transcode: a synthetic composited video -> animated GIF. Asserts
/// the decimation (30 fps source -> ~15 fps), the infinite loop, the long-edge
/// downscale cap, and that a valid `.gif` is produced. CI-runnable (writes its
/// own fixture video, no app UI).
final class GifExportSessionTests: XCTestCase {
  private var tempDir: URL!

  override func setUpWithError() throws {
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("gif-session-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
  }

  // MARK: - fixtures

  private func makeSolidPixelBuffer(width: Int, height: Int, red: CGFloat) -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(
      kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
      [
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
      ] as CFDictionary, &pixelBuffer)
    let buffer = pixelBuffer!
    CVPixelBufferLockBaseAddress(buffer, [])
    let context = CGContext(
      data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue)!
    context.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [red, 0.3, 0.6, 1])!)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
  }

  private func writeSolidVideo(url: URL, width: Int, height: Int, seconds: Double, fps: Int32 = 30)
    throws
  {
    let writer = try AVAssetWriter(url: url, fileType: .mov)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264.rawValue,
        AVVideoWidthKey: width, AVVideoHeightKey: height,
      ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
      ])
    XCTAssertTrue(writer.canAdd(input))
    writer.add(input)
    XCTAssertTrue(writer.startWriting())
    writer.startSession(atSourceTime: .zero)

    let frameCount = max(2, Int(seconds * Double(fps)))
    for frame in 0..<frameCount {
      while !input.isReadyForMoreMediaData {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
      }
      let buffer = makeSolidPixelBuffer(
        width: width, height: height, red: CGFloat(frame) / CGFloat(frameCount))
      XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)))
    }
    input.markAsFinished()
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting { semaphore.signal() }
    semaphore.wait()
    if let error = writer.error { throw error }
  }

  private func transcode(
    _ source: URL, to gif: URL,
    maxLongEdge: CGFloat = GifExportPolicy.defaultMaxLongEdge,
    timeout: TimeInterval = 30
  ) -> Result<URL, Error>? {
    let session = GifExportSession()
    let expectation = expectation(description: "transcode")
    var captured: Result<URL, Error>?
    session.run(
      sourceVideoURL: source, outputURL: gif, maxLongEdge: maxLongEdge, onProgress: nil
    ) { result in
      captured = result
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: timeout)
    return captured
  }

  // MARK: - tests

  func testTranscodesVideoToDecimatedInfiniteLoopGif() throws {
    let source = tempDir.appendingPathComponent("src.mov")
    try writeSolidVideo(url: source, width: 400, height: 300, seconds: 1.0, fps: 30)
    let gif = tempDir.appendingPathComponent("out.gif")

    let result = try XCTUnwrap(transcode(source, to: gif))
    guard case .success(let url) = result else {
      return XCTFail("transcode failed: \(result)")
    }
    XCTAssertEqual(url, gif)

    let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
    XCTAssertEqual(CGImageSourceGetType(imageSource) as String?, "com.compuserve.gif")

    // 30 fps over 1 s decimates to ~15 kept frames on the ideal grid.
    let count = CGImageSourceGetCount(imageSource)
    XCTAssertGreaterThanOrEqual(count, 13)
    XCTAssertLessThanOrEqual(count, 16)

    let properties = CGImageSourceCopyProperties(imageSource, nil) as? [CFString: Any]
    let gifDictionary = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
    XCTAssertEqual(gifDictionary?[kCGImagePropertyGIFLoopCount] as? Int, 0)

    // 400x300 is within the cap -> unchanged.
    let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
    XCTAssertEqual(frame.width, 400)
    XCTAssertEqual(frame.height, 300)
  }

  func testDownscalesLargeSourceToTheLongEdgeCap() throws {
    let source = tempDir.appendingPathComponent("big.mov")
    try writeSolidVideo(url: source, width: 1600, height: 900, seconds: 0.4, fps: 30)
    let gif = tempDir.appendingPathComponent("big.gif")

    let result = try XCTUnwrap(transcode(source, to: gif))
    guard case .success = result else { return XCTFail("transcode failed: \(result)") }

    let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
    let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
    // 1600x900: long edge 1600 -> 1080, height 900 * (1080/1600) = 607.5 -> 608.
    XCTAssertEqual(frame.width, 1080)
    XCTAssertEqual(frame.height, 608)
  }

  func testSmallSizePresetCapDownscalesFurtherThanLarge() throws {
    // The same 1600x900 source, but transcoded at the Small preset's 480 cap
    // (as ExportEngine would pass through from the size selection): 1600 -> 480,
    // 900 * (480/1600) = 270.
    let source = tempDir.appendingPathComponent("small.mov")
    try writeSolidVideo(url: source, width: 1600, height: 900, seconds: 0.4, fps: 30)
    let gif = tempDir.appendingPathComponent("small.gif")

    let result = try XCTUnwrap(
      transcode(source, to: gif, maxLongEdge: GifExportPolicy.maxLongEdge(forSizePreset: "small")))
    guard case .success = result else { return XCTFail("transcode failed: \(result)") }

    let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
    let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
    XCTAssertEqual(frame.width, 480)
    XCTAssertEqual(frame.height, 270)
  }
}
