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
  private static let rampValues: [UInt8] = [
    // 8/16 and 240/248 straddle the limited-range boundaries (16 and 235);
    // if the file's range flag disagrees with the data these crush or clip
    // while the 0/255 endpoints still look fine.
    0, 8, 16, 32, 64, 96, 128, 160, 192, 224, 240, 248, 255,
  ]

  private static let patchWidth = 96
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
    ciContext: CIContext? = nil,
    // When true this renders through `VideoColorPipeline.renderComposedExportFrame`
    // — the exact function both final export render sites call — instead of a
    // bespoke `render` written for the test. That is the whole point: a
    // measurement that renders differently from the product can pass while the
    // product is broken.
    throughProductionRender: Bool = false,
    // Candidate transfer curve to apply before the write, for comparing
    // encodes against the real writer + decoder instead of arguing about them.
    probeEncode: ((CIImage) -> CIImage)? = nil,
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
    let ciContext = ciContext ?? VideoColorPipeline.makeCIContext()
    let renderBounds = CGRect(x: 0, y: 0, width: width, height: height)
    if throughProductionRender {
      VideoColorPipeline.renderComposedExportFrame(
        CIImage(cgImage: ramp), to: pixelBuffer, bounds: renderBounds, using: ciContext)
    } else {
      let sourceImage = CIImage(cgImage: ramp)
      ciContext.render(
        probeEncode?(sourceImage) ?? sourceImage, to: pixelBuffer, bounds: renderBounds,
        colorSpace: renderColorSpace)
    }
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
    // WAS the pinned bug; the pin is now removed and this must PASS. The
    // pipeline encodes with the decoder's own transfer before the write
    // (VideoColorPipeline.renderComposedExportFrame), so the data finally
    // agrees with the tag the file has always carried and the round trip
    // returns what was authored.
    //
    // This is the criterion the fix is held to. Two notes on why it is THIS
    // criterion and not the two obvious alternatives.
    //
    // Not `ffmpeg -vf zscale`: zscale's `t=bt709` implements the BT.1886
    // display curve, not a camera OETF. Measured, on linear 0.502: zscale
    // gives 192 where the published OETF predicts 180. Its controls are
    // honest — `t=linear` round-trips exactly and `t=iec61966-2-1` gives 188,
    // matching sRGB — so the disagreement is zscale's 709 curve specifically.
    // Verifying against it would report a correct export as broken.
    //
    // Not the published BT.709 OETF either, which was tried and measured:
    // it fixes midtones (+11 -> -2) and crushes shadows by up to 17 code
    // values, because its linear toe is never undone. See
    // `testACandidateTransferCurveRoundTripsWithinTolerance` for the sweep
    // that settled this and `ColorTransferFunctions.exportTransferGamma` for
    // what shipped.
    //
    // The extended ramp still shows a second, smaller defect at the limited-
    // range boundaries: 8/16 and 240/248 drift by 1-2. That is the
    // FullRangeVideo: 0 flag disagreeing with full-range data — independent of
    // the gamma error and deliberately not fixed here. The tolerance below
    // absorbs it; tightening it is the job of the range change.

    let measured = try roundTripThroughExport(
      renderColorSpace: VideoColorPipeline.workingColorSpace,
      throughProductionRender: true
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

  /// Which transfer curve does this writer + decoder actually round-trip?
  ///
  /// The published BT.709 OETF gets midtones and highlights right but crushes
  /// shadows by up to 17 code values, because its 4.5x linear toe near black
  /// is not undone on the way back. Rather than argue about which curve the
  /// decoder "should" apply, this sweeps plain power laws through the real
  /// writer and the real decode and reports the worst-case error of each.
  ///
  /// The claim under test is that a curve exists which round-trips this
  /// pipeline within the same tolerance the main test uses. Which one wins is
  /// printed, so adopting it is a decision made from the table.
  func testACandidateTransferCurveRoundTripsWithinTolerance() throws {
    let publishedOetf = try roundTripThroughExport(
      renderColorSpace: VideoColorPipeline.workingColorSpace,
      probeEncode: { ColorTransferFunctions.encodeToBt709($0) }
    ) { VideoColorPipeline.tag(pixelBuffer: $0) }

    func worstError(_ measured: [Double]) -> Double {
      zip(Self.rampValues, measured).map { abs($1 - Double($0)) }.max() ?? .infinity
    }

    var rows: [String] = [
      String(format: "  published 709 OETF   worst %5.1f", worstError(publishedOetf))
    ]
    var best: (gamma: Double, worst: Double, measured: [Double])?

    for gamma in [1.8, 1.961, 2.0, 2.2, 2.4] {
      let measured = try roundTripThroughExport(
        renderColorSpace: VideoColorPipeline.workingColorSpace,
        probeEncode: { ColorTransferFunctions.encodeToPureGamma($0, gamma: gamma) }
      ) { VideoColorPipeline.tag(pixelBuffer: $0) }
      let worst = worstError(measured)
      rows.append(String(format: "  pure gamma %-6.3f     worst %5.1f", gamma, worst))
      if best == nil || worst < best!.worst {
        best = (gamma, worst, measured)
      }
    }

    let winner = try XCTUnwrap(best)
    var detail = ["candidate transfer curves (worst |authored - decoded|):"]
    detail.append(contentsOf: rows)
    detail.append(String(format: "  winner: pure gamma %.3f", winner.gamma))
    for (index, expected) in Self.rampValues.enumerated() {
      detail.append(
        String(format: "    %3d -> %6.1f  (%+.1f)", expected, winner.measured[index],
               winner.measured[index] - Double(expected)))
    }
    let table = detail.joined(separator: "\n")
    print(table)
    try? table.write(
      to: URL(fileURLWithPath: "/tmp/ramp_candidates.txt"), atomically: true, encoding: .utf8)

    XCTAssertLessThanOrEqual(
      winner.worst, 4.0,
      "no candidate transfer curve round-trips this pipeline; see the table above")
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
    // MEASURED, not assumed: this produces byte-identical numbers to the
    // linear-working-space variant below. So the 709 OETF is applied exactly
    // ONCE here — `render(_:to:bounds:colorSpace:)` governs output encoding
    // and the context's `outputColorSpace` option is ignored for that API.
    // The overshoot is therefore not a double encode.

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

  /// Candidate: linear-light working space, BT.709 on the way out.
  ///
  /// The previous candidate applied the 709 OETF to values Core Image had
  /// ALREADY gamma-encoded as sRGB — a double encode, which is why it
  /// overshot to +18 rather than showing 709 to be wrong. The correct
  /// transform is linearize, then apply 709. Working in extended linear sRGB
  /// makes that explicit instead of implicit.
  func testLinearWorkingSpaceWithBT709OutputRoundTripsFaithfully() throws {
    // MEASURED IDENTICAL to the plain-709 candidate at every patch, which
    // disproves the double-encode explanation for the overshoot. Kept as a
    // test because "make the working space linear" is the obvious next idea
    // and this records that, on this API, it changes nothing.
    XCTExpectFailure("Identical to the plain 709 candidate: +18 at midtone")

    let bt709 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.itur_709))
    let linear = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))

    let context = CIContext(options: [
      .cacheIntermediates: false,
      .workingColorSpace: linear,
      .outputColorSpace: bt709,
      .workingFormat: CIFormat.RGBAh,
    ])

    let measured = try roundTripThroughExport(
      renderColorSpace: bt709, ciContext: context
    ) { buffer in
      CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, bt709, .shouldPropagate)
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
    let table = "CANDIDATE (linear working -> 709 out):\n" + report.joined(separator: "\n")
    print(table)
    try? table.write(
      to: URL(fileURLWithPath: "/tmp/ramp_linear.txt"), atomically: true, encoding: .utf8)

    for (index, expected) in Self.rampValues.enumerated() {
      XCTAssertEqual(
        measured[index], Double(expected), accuracy: 4.0,
        "patch \(index): authored \(expected), decoded \(measured[index])")
    }
  }
}
