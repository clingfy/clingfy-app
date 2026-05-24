import XCTest

@testable import Clingfy

/// PR 8 guard: getZoomSegments still resolves and keeps its empty-result
/// fallback after being moved into the ZoomQueryService extension.
/// Deterministic / side-effect-free (unknown project → loadRecordingProject
/// returns nil → []).
@MainActor
final class ZoomQueryServiceTests: XCTestCase {
  func testUnknownProjectYieldsEmptySegments() {
    let facade = ScreenRecorderFacade()
    var captured: Any?
    facade.getZoomSegments(projectPath: "/no/such/project") { captured = $0 }

    let segments = captured as? [[String: Any]]
    XCTAssertNotNil(segments)
    XCTAssertTrue(segments?.isEmpty ?? false)
  }
}
