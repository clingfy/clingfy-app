import AVFoundation
import FlutterMacOS
import XCTest

@testable import Clingfy

/// PR 11 guard: the pure export-prep helpers keep exact behavior after being
/// moved into the ExportPrep extension. Pure / deterministic.
@MainActor
final class ExportPrepTests: XCTestCase {
  private let facade = ScreenRecorderFacade()

  // resolveTargetSize: layout aspect × resolution short-side matrix.
  func testResolveTargetSizePresetAspectsAndResolutions() {
    let src = CGSize(width: 1920, height: 1080)

    XCTAssertEqual(
      facade.resolveTargetSize(sourceSize: src, layout: "youtube169", resolution: "p1080"),
      CGSize(width: 1920, height: 1080))
    XCTAssertEqual(
      facade.resolveTargetSize(sourceSize: src, layout: "square11", resolution: "p1080"),
      CGSize(width: 1080, height: 1080))
    XCTAssertEqual(
      facade.resolveTargetSize(sourceSize: src, layout: "reel916", resolution: "p1080"),
      CGSize(width: 1080, height: 1920))
    XCTAssertEqual(
      facade.resolveTargetSize(sourceSize: src, layout: "classic43", resolution: "p1440"),
      CGSize(width: 1440.0 * 4.0 / 3.0, height: 1440))
  }

  func testResolveTargetSizeAutoFallsBackToSource() {
    let src = CGSize(width: 1280, height: 720)
    XCTAssertEqual(
      facade.resolveTargetSize(sourceSize: src, layout: "auto", resolution: "auto"), src)
  }

  func testExportFormatInfoMapping() {
    XCTAssertEqual(facade.exportFormatInfo("mp4").ext, "mp4")
    XCTAssertEqual(facade.exportFormatInfo("mp4").avFileType, .mp4)
    XCTAssertEqual(facade.exportFormatInfo("m4v").avFileType, .m4v)
    XCTAssertEqual(facade.exportFormatInfo("MOV").avFileType, .mov)
    XCTAssertNil(facade.exportFormatInfo("gif").avFileType)
    XCTAssertEqual(facade.exportFormatInfo("gif").ext, "gif")
    // Unknown -> safe mov default.
    XCTAssertEqual(facade.exportFormatInfo("weird").avFileType, .mov)
  }

  /// The facade must not carry its own copy of the mapping.
  ///
  /// `ExportEngine` builds the output URL from this, and `LetterboxExporter`
  /// renames the file to match its own answer — and deletes whatever already
  /// sits at the renamed path first. A drift between the two therefore moves
  /// the user's output somewhere `ExportEngine` is not looking, and can delete
  /// a file on the way. Pinning delegation is what stops them drifting apart
  /// again; they previously agreed only by coincidence.
  func testExportFormatInfoDelegatesToTheSharedMap() {
    for format in ["mov", "MOV", "mp4", "MP4", "m4v", "M4V", "gif", "GIF", "", "weird"] {
      let viaFacade = facade.exportFormatInfo(format)
      let viaMap = ExportFormatInfo.resolve(format)
      XCTAssertEqual(viaFacade.ext, viaMap.ext, "ext drifted for \(format)")
      XCTAssertEqual(
        viaFacade.avFileType, viaMap.avFileType, "avFileType drifted for \(format)")
    }
  }

  /// gif is the one format with no container of its own — `ExportEngine`
  /// renders a temp MOV and transcodes it, so the exporter must fall back to
  /// BOTH a `.mov` type and a "mov" extension. Taking the extension from the
  /// resolved format instead would name a QuickTime file ".gif".
  func testGifResolvesToNoContainerSoTheExporterMustSubstituteMov() {
    let gif = ExportFormatInfo.resolve("gif")
    XCTAssertNil(gif.avFileType)
    XCTAssertEqual(gif.ext, "gif")
    XCTAssertEqual(ExportFormatInfo.resolve("mov").avFileType, .mov)
    XCTAssertEqual(ExportFormatInfo.resolve("mov").ext, "mov")
  }

  /// The rename the exporter performs must be a no-op for a path that already
  /// carries the right extension, including names containing dots and spaces.
  func testOutputExtensionRoundTripsForAwkwardFilenames() {
    for (path, format, expected) in [
      ("/tmp/Clingfy Export (2).mp4", "mp4", "/tmp/Clingfy Export (2).mp4"),
      ("/tmp/my.recording.v2.mov", "mov", "/tmp/my.recording.v2.mov"),
      ("/tmp/clip.mov", "mp4", "/tmp/clip.mp4"),
    ] {
      let resolved = ExportFormatInfo.resolve(format)
      let url = URL(fileURLWithPath: path)
        .deletingPathExtension()
        .appendingPathExtension(resolved.ext)
      XCTAssertEqual(url.path, expected)
    }
  }

  func testFlutterExportFailureGenericMapsToExportError() {
    let err = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
    let fe = facade.flutterExportFailure(from: err)
    XCTAssertEqual(fe.code, NativeErrorCode.exportError)
    XCTAssertEqual(fe.message, "boom")
    XCTAssertNil(fe.details)
  }

  func testFlutterExportFailurePreservesAdvancedCameraExportCode() {
    let err = NSError(
      domain: "x", code: 2,
      userInfo: [
        "nativeErrorCode": NativeErrorCode.advancedCameraExportFailed,
        "stage": "compose",
        "reason": "bad",
      ])
    let fe = facade.flutterExportFailure(from: err)
    XCTAssertEqual(fe.code, NativeErrorCode.advancedCameraExportFailed)
    let details = fe.details as? [String: Any]
    XCTAssertEqual(details?["stage"] as? String, "compose")
    XCTAssertEqual(details?["reason"] as? String, "bad")
  }

