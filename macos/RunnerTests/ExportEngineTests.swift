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
    directoryOverride: String? = nil
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
      filename: nil,
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
