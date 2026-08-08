import AVFoundation
import AppKit
import XCTest

@testable import Clingfy

/// The burn-in seat, pinned against the production render path.
///
/// This exists because the tests that claimed to cover it did not.
/// `CaptionOverlayRendererTests` re-implements both orderings in its own helper
/// and never touches `LetterboxExporter`, so moving the composite back to the
/// pre-grade seat left the suite green while the defect shipped. The assertion
/// here runs the real export and reads the real pixels, so deleting or moving
/// the production line fails it.
final class CaptionBurnInSeatTests: XCTestCase {

  private var tempDir: URL!

  override func setUpWithError() throws {
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("clingfy_seat_\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: tempDir)
  }

  /// A solid mid-grey source, so a grade has something to move.
  private func makeSourceVideo(url: URL, seconds: Double) throws {
    let size = CGSize(width: 320, height: 180)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(size.width),
        AVVideoHeightKey: Int(size.height),
      ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(size.width),
        kCVPixelBufferHeightKey as String: Int(size.height),
      ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    let frames = Int(seconds * 30)
    for i in 0..<frames {
      var pixelBuffer: CVPixelBuffer?
      CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixelBuffer)
      guard let buffer = pixelBuffer else { continue }
      CVPixelBufferLockBaseAddress(buffer, [])
      if let base = CVPixelBufferGetBaseAddress(buffer) {
        // Mid grey (0x80) in BGRA.
        memset(base, 0x80, CVPixelBufferGetDataSize(buffer))
      }
      CVPixelBufferUnlockBaseAddress(buffer, [])
      while !input.isReadyForMoreMediaData { usleep(1000) }
      adaptor.append(
        buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
    }
    input.markAsFinished()
    let done = expectation(description: "source written")
    writer.finishWriting { done.fulfill() }
    wait(for: [done], timeout: 30)
  }

  /// One opaque, strongly saturated caption bitmap filling the frame.
  ///
  /// Full-frame and saturated on purpose: a small pill would be averaged away
  /// by the sampler, and a NEUTRAL colour is invariant under saturation and
  /// clips under contrast, so it would pass at both seats and prove nothing.
  private func writeCaptionBitmap(named name: String, size: CGSize) throws {
    let image = NSImage(size: size)
    image.lockFocus()
    // A MIDTONE, and non-neutral on every channel. A probe with a zeroed
    // channel is useless here: exposure is multiplicative, so 0 stays 0 whether
    // the caption was graded or not, and the assertion passes at both seats.
    // (The first version of this test made exactly that mistake and its
    // mutation check caught it.) Midtones also matter because the export
    // transfer crosses over near code 24 and saturates at the ends.
    NSColor(srgbRed: 0.35, green: 0.25, blue: 0.70, alpha: 1.0).setFill()
    NSRect(origin: .zero, size: size).fill()
    image.unlockFocus()
    let tiff = try XCTUnwrap(image.tiffRepresentation)
    let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
    let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    try png.write(to: tempDir.appendingPathComponent(name))
  }

  func testACaptionIsNotPutThroughTheUsersColourGrade() throws {
    let sourceURL = tempDir.appendingPathComponent("source.mov")
    try makeSourceVideo(url: sourceURL, seconds: 1.0)
    try writeCaptionBitmap(named: "cue.png", size: CGSize(width: 320, height: 180))

    let params = CompositionParams(
      targetSize: CGSize(width: 320, height: 180),
      padding: 0.0,
      cornerRadius: 0.0,
      backgroundColor: nil,
      backgroundImagePath: nil,
      cursorSize: 1.0,
      showCursor: false,
      zoomEnabled: false,
      zoomFactor: 1.0,
      followStrength: 0.15,
      fpsHint: 30,
      fitMode: "fit",
      audioGainDb: 0.0,
      audioVolumePercent: 100.0
    )
    let composition = try XCTUnwrap(
      CompositionBuilder().buildExport(
        asset: AVAsset(url: sourceURL),
        cameraAsset: nil,
        params: params,
        cameraParams: nil,
        cursorRecording: nil,
        cameraAssetIsPreStyled: false
      )
    )

    // A strong EXPOSURE grade: it moves every channel, unlike saturation, which
    // leaves a neutral probe untouched and would let the wrong seat pass.
    let grade = ColorGrade(
      autoEnabled: false,
      exposure: 0.8,
      contrast: 0,
      saturation: 0,
      temperature: 0,
      tint: 0
    )
    let outputURL = tempDir.appendingPathComponent("out.mov")
    let exporter = LetterboxExporter()
    let done = expectation(description: "render")
    var rendered: Result<URL, Error>?

    exporter._testRenderFinalExport(
      result: composition,
      outputURL: outputURL,
      colorGrade: grade,
      captionBitmapDirectory: tempDir.path,
      captions: [
        CaptionCueTrack.Cue(
          id: "c1", startMs: 0, endMs: 1000, bitmapName: "cue.png")
      ]
    ) { result in
      rendered = result
      done.fulfill()
    }
    wait(for: [done], timeout: 90)

    let finalURL = try XCTUnwrap(try rendered?.get())
    XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))

    // Decode a frame the caption covers and read the middle pixel.
    let generator = AVAssetImageGenerator(asset: AVAsset(url: finalURL))
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let cg = try generator.copyCGImage(
      at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil)

    let rep = NSBitmapImageRep(cgImage: cg)
    let sampled = try XCTUnwrap(
      rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2))

    // Decoded through the export transfer, like every other colour assertion in
    // this project -- the seat sits upstream of encodeForExport.
    func decode(_ component: CGFloat) -> Double {
      let byte = UInt8(max(0, min(255, (component * 255).rounded())))
      return Double(ColorTransferFunctions.exportTransferToSrgb(byte)) / 255.0
    }
    let red = decode(sampled.redComponent)
    let green = decode(sampled.greenComponent)
    let blue = decode(sampled.blueComponent)

    // The caption must come out the colour it was authored in. Running the
    // user's +0.8 exposure over it lifts every channel well past this
    // tolerance, which is what makes deleting or moving the production line
    // fail here rather than pass quietly.
    XCTAssertEqual(red, 0.35, accuracy: 0.10, "red survived the grade")
    XCTAssertEqual(green, 0.25, accuracy: 0.10, "green survived the grade")
    XCTAssertEqual(blue, 0.70, accuracy: 0.10, "blue survived the grade")
  }
}
