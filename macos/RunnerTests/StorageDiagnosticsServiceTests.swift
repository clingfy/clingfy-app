import XCTest

@testable import Clingfy

/// PR 7 guard: getCaptureDiagnostics / getStorageSnapshot still resolve and
/// behave after being moved into the StorageDiagnosticsService extension.
/// Read-only (disk-capacity / snapshot queries only) — no recording started.
@MainActor
final class StorageDiagnosticsServiceTests: XCTestCase {

  func testCaptureDiagnosticsPayloadHasBackendAndFps() {
    let facade = ScreenRecorderFacade()
    var payload: [String: Any]?
    facade.getCaptureDiagnostics { payload = $0 as? [String: Any] }

    let p = try? XCTUnwrap(payload)
    XCTAssertNotNil(p?["backend"] as? String)
    XCTAssertEqual(p?["captureFps"] as? Int, 30)
  }

  func testStorageSnapshotReturnsNonEmptyMap() {
    let facade = ScreenRecorderFacade()
    var snapshot: [String: Any]?
    facade.getStorageSnapshot { snapshot = $0 as? [String: Any] }

    XCTAssertFalse((snapshot ?? [:]).isEmpty)
  }

  func testCaptureDestinationURLFallsBackToTempWhenNoActiveProject() {
    let facade = ScreenRecorderFacade()
    XCTAssertEqual(facade.currentCaptureDestinationURL(), AppPaths.tempRoot())
  }
}
