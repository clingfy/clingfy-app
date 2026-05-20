import FlutterMacOS
import XCTest

@testable import Clingfy

/// Slice 4 / PR 16 guard: the extracted camera-coordination state and the
/// pure factories reproduce the inline behavior that used to live on
/// `ScreenRecorderFacade`. Device-dependent factories
/// (`recordingDimensions(deviceID:)` /
/// `nominalFrameRate(deviceID:)`) are exercised against the real
/// `AVCaptureDevice` layer in `RunnerTests`-level integration coverage; here
/// we pin the deterministic logic.
@MainActor
final class CameraCoordinationControllerTests: XCTestCase {

  func testPendingRecordingSessionStartsNilAndRoundTrips() {
    let sut = CameraCoordinationController()
    XCTAssertNil(sut.pendingRecordingSession)

    let session = CameraRecordingSession(
      outputURL: URL(fileURLWithPath: "/tmp/raw.mov"),
      metadataURL: URL(fileURLWithPath: "/tmp/meta.json"),
      segmentDirectoryURL: URL(fileURLWithPath: "/tmp/segments"),
      deviceId: "cam-1",
      mirroredRaw: false,
      nominalFrameRate: 30,
      dimensions: CameraRecordingMetadata.Dimensions(width: 1280, height: 720))

    sut.setPendingRecordingSession(session)
    XCTAssertEqual(sut.pendingRecordingSession?.deviceId, "cam-1")
    XCTAssertEqual(sut.pendingRecordingSession?.outputURL.lastPathComponent, "raw.mov")

    sut.setPendingRecordingSession(nil)
    XCTAssertNil(sut.pendingRecordingSession)
  }

  // MARK: - Failure latch

  func testFirstFailureLatchesAndSubsequentAreSuppressed() {
    let sut = CameraCoordinationController()
    XCTAssertNil(sut.pendingFailure)

    let first = FlutterError(code: "FIRST", message: "first failure", details: nil)
    XCTAssertTrue(sut.storeFailureIfFirst(first))
    XCTAssertEqual(sut.pendingFailure?.code, "FIRST")

    let second = FlutterError(code: "SECOND", message: "later", details: nil)
    XCTAssertFalse(sut.storeFailureIfFirst(second))
    XCTAssertEqual(sut.pendingFailure?.code, "FIRST", "first-failure-wins must not be overwritten")
  }

  func testClearPendingFailureReopensLatch() {
    let sut = CameraCoordinationController()
    let e = FlutterError(code: "X", message: nil, details: nil)
    XCTAssertTrue(sut.storeFailureIfFirst(e))
    XCTAssertNotNil(sut.pendingFailure)

    sut.clearPendingFailure()
    XCTAssertNil(sut.pendingFailure)

    // After clearing, the next failure latches again.
    let after = FlutterError(code: "Y", message: nil, details: nil)
    XCTAssertTrue(sut.storeFailureIfFirst(after))
    XCTAssertEqual(sut.pendingFailure?.code, "Y")
  }

  // MARK: - terminalRecordingError truth table

  private struct StubError: Error, Equatable { let id: Int }

  func testTerminalRecordingErrorPrefersScreenError() {
    let sut = CameraCoordinationController()
    let screen = StubError(id: 1)

    // No latched camera failure — screen error wins.
    XCTAssertEqual(sut.terminalRecordingError(screenError: screen) as? StubError, screen)

    // Even when a camera failure is latched, the screen error still wins.
    _ = sut.storeFailureIfFirst(FlutterError(code: "CAM", message: nil, details: nil))
    XCTAssertEqual(sut.terminalRecordingError(screenError: screen) as? StubError, screen)
  }

  func testTerminalRecordingErrorFallsBackToCameraFailureWhenScreenIsNil() {
    let sut = CameraCoordinationController()
    XCTAssertNil(sut.terminalRecordingError(screenError: nil))

    let cam = FlutterError(code: "CAM", message: "boom", details: nil)
    _ = sut.storeFailureIfFirst(cam)
    XCTAssertEqual((sut.terminalRecordingError(screenError: nil) as? FlutterError)?.code, "CAM")
  }

  // MARK: - makeCaptureInfo gating

  func testMakeCaptureInfoReturnsNilWhenNotRecordingSeparateAsset() {
    let sut = CameraCoordinationController()
    XCTAssertNil(
      sut.makeCaptureInfo(
        projectRoot: URL(fileURLWithPath: "/tmp/x"),
        shouldRecordSeparateCameraAsset: false,
        deviceId: "cam-1",
        mirrored: false))
  }

  func testMakeCaptureInfoReturnsNilWhenProjectRootIsNil() {
    let sut = CameraCoordinationController()
    XCTAssertNil(
      sut.makeCaptureInfo(
        projectRoot: nil,
        shouldRecordSeparateCameraAsset: true,
        deviceId: "cam-1",
        mirrored: false))
  }

  func testMakeCaptureInfoPopulatesManifestWhenGated() {
    let sut = CameraCoordinationController()
    let projectRoot = URL(fileURLWithPath: "/tmp/clingfy-proj")
    let info = sut.makeCaptureInfo(
      projectRoot: projectRoot,
      shouldRecordSeparateCameraAsset: true,
      deviceId: "cam-1",
      mirrored: true)

    XCTAssertNotNil(info)
    XCTAssertEqual(info?.mode, .separateCameraAsset)
    XCTAssertEqual(info?.enabled, true)
    XCTAssertEqual(info?.deviceId, "cam-1")
    XCTAssertEqual(info?.mirroredRaw, true)
    XCTAssertEqual(info?.rawRelativePath, RecordingProjectPaths.relativeCameraRawPath)
    XCTAssertEqual(info?.metadataRelativePath, RecordingProjectPaths.relativeCameraMetadataPath)
    XCTAssertEqual(info?.segments.count, 0)
  }

  // MARK: - makeRecordingSession path wiring

  func testMakeRecordingSessionUsesProjectPathHelpers() {
    let sut = CameraCoordinationController()
    let projectRoot = URL(fileURLWithPath: "/tmp/clingfy-proj")
    let session = sut.makeRecordingSession(
      projectRoot: projectRoot, deviceId: "cam-1", mirrored: true)

    XCTAssertEqual(session.outputURL, RecordingProjectPaths.cameraRawURL(for: projectRoot))
    XCTAssertEqual(session.metadataURL, RecordingProjectPaths.cameraMetadataURL(for: projectRoot))
    XCTAssertEqual(
      session.segmentDirectoryURL,
      RecordingProjectPaths.cameraSegmentsDirectoryURL(for: projectRoot))
    XCTAssertEqual(session.rawRelativePath, RecordingProjectPaths.relativeCameraRawPath)
    XCTAssertEqual(
      session.metadataRelativePath, RecordingProjectPaths.relativeCameraMetadataPath)
    XCTAssertEqual(session.deviceId, "cam-1")
    XCTAssertTrue(session.mirroredRaw)
  }
}
