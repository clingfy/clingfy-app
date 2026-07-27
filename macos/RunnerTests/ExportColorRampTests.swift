import AVFoundation
import CoreImage
import XCTest

@testable import Clingfy

/// Measures what the export pipeline does to known colour, instead of
/// reasoning about which tag "should" win.
///
/// The criterion is round-trip fidelity: author a ramp in sRGB, push it
/// through the real writer settings, decode the result back to sRGB, and
/// compare. If those disagree, the exported file does not show what the
/// editor showed — which is the reported symptom.
final class ExportColorRampTests: XCTestCase {

  /// Flat patches, because H.264 is lossy and gradients smear across edges.
  private static let rampValues: [UInt8] = [0, 32, 64, 96, 128, 160, 192, 224, 255]

  private static let patchWidth = 160
  private static let patchHeight = 720

  private var tempDirectory: URL!

  override func setUpWithError() throws {
    tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ExportColorRampTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let tempDirectory { try? FileManager.default.removeItem(at: tempDirectory) }
  }

  // MARK: - Fixture

  /// A horizontal greyscale ramp authored in sRGB.
  private func makeRampImage() throws -> CGImage {
    let width = Self.patchWidth * Self.rampValues.count
    let height = Self.patchHeight
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))

    for (index, value) in Self.rampValues.enumerated() {
      let level = CGFloat(value) / 255.0
      context.setFillColor(red: level, green: level, blue: level, alpha: 1.0)
      context.fill(
        CGRect(
          x: index * Self.patchWidth, y: 0, width: Self.patchWidth, height: height))
    }
    return try XCTUnwrap(context.makeImage())
  }

  /// Mean value of each patch, read back in sRGB.
  private func samplePatches(of image: CGImage) throws -> [Double] {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = try XCTUnwrap(
      CGContext(
        data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

    let patchWidth = image.width / Self.rampValues.count
    var means: [Double] = []
    for index in 0..<Self.rampValues.count {
      // Sample the middle of each patch so codec ringing at the edges does
      // not pollute the reading.
      let x0 = index * patchWidth + patchWidth / 4
      let x1 = index * patchWidth + (patchWidth * 3) / 4
      let y0 = image.height / 4
      let y1 = (image.height * 3) / 4
      var total = 0.0
      var count = 0.0
      for y in stride(from: y0, to: y1, by: 4) {
        for x in stride(from: x0, to: x1, by: 4) {
          total += Double(pixels[(y * image.width + x) * 4])
          count += 1
        }
      }
      means.append(total / count)
    }
    return means
  }

  // MARK: - The measurement

  /// Writes the ramp through the production writer settings and reads the
  /// first frame back, decoded to sRGB.
  private func roundTripThroughExport(
    renderColorSpace: CGColorSpace,
    tagBuffer: (CVPixelBuffer) -> Void
  ) throws -> [Double] {
    let ramp = try makeRampImage()
    let width = ramp.width
    let height = ramp.height
    let outputURL = tempDirectory.appendingPathComponent("ramp-\(UUID().uuidString).mov")

    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
    let input = try VideoColorPipeline.makeVideoWriterInput(
      baseOutputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
      ],
      category: "Test",
      operation: "color_ramp")
    input.expectsMediaDataInRealTime = false

    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
      ])

    XCTAssertTrue(writer.canAdd(input))
    writer.add(input)
    XCTAssertTrue(writer.startWriting())
    writer.startSession(atSourceTime: .zero)

    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(
      kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
      [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary, &buffer)
    let pixelBuffer = try XCTUnwrap(buffer)

    // Render exactly as the exporter does: a CIContext working in the
    // pipeline's colour space, drawing into the buffer that gets written.
    let ciContext = VideoColorPipeline.makeCIContext()
    ciContext.render(
      CIImage(cgImage: ramp), to: pixelBuffer,
      bounds: CGRect(x: 0, y: 0, width: width, height: height),
      colorSpace: renderColorSpace)
    tagBuffer(pixelBuffer)

    XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: .zero))
    input.markAsFinished()
    let finished = expectation(description: "written")
    writer.finishWriting { finished.fulfill() }
    wait(for: [finished], timeout: 60)
    XCTAssertNotEqual(writer.status, .failed, "writer failed: \(String(describing: writer.error))")

    // Decode the first frame back into sRGB.
    let asset = AVURLAsset(url: outputURL)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .positiveInfinity
    let decoded = try generator.copyCGImage(at: .zero, actualTime: nil)
    return try samplePatches(of: decoded)
  }

  // MARK: - Tests

  /// Establishes the baseline: what the ramp looks like before any video
  /// encoding, so a failure downstream cannot be blamed on the fixture.
  func testTheRampFixtureItselfIsFaithful() throws {
    let ramp = try makeRampImage()
    let means = try samplePatches(of: ramp)
    for (index, expected) in Self.rampValues.enumerated() {
      XCTAssertEqual(
        means[index], Double(expected), accuracy: 1.0,
        "authored patch \(index) drifted before any encoding")
    }
  }

  /// The load-bearing measurement. Authoring in sRGB and decoding back to
  /// sRGB must return what was authored; anything else is the exported file
  /// disagreeing with the editor.
  ///
  /// Tolerance is generous because H.264 is lossy — the reported symptom is
  /// a shift of 8-16 levels, far outside codec noise.
  func testExportRoundTripPreservesAuthoredValues() throws {
    // KNOWN FAILING — this is the reported bug, pinned as a measurement.
    // XCTExpectFailure rather than a disabled test: it still RUNS and still
    // records the numbers, and it will fail loudly as an unexpected PASS the
    // moment the pipeline is fixed, so the fix cannot land unnoticed.
    XCTExpectFailure(
      "Export re-encodes sRGB data under a BT.709 transfer tag; midtones lift ~11/255")

    let measured = try roundTripThroughExport(
      renderColorSpace: VideoColorPipeline.workingColorSpace
    ) { buffer in
      VideoColorPipeline.tag(pixelBuffer: buffer)
    }

    var report: [String] = []
    for (index, expected) in Self.rampValues.enumerated() {
      report.append(
        String(format: "  %3d -> %6.1f  (%+.1f)", expected, measured[index],
               measured[index] - Double(expected)))
    }
    let table = "ramp round-trip (authored -> decoded):\n" + report.joined(separator: "\n")
    print(table)
    try? table.write(
      to: URL(fileURLWithPath: "/tmp/ramp_result.txt"), atomically: true, encoding: .utf8)

    for (index, expected) in Self.rampValues.enumerated() {
      XCTAssertEqual(
        measured[index], Double(expected), accuracy: 4.0,
        "patch \(index): authored \(expected), decoded \(measured[index]) — "
          + "the exported file does not match what the editor showed")
    }
  }

  /// Candidate fix, measured before it is adopted: encode the pixels in the
  /// space the file already declares (BT.709) instead of sRGB, and tag the
  /// buffer to match.
  ///
  /// If this round-trips faithfully, the defect is purely that the data and
  /// the transfer tag disagreed — and the fix is to make the data agree,
  /// not to change what the file claims. Keeping the file at 709 also keeps
  /// it standard, which every player expects.
  func testEncodingInTheDeclaredSpaceRoundTripsFaithfully() throws {
    // DISPROVEN, kept so the next person does not retry it: encoding in 709
    // makes the shift WORSE (+18 at midtone versus +11 for the current
    // pipeline). Whatever the fix is, it is not this.
    XCTExpectFailure("Encoding in BT.709 overshoots: +18 at midtone, worse than the +11 baseline")

    let bt709 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.itur_709))

    let measured = try roundTripThroughExport(renderColorSpace: bt709) { buffer in
      CVBufferSetAttachment(
        buffer, kCVImageBufferCGColorSpaceKey, bt709, .shouldPropagate)
      CVBufferSetAttachment(
        buffer, kCVImageBufferColorPrimariesKey,
        kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
      CVBufferSetAttachment(
        buffer, kCVImageBufferTransferFunctionKey,
        kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
      CVBufferSetAttachment(
        buffer, kCVImageBufferYCbCrMatrixKey,
        kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    var report: [String] = []
    for (index, expected) in Self.rampValues.enumerated() {
      report.append(
        String(format: "  %3d -> %6.1f  (%+.1f)", expected, measured[index],
               measured[index] - Double(expected)))
    }
    let table = "CANDIDATE (encode in 709):\n" + report.joined(separator: "\n")
    print(table)
    try? table.write(
      to: URL(fileURLWithPath: "/tmp/ramp_candidate.txt"), atomically: true, encoding: .utf8)

    for (index, expected) in Self.rampValues.enumerated() {
      XCTAssertEqual(
        measured[index], Double(expected), accuracy: 4.0,
        "patch \(index): authored \(expected), decoded \(measured[index])")
    }
  }
}
