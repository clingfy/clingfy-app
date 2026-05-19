import AVFoundation
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
}