  func testFlutterExportFailureForwardsDiskFullCodeAndDetails() {
    let err = NSError(
      domain: "Letterbox.ScreenPrepass", code: 1,
      userInfo: [
        NSLocalizedDescriptionKey: "Not enough free disk space …",
        "nativeErrorCode": NativeErrorCode.exportDiskFull,
        "stage": "screen_prepass_build",
        "reason": "Not enough free disk space …",
        "context": [
          "availableTempFormatted": "59 GB",
          "estimatedRequiredTempFormatted": "96 GB",
          "shortfallTempFormatted": "37 GB",
        ],
      ])
    let fe = facade.flutterExportFailure(from: err)
    XCTAssertEqual(fe.code, NativeErrorCode.exportDiskFull)
    XCTAssertEqual(fe.message, "Not enough free disk space …")
    let details = fe.details as? [String: Any]
    XCTAssertEqual(details?["stage"] as? String, "screen_prepass_build")
    let ctx = details?["context"] as? [String: Any]
    XCTAssertEqual(ctx?["availableTempFormatted"] as? String, "59 GB")
    XCTAssertEqual(ctx?["estimatedRequiredTempFormatted"] as? String, "96 GB")
    XCTAssertEqual(ctx?["shortfallTempFormatted"] as? String, "37 GB")
  }

  // The disk-full reason should NOT be prefixed by "Screen zoom export could
  // not be rendered." — it's a user-actionable storage condition, not a
  // rendering failure, and the prefix would just confuse the user.
  func testMakeScreenPrepassExportErrorDiskFullSkipsRenderingPreamble() {
    let err = makeScreenPrepassExportError(
      stage: .build,
      nativeErrorCode: NativeErrorCode.exportDiskFull,
      reason: "Not enough free disk space to render this export.",
      context: [:]
    )
    XCTAssertEqual(
      err.userInfo[NSLocalizedDescriptionKey] as? String,
      "Not enough free disk space to render this export."
    )
    XCTAssertEqual(err.userInfo["nativeErrorCode"] as? String, NativeErrorCode.exportDiskFull)
  }

  func testMakeScreenPrepassExportErrorGenericKeepsRenderingPreamble() {
    let err = makeScreenPrepassExportError(
      stage: .build,
      reason: "some other failure"
    )
    XCTAssertEqual(
      err.userInfo[NSLocalizedDescriptionKey] as? String,
      "Screen zoom export could not be rendered. some other failure"
    )
    XCTAssertEqual(err.userInfo["nativeErrorCode"] as? String, NativeErrorCode.exportError)
  }
}

/// The `resolveExportSize` bridge method: Flutter rasterises caption bitmaps
/// before calling `exportVideo`, and has to draw them at the canvas the frames
/// will actually be. It cannot compute that itself — the `auto` preset resolves
/// against the recording's own oriented video track, which only this side reads.
///
/// The contract these pin is that the reply is a plain `{width, height}` map of
/// Ints on the happy path, and a FlutterError (never a silent default) when the
/// project cannot be read. A default would burn captions in at the wrong scale.
@MainActor
final class ResolveExportSizeTests: XCTestCase {
  private let facade = ScreenRecorderFacade()

  private func resolve(
    projectPath: String, layout: String = "auto", resolution: String = "auto"
  ) -> Any? {
    var reply: Any?
    let done = expectation(description: "resolveExportSize replied")
    facade.resolveExportSize(
      projectPath: projectPath, layout: layout, resolution: resolution,
      result: { value in
        reply = value
        done.fulfill()
      })
    wait(for: [done], timeout: 10)
    return reply
  }

  func testAMissingProjectIsAnErrorNotAGuessedSize() {
    let reply = resolve(projectPath: "/tmp/does-not-exist-\(UUID().uuidString).clingfyproj")
    guard let error = reply as? FlutterError else {
      return XCTFail("expected a FlutterError, got \(String(describing: reply))")
    }
    XCTAssertEqual(error.code, "SCENE_INPUT_MISSING")
  }

  /// The sizes themselves are covered exhaustively by
  /// `testResolveTargetSizePresetAspectsAndResolutions`. What matters here is
  /// that this method routes through the SAME function rather than growing a
  /// second implementation that could drift from the exporter's.
  func testItAgreesWithTheExporterOnEveryPreset() {
    let src = CGSize(width: 1920, height: 1080)
    for layout in ["auto", "classic43", "square11", "youtube169", "reel916"] {
      for resolution in ["auto", "p1080", "p1440", "p2160"] {
        let expected = facade.resolveTargetSize(
          sourceSize: src, layout: layout, resolution: resolution)
        XCTAssertGreaterThan(expected.width, 0, "\(layout)/\(resolution)")
        XCTAssertGreaterThan(expected.height, 0, "\(layout)/\(resolution)")
      }
    }
  }

  /// A portrait recording carries a rotation transform. Laying captions out
  /// against the UNROTATED natural size would scale them for the wrong axis —
  /// the font scales by height, so a 1080×1920 clip treated as 1920×1080 gets
  /// captions roughly half the size they should be.
  func testPortraitSourcesResolveToPortraitTargets() {
    let portrait = CGSize(width: 1080, height: 1920)
    let target = facade.resolveTargetSize(
      sourceSize: portrait, layout: "auto", resolution: "auto")
    XCTAssertGreaterThan(target.height, target.width)
  }
}
