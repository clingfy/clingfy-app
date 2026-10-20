import AVFoundation
import CoreGraphics
import FlutterMacOS
import XCTest

@testable import Clingfy

/// Slice 8 / PR 27 guard: behavior pinned for the input-validation early
/// returns of `ExportEngine.export(...)` plus `cancel()`. The happy path
/// runs the real `LetterboxExporter` against a real on-disk recording —
/// that's covered by manual smoke + the existing
/// `RecordingFailureRecoveryTests` / export-path coverage in
/// `RunnerTests`. Here we pin the two paths the engine takes BEFORE the
/// exporter is invoked, plus the cancel passthrough.
@MainActor
final class ExportEngineTests: XCTestCase {

  private func makeAnyInput(
    projectPath: String = "/tmp/does-not-exist", format: String = "mov",
    directoryOverride: String? = nil, filename: String? = nil
  )
    -> ExportEngine.Input
  {
    ExportEngine.Input(
      projectPath: projectPath,
      layout: "auto",
      resolution: "auto",
      fit: "fit",
      padding: 0,
      cornerRadius: 0,
      backgroundColor: nil,
      backgroundImagePath: nil,
      backgroundPreset: nil,
      cursorSize: 1.0,
      zoomFactor: 1.0,
      showCursor: true,
      filename: filename,
      directoryOverride: directoryOverride,
      format: format,
      writesSubtitleSidecars: false,
      codec: "hevc",
      bitrate: "auto",
      audioQuality: "standard",
      audioGainDb: 0,
      audioVolumePercent: 100,
      autoNormalizeOnExport: false,
      targetLoudnessDbfs: -16,
      cameraPath: nil,
      cameraParams: nil)
  }

  /// Builds a deps struct with safe defaults; tests override the closure
  /// they care about.
  private func makeDeps(
    loadRecordingProject: @escaping (String) -> RecordingProjectRef? = { _ in nil }
  ) -> ExportEngine.Dependencies {
    .init(
      loadRecordingProject: loadRecordingProject,
      resolveTargetSize: { src, _, _ in src },
      exportFormatInfo: { _ in ExportFormatInfo(ext: "mov", avFileType: .mov) },
      flutterExportFailure: { err in
        FlutterError(code: "EXPORT_FAIL", message: err.localizedDescription, details: nil)
      },
      sanitizeCameraParams: { params, _ in params },
      saveFolderURL: { URL(fileURLWithPath: NSTemporaryDirectory()) },
      recordingStore: RecordingStore(),
      keepOriginals: false,
      defaultZoomFollowStrength: 0.15)
  }

  // MARK: - Missing-project early return

  func testExportReturnsEXPORTINPUTMISSINGWhenProjectFailsToLoad() {
    let engine = ExportEngine()
    var loaderProbed: String?
    let exp = expectation(description: "result fires synchronously")
    var receivedError: FlutterError?

    engine.export(
      input: makeAnyInput(projectPath: "/tmp/nope"),
      dependencies: makeDeps { path in
        loaderProbed = path
        return nil
      }
    ) { res in
      receivedError = res as? FlutterError
      exp.fulfill()
    }

    wait(for: [exp], timeout: 1)
    XCTAssertEqual(loaderProbed, "/tmp/nope", "loadRecordingProject must be probed with the input path")
    XCTAssertEqual(receivedError?.code, "EXPORT_INPUT_MISSING")
    XCTAssertEqual(
      receivedError?.details as? String, "/tmp/nope",
      "details must echo the projectPath the caller supplied")
    XCTAssertEqual(
      receivedError?.message,
      "Recording project not found. It may have been moved or deleted.")
  }

  // MARK: - GIF length cap

