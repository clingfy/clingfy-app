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
  ///
  /// `color` must be a MIDTONE, and non-neutral on every channel. A probe with
  /// a zeroed channel is useless in the grade-seat test: exposure is
  /// multiplicative, so 0 stays 0 whether the caption was graded or not, and
  /// the assertion passes at both seats. (The first version of that test made
  /// exactly that mistake and its mutation check caught it.) Midtones also
  /// matter because the export transfer crosses over near code 24 and
  /// saturates at the ends.
  ///
  /// Passed at every call site rather than defaulted: the probe colour is the
  /// thing these assertions actually rest on, so it belongs in the test body,
  /// not hidden in this helper.
  private func writeCaptionBitmap(named name: String, size: CGSize, color: NSColor) throws {
    let image = NSImage(size: size)
    image.lockFocus()
    color.setFill()
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
    try writeCaptionBitmap(
      named: "cue.png", size: CGSize(width: 320, height: 180),
      color: NSColor(srgbRed: 0.35, green: 0.25, blue: 0.70, alpha: 1.0))

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

  /// Asserts the exported frame shown at `editedSeconds` carries the caption
  /// authored in `expectedSrgb`.
  ///
  /// Reads the middle pixel, which a full-frame caption bitmap always covers:
  /// placement only lifts the bitmap `defaultBottomMarginFraction` (0.08) of
  /// the canvas height off the bottom, so on a 180pt canvas just the bottom
  /// ~14 rows are bare. The sampled bytes are decoded back through the export
  /// transfer before comparing -- the burn-in seat is upstream of
  /// `encodeForExport`, so a raw comparison against the authored colour is off
  /// by the whole transfer.
  private func assertBurnedInCaption(
    in url: URL,
    atEditedSeconds editedSeconds: Double,
    isSrgb expectedSrgb: NSColor,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let generator = AVAssetImageGenerator(asset: AVAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    // Load-bearing on a REORDERED file: left at the default the generator is
    // free to hand back the nearest sync sample, which here can belong to the
    // other kept range entirely -- i.e. to a different moment of the source.
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero

    var actualTime = CMTime.zero
    let frame = try generator.copyCGImage(
      at: CMTime(seconds: editedSeconds, preferredTimescale: 600),
      actualTime: &actualTime
    )
    // A file that is short by a whole range would clamp to its last frame and
    // quietly answer with the wrong range instead of failing. One frame of
    // slack at 30fps.
    XCTAssertEqual(
      actualTime.seconds, editedSeconds, accuracy: 0.034,
      "\(message): sampled the wrong frame", file: file, line: line)

    let rep = NSBitmapImageRep(cgImage: frame)
    let sampled = try XCTUnwrap(
      rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2), file: file, line: line)

    func decode(_ component: CGFloat) -> Double {
      let byte = UInt8(max(0, min(255, (component * 255).rounded())))
      return Double(ColorTransferFunctions.exportTransferToSrgb(byte)) / 255.0
    }
    XCTAssertEqual(
      decode(sampled.redComponent), Double(expectedSrgb.redComponent),
      accuracy: 0.10, "\(message) (red)", file: file, line: line)
    XCTAssertEqual(
      decode(sampled.greenComponent), Double(expectedSrgb.greenComponent),
      accuracy: 0.10, "\(message) (green)", file: file, line: line)
    XCTAssertEqual(
      decode(sampled.blueComponent), Double(expectedSrgb.blueComponent),
      accuracy: 0.10, "\(message) (blue)", file: file, line: line)
  }

  /// The reader-swap cue-cursor reset, pinned against the production render
  /// path.
  ///
  /// `CaptionCueTrackTests`' reset pair calls `track.reset()` in the *test
  /// body*, so it pins the struct and says nothing about whether the exporter
  /// ever calls it: delete `captionCueTrack?.reset()` from
  /// `runRenderedExportSession`'s reader-swap branch and that pair stays green.
  /// This runs a real REORDERED export through `_testRenderFinalExport` and
  /// reads the real pixels, so the deletion fails here.
  ///
  /// The fixture is the smallest one that can tell the difference:
  ///
  /// ```
  ///   source   0 -----1s--------2s ------3s
  ///            [ "early" ]      [ "late" ]
  ///
  ///   edited   0 -----1s ------2s
  ///            [ "late" ][ "early" ]        <- keptRanges, in TIMELINE order
  /// ```
  ///
  /// Exactly two ranges, later source first. Three would heal itself: the
  /// parked cursor walks FORWARD on its own, so a third, still-later range
  /// renders fine with or without the reset and an "every range after the
  /// first" assertion would pass under the mutation.
  ///
  /// This covers the cue-cursor reset ONLY. The `captionRenderer?.reset()` on
  /// the next line drops a one-deep bitmap cache keyed by `cue.id`, and these
  /// two cues have different ids, so deleting that line changes no pixel here.
  func testAReorderedExportPaintsCaptionsOnTheRangeItReadsSecond() throws {
    let canvas = CGSize(width: 320, height: 180)
    let sourceURL = tempDir.appendingPathComponent("source.mov")
    // 3s at 30fps -> frames 0..89 on exact 1/30 multiples (the last at
    // 2.9667s). No frame sits on a range edge, so the clamp at the re-stamp
    // cannot land two frames on one edited PTS.
    try makeSourceVideo(url: sourceURL, seconds: 3.0)

    // What makes the mutation detectable is each probe's channel SPREAD, not
    // the arithmetic against this particular fixture. Both spread ~0.44, well
    // over 2x the 0.10 tolerance, so NO neutral grey can sit within tolerance
    // of all three channels at once -- whatever the bare source frame decodes
    // to, a frame that lost its caption fails. Stated this way the test
    // survives a future change to the fixture's grey.
    //
    // They are also >0.20 apart from each other on every channel, so "the
    // second range painted the FIRST range's cue" fails too, not just
    // "painted nothing". And both stay inside the saturation envelope the
    // grade-seat assertion above has already demonstrated through this same
    // NSImage -> PNG -> CIImage authoring path.
    let lateColor = NSColor(srgbRed: 0.72, green: 0.28, blue: 0.66, alpha: 1.0)
    let earlyColor = NSColor(srgbRed: 0.24, green: 0.68, blue: 0.30, alpha: 1.0)
    try writeCaptionBitmap(named: "late.png", size: canvas, color: lateColor)
    try writeCaptionBitmap(named: "early.png", size: canvas, color: earlyColor)
    // A bitmap that failed to write is indistinguishable from the mutation: the
    // renderer caches the miss, the export still succeeds, and the pixels are
    // bare source either way. Fail on the fixture instead, loudly.
    for name in ["late.png", "early.png"] {
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath: tempDir.appendingPathComponent(name).path),
        "fixture: \(name) must exist, or a missing bitmap reads as a lost cue")
    }

    let params = CompositionParams(
      targetSize: canvas,
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

    // TIMELINE order, and deliberately NON-monotonic in source time. That is
    // the entire trigger for the reader-swap path; listed the other way round
    // these are an ordinary forward read and the line under test never runs.
    // The 1s..2s gap also keeps them un-coalescable, so the fixture is the
    // shape production actually hands the renderer.
    let keptRanges = [
      ClipKeptRange(sourceInMs: 2000, sourceOutMs: 3000),
      ClipKeptRange(sourceInMs: 0, sourceOutMs: 1000),
    ]
    XCTAssertFalse(
      ClipPlaybackPlanner.isSourceMonotonic(keptRanges),
      "fixture precondition: these ranges must take the reorder path")

    // SOURCE time, not edited time -- that mismatch is the defect this guards.
    // Sorted and non-overlapping so neither is silently rejected by
    // CaptionCueTrack (a cue starting before the previous one ends is dropped).
    let captions = [
      CaptionCueTrack.Cue(id: "early", startMs: 0, endMs: 1000, bitmapName: "early.png"),
      CaptionCueTrack.Cue(id: "late", startMs: 2000, endMs: 3000, bitmapName: "late.png"),
    ]

    let outputURL = tempDir.appendingPathComponent("reordered.mov")
    let exporter = LetterboxExporter()
    let done = expectation(description: "render")
    var rendered: Result<URL, Error>?

    exporter._testRenderFinalExport(
      result: composition,
      outputURL: outputURL,
      captionBitmapDirectory: tempDir.path,
      captions: captions,
      keptRanges: keptRanges
    ) { result in
      rendered = result
      done.fulfill()
    }
    wait(for: [done], timeout: 90)

    let finalURL = try XCTUnwrap(try rendered?.get())
    XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
    // Both ranges really were written: 1s + 1s of edited timeline. A file cut
    // short would make the second sample below re-read the first range's last
    // frame instead of failing.
    XCTAssertEqual(
      AVAsset(url: finalURL).duration.seconds, 2.0, accuracy: 0.15,
      "both kept ranges should be on the edited timeline")

    // Positive control, and it only proves the cheap half: that the bitmap
    // directory resolves and the burn-in path runs at all. Edited 0.5s is
    // source 2.5s -- the FIRST range, whose reader is windowed before the loop
    // starts and whose cursor begins at zero, so it renders with or without the
    // reset. The 'early' cue's own fixture is covered by the file-exists guard
    // above, not by this assertion.
    try assertBurnedInCaption(
      in: finalURL, atEditedSeconds: 0.5, isSrgb: lateColor,
      "edited 0.5s is source 2.5s, inside cue 'late'")

    // THE ASSERTION. Edited 1.5s is source 0.5s: at the swap the reader jumped
    // BACKWARD, and the forward-only cue cursor is parked past 'early' unless
    // the exporter reset it. Parked, `activeCue` returns nil rather than a
    // stale cue, `applyCaptions` hands the frame straight back, and this pixel
    // is the bare source instead of the caption.
    try assertBurnedInCaption(
      in: finalURL, atEditedSeconds: 1.5, isSrgb: earlyColor,
      "edited 1.5s is source 0.5s, inside cue 'early'")
  }
}