  /// A real project whose screen.mov runs `seconds`: two frames, at 0 and at
  /// the end, which is all a duration needs.
  private func makeProject(seconds: Int) throws -> RecordingProjectRef {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("clingfy_gif_cap_\(UUID().uuidString)")
    let projectRoot = root.appendingPathComponent(
      RecordingProjectPaths.projectDirectoryName(for: "rec_gif_cap"), isDirectory: true)
    addTeardownBlock { try? fm.removeItem(at: root) }
    for directory in [
      RecordingProjectPaths.captureDirectoryURL(for: projectRoot),
      RecordingProjectPaths.postDirectoryURL(for: projectRoot),
      RecordingProjectPaths.derivedDirectoryURL(for: projectRoot),
    ] {
      try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    var manifest = RecordingProjectManifest.create(
      projectId: "rec_gif_cap", displayName: "Clingfy Test", includeCamera: false)
    manifest.updateStatus(.ready)
    try manifest.write(to: RecordingProjectPaths.manifestURL(for: projectRoot))

    let url = RecordingProjectPaths.screenVideoURL(for: projectRoot)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
      ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
      ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    for frame in [0, seconds * 30] {
      var buffer: CVPixelBuffer?
      CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
      guard let buffer else { continue }
      while !input.isReadyForMoreMediaData { usleep(1000) }
      adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
    }
    input.markAsFinished()
    let written = expectation(description: "screen.mov written")
    writer.finishWriting { written.fulfill() }
    wait(for: [written], timeout: 30)
    return try RecordingProjectRef.open(projectPath: projectRoot.path)
  }

  /// Runs an export whose folder does not exist, so anything that passes the
  /// GIF cap stops at the destination check instead of rendering.
  private func exportError(
    _ project: RecordingProjectRef, format: String, clips: [ClipKeptRange] = []
  ) -> FlutterError? {
    var input = makeAnyInput(
      projectPath: project.rootURL.path, format: format,
      directoryOverride: "/tmp/clingfy-missing-\(UUID().uuidString)")
    input.clips = clips
    var error: FlutterError?
    let done = expectation(description: "export answered")
    ExportEngine().export(input: input, dependencies: makeDeps { _ in project }) { reply in
      error = reply as? FlutterError
      done.fulfill()
    }
    wait(for: [done], timeout: 10)
    return error
  }

  /// A GIF past the cap is refused before anything is resolved or rendered,
  /// with the lengths Flutter needs for its message.
  func testAGifOverTheLengthCapIsRefusedBeforeRendering() throws {
    let error = exportError(try makeProject(seconds: 61), format: "gif")
    XCTAssertEqual(error?.code, NativeErrorCode.exportGifTooLong)
    let details = try XCTUnwrap(error?.details as? [String: Any])
    XCTAssertEqual(details["maxDurationMs"] as? Int, 60_000)
    XCTAssertGreaterThanOrEqual(details["durationMs"] as? Int ?? 0, 61_000)
  }

  /// The cap is on the EXPORTED length: a long recording cut under it exports.
  func testALongRecordingTrimmedUnderTheCapIsNotRefused() throws {
    let error = exportError(
      try makeProject(seconds: 61), format: "gif",
      clips: [ClipKeptRange(sourceInMs: 0, sourceOutMs: 20_000)])
    XCTAssertEqual(error?.code, NativeErrorCode.exportError, "stopped by the missing folder instead")
  }

  /// Only GIFs are capped.
  func testAVideoExportOverTheGifCapIsNotRefused() throws {
    let error = exportError(try makeProject(seconds: 61), format: "mov")
    XCTAssertEqual(error?.code, NativeErrorCode.exportError)
  }

  // MARK: - GIF export measurement (opt-in)

  /// A real project whose screen.mov is `seconds` of `size` at 30 fps, with a
  /// bar that moves every frame so no two frames are alike.
  private func makeMovingProject(seconds: Int, size: CGSize) throws -> RecordingProjectRef {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("clingfy_gif_measure_\(UUID().uuidString)")
    let projectRoot = root.appendingPathComponent(
      RecordingProjectPaths.projectDirectoryName(for: "rec_gif_measure"), isDirectory: true)
    addTeardownBlock { try? fm.removeItem(at: root) }
    for directory in [
      RecordingProjectPaths.captureDirectoryURL(for: projectRoot),
      RecordingProjectPaths.postDirectoryURL(for: projectRoot),
      RecordingProjectPaths.derivedDirectoryURL(for: projectRoot),
    ] {
      try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    var manifest = RecordingProjectManifest.create(
      projectId: "rec_gif_measure", displayName: "Clingfy Test", includeCamera: false)
    manifest.updateStatus(.ready)
    try manifest.write(to: RecordingProjectPaths.manifestURL(for: projectRoot))

    let url = RecordingProjectPaths.screenVideoURL(for: projectRoot)
    let width = Int(size.width)
    let height = Int(size.height)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
      ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
      ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    let frames = seconds * 30
    for frame in 0..<frames {
      var buffer: CVPixelBuffer?
      CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
      guard let buffer else { continue }
      CVPixelBufferLockBaseAddress(buffer, [])
      if let base = CVPixelBufferGetBaseAddress(buffer) {
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        memset(base, 0x30, rowBytes * height)
        let barX = (frame * 8) % max(width - 64, 1)
        for y in 0..<height {
          let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
          for x in barX..<(barX + 64) {
            row[x * 4] = 0x20
            row[x * 4 + 1] = 0xC0
            row[x * 4 + 2] = 0xF0
            row[x * 4 + 3] = 0xFF
          }
        }
      }
      CVPixelBufferUnlockBaseAddress(buffer, [])
      while !input.isReadyForMoreMediaData { usleep(1000) }
      adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
    }
    input.markAsFinished()
    let written = expectation(description: "screen.mov written")
    writer.finishWriting { written.fulfill() }
    wait(for: [written], timeout: 120)
    return try RecordingProjectRef.open(projectPath: projectRoot.path)
  }

  /// Exports `project` through the engine and returns the output path.
  private func exportPath(
    _ project: RecordingProjectRef, format: String, clips: [ClipKeptRange] = [], folder: URL,
    grade: ColorGrade = .identity
  ) throws -> String {
    var input = makeAnyInput(
      projectPath: project.rootURL.path, format: format, directoryOverride: folder.path,
      filename: "out-\(format)-\(UUID().uuidString.prefix(6))")
    input.clips = clips
    input.colorGrade = grade
    var reply: Any?
    let done = expectation(description: "\(format) export")
    ExportEngine().export(input: input, dependencies: makeDeps { _ in project }) { value in
      reply = value
      done.fulfill()
    }
    wait(for: [done], timeout: 300)
    return try XCTUnwrap(reply as? String, "\(format) export failed: \(String(describing: reply))")
  }

  private struct DecodedGif {
    var size: CGSize
    var delays: [Double]
    var frames: [[UInt8]]
  }

  private func decodeGif(_ path: String) throws -> DecodedGif {
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
    var result = DecodedGif(size: .zero, delays: [], frames: [])
    for index in 0..<CGImageSourceGetCount(source) {
      let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
      let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
      result.delays.append(
        (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
          ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? -1)
      let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
      result.size = CGSize(width: image.width, height: image.height)
      var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
      let context = try XCTUnwrap(
        CGContext(
          data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
          bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      result.frames.append(pixels)
    }
    return result
  }

  /// The pre-#single-pass path, as the reference: render a video, then convert
  /// it with `GifExportSession`, exactly as GIF export used to.
  private func twoPassGif(
    _ project: RecordingProjectRef, clips: [ClipKeptRange], folder: URL,
    grade: ColorGrade = .identity
  ) throws -> String {
    let mov = try exportPath(project, format: "mov", clips: clips, folder: folder, grade: grade)
    let gifURL = folder.appendingPathComponent("two-pass-\(UUID().uuidString.prefix(6)).gif")
    var outcome: Result<URL, Error>?
    let done = expectation(description: "two-pass transcode")
    GifExportSession().run(sourceVideoURL: URL(fileURLWithPath: mov), outputURL: gifURL, onProgress: nil) {
      outcome = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 120)
    return try XCTUnwrap(try outcome?.get()).path
  }

  /// One pass must give the same GIF as the old render-then-convert, apart from
  /// the codec loss it no longer has: same frames, same delays, same size, and
  /// pixels within the H.264 round trip's error.
  private func assertSinglePassMatchesTwoPass(
    clips: [ClipKeptRange], grade: ColorGrade = .identity
  ) throws {
    let project = try makeMovingProject(seconds: 2, size: CGSize(width: 640, height: 360))
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("clingfy_gif_parity_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

    let single = try decodeGif(
      try exportPath(project, format: "gif", clips: clips, folder: folder, grade: grade))
    let reference = try decodeGif(
      try twoPassGif(project, clips: clips, folder: folder, grade: grade))

    XCTAssertEqual(single.size, reference.size, "same GIF size")
    XCTAssertEqual(single.frames.count, reference.frames.count, "same kept frames")
    XCTAssertEqual(single.delays, reference.delays, "same frame timing")
    for (index, (a, b)) in zip(single.frames, reference.frames).enumerated() {
      var total = 0
      for i in stride(from: 0, to: a.count, by: 4) {
        total += abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1]))
          + abs(Int(a[i + 2]) - Int(b[i + 2]))
      }
      let meanPerChannel = Double(total) / Double(a.count / 4 * 3)
      XCTAssertLessThan(meanPerChannel, 4.0, "frame \(index) differs beyond codec error")
    }
  }

  func testSinglePassGifMatchesTheTwoPassGif() throws {
    try assertSinglePassMatchesTwoPass(clips: [])
  }

  func testSinglePassGifMatchesTheTwoPassGifWithCuts() throws {
    try assertSinglePassMatchesTwoPass(clips: [
      ClipKeptRange(sourceInMs: 0, sourceOutMs: 600),
      ClipKeptRange(sourceInMs: 1000, sourceOutMs: 1800),
    ])
  }

  /// The grade is applied in the shared loop, before the GIF takes the frame.
  func testSinglePassGifMatchesTheTwoPassGifWithAColourGrade() throws {
    var grade = ColorGrade.identity
    grade.exposure = 0.3
    grade.temperature = 0.4
    try assertSinglePassMatchesTwoPass(clips: [], grade: grade)
  }

  /// Reordered clips take the per-range reader path.
  func testSinglePassGifMatchesTheTwoPassGifWithReorderedClips() throws {
    try assertSinglePassMatchesTwoPass(clips: [
      ClipKeptRange(sourceInMs: 1000, sourceOutMs: 1800),
      ClipKeptRange(sourceInMs: 0, sourceOutMs: 600),
    ])
  }

  /// No temp video is written for a GIF any more.
  func testASinglePassGifWritesNoTempVideo() throws {
    let project = try makeMovingProject(seconds: 1, size: CGSize(width: 320, height: 180))
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("clingfy_gif_notemp_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    let tempDir = FileManager.default.temporaryDirectory.path
    func gifSources() -> Set<String> {
      Set(((try? FileManager.default.contentsOfDirectory(atPath: tempDir)) ?? [])
        .filter { $0.hasPrefix("clingfy-gif-source-") })
    }
    let before = gifSources()
    var seen = Set<String>()
    let poll = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
      seen.formUnion(gifSources())
    }
    _ = try exportPath(project, format: "gif", folder: folder)
    poll.invalidate()
    XCTAssertTrue(seen.subtracting(before).isEmpty, "a temp video was written: \(seen)")
    XCTAssertTrue(
      ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        .allSatisfy { $0.hasSuffix(".gif") }, "only the GIF lands in the folder")
  }

  /// Wall time, peak temp-file bytes and output size of a real GIF export.
  /// Opt-in: run with `TEST_RUNNER_CLINGFY_MEASURE_GIF=1 xcodebuild test ...`.
  /// Prints one `GIF_MEASURE` line; asserts only that the export succeeded.
  func testMeasureGifExport() throws {
    guard ProcessInfo.processInfo.environment["CLINGFY_MEASURE_GIF"] == "1" else {
      throw XCTSkip("Opt-in measurement; set TEST_RUNNER_CLINGFY_MEASURE_GIF=1")
    }
    let project = try makeMovingProject(seconds: 10, size: CGSize(width: 1920, height: 1080))
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("clingfy_gif_measure_out_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

    let tempDir = FileManager.default.temporaryDirectory
    func tempGifSourceBytes() -> Int {
      let names = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
      return names.filter { $0.hasPrefix("clingfy-gif-source-") }.reduce(0) { total, name in
        let size = (try? FileManager.default.attributesOfItem(
          atPath: tempDir.appendingPathComponent(name).path)[.size] as? NSNumber)?.intValue ?? 0
        return total + size
      }
    }
    var peakTempBytes = 0
    let poll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
      peakTempBytes = max(peakTempBytes, tempGifSourceBytes())
    }
    defer { poll.invalidate() }

    var input = makeAnyInput(
      projectPath: project.rootURL.path, format: "gif", directoryOverride: folder.path)
    input.gifSize = "large"
    var reply: Any?
    let done = expectation(description: "export finished")
    let started = Date()
    ExportEngine().export(input: input, dependencies: makeDeps { _ in project }) { value in
      reply = value
      done.fulfill()
    }
    wait(for: [done], timeout: 600)
    let elapsed = Date().timeIntervalSince(started)
    let path = try XCTUnwrap(reply as? String, "export failed: \(String(describing: reply))")
    let gifBytes =
      (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
    let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
    let frames = source.map { CGImageSourceGetCount($0) } ?? 0
    let line =
      "GIF_MEASURE elapsed=\(String(format: "%.2f", elapsed))s peakTempMovBytes=\(peakTempBytes) "
      + "gifBytes=\(gifBytes) frames=\(frames)"
    NSLog("%@", line)
    try line.write(
      to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gif_measure.txt"),
      atomically: true, encoding: .utf8)
  }

  // MARK: - cancel() passthrough
  //
  // `ExportEngine.cancel()` is a one-line passthrough to
  // `LetterboxExporter.cancel()`. `LetterboxExporter` is `final` and the
  // engine doesn't take a protocol abstraction, so we don't unit-test this
  // directly — the existing manual smoke + facade-side `cancelExport()`
  // flow are the safety net. The test below exists only to assert
  // `engine.cancel()` is a no-throw call on the canonical init path; a
  // future PR that introduces an `Exporting` protocol can replace this
  // with a counted-invocation assertion.

  func testCancelDoesNotCrashOnEngineFromDefaultInit() {
    let engine = ExportEngine()
    engine.cancel()  // no-op when no export is in flight — must not throw or crash
  }
  // MARK: - Output name collision, video + sidecars

  private func makeTempFolder() -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("clingfy_names_\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func touch(_ folder: URL, _ name: String) {
    FileManager.default.createFile(
      atPath: folder.appendingPathComponent(name).path, contents: Data())
  }

  /// The case that silently destroyed a user's subtitles.
  ///
  /// Export A as "Demo" to MOV with subtitles, then B as "Demo" to MP4. The
  /// VIDEO does not clash -- different extension -- so the old walk was happy,
  /// wrote `Demo.mp4`, and the Dart side then replaced `Demo.srt` with B's
  /// cues while it still sat beside A's `Demo.mov`, describing the wrong
  /// video.
  func testASidecarClashMovesTheVideoToo() throws {
    let folder = makeTempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    touch(folder, "Demo.mov")
    touch(folder, "Demo.srt")
    touch(folder, "Demo.vtt")

    let url = ExportEngine.resolveOutputURL(
      folder: folder, stem: "Demo", ext: "mp4", writesSubtitleSidecars: true)

    XCTAssertEqual(
      url.lastPathComponent, "Demo (1).mp4",
      "the video must move even though no .mp4 existed, because its sidecars "
        + "have to keep its stem to be found by a player")
  }

  /// The other half: renaming only the sidecar would "avoid" the clash and
  /// produce a subtitle file nothing loads. The video name is what carries it.
  func testTheChosenStemIsFreeForEveryExtensionAtOnce() throws {
    let folder = makeTempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    touch(folder, "Demo.mp4")
    touch(folder, "Demo (1).srt")

    let url = ExportEngine.resolveOutputURL(
      folder: folder, stem: "Demo", ext: "mp4", writesSubtitleSidecars: true)

    XCTAssertEqual(
      url.lastPathComponent, "Demo (2).mp4",
      "(1) was unusable because its .srt was taken, so the whole trio skips to (2)")
  }

  /// Without sidecars the walk must not widen: an unrelated `.srt` in the
  /// folder is none of this export's business.
  func testAnExportWithNoSidecarsIgnoresThem() throws {
    let folder = makeTempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    touch(folder, "Demo.srt")

    let url = ExportEngine.resolveOutputURL(
      folder: folder, stem: "Demo", ext: "mp4", writesSubtitleSidecars: false)

    XCTAssertEqual(
      url.lastPathComponent, "Demo.mp4",
      "a GIF or a burn-in-only export writes no sidecar, so an existing one "
        + "must not push the video's name around")
  }

  func testAFreeNameIsUsedUnchanged() throws {
    let folder = makeTempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = ExportEngine.resolveOutputURL(
      folder: folder, stem: "Demo", ext: "mp4", writesSubtitleSidecars: true)
    XCTAssertEqual(url.lastPathComponent, "Demo.mp4")
  }

}
