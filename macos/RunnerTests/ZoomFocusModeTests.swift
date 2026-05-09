import XCTest

@testable import Clingfy

final class ZoomFocusModeTests: XCTestCase {

  // MARK: - ZoomFocusMode wire parsing

  func testFocusModeMissingDefaultsToFollowCursor() {
    XCTAssertEqual(ZoomFocusMode(wireValue: nil), .followCursor)
  }

  func testFocusModeUnknownStringDefaultsToFollowCursor() {
    XCTAssertEqual(ZoomFocusMode(wireValue: "garbage"), .followCursor)
  }

  func testFocusModeFollowCursorRoundTrip() {
    XCTAssertEqual(ZoomFocusMode(wireValue: "followCursor"), .followCursor)
  }

  func testFocusModeFixedTargetRoundTrip() {
    XCTAssertEqual(ZoomFocusMode(wireValue: "fixedTarget"), .fixedTarget)
  }

  // MARK: - ZoomFixedTarget parsing

  func testFixedTargetParseValidPoint() {
    let target = ZoomFixedTarget.parse(["dx": 0.25, "dy": 0.75])
    XCTAssertEqual(target?.dx, 0.25)
    XCTAssertEqual(target?.dy, 0.75)
  }

  func testFixedTargetParseClampsToZeroOne() {
    let highTarget = ZoomFixedTarget.parse(["dx": 1.5, "dy": 2.0])
    XCTAssertEqual(highTarget?.dx, 1.0)
    XCTAssertEqual(highTarget?.dy, 1.0)

    let lowTarget = ZoomFixedTarget.parse(["dx": -0.5, "dy": -2.0])
    XCTAssertEqual(lowTarget?.dx, 0.0)
    XCTAssertEqual(lowTarget?.dy, 0.0)
  }

  func testFixedTargetParseRejectsMalformed() {
    XCTAssertNil(ZoomFixedTarget.parse(nil))
    XCTAssertNil(ZoomFixedTarget.parse("not a map"))
    XCTAssertNil(ZoomFixedTarget.parse(["dx": "a", "dy": "b"]))
  }

  // MARK: - ZoomTimelineSegment construction

  func testFollowCursorSegmentDoesNotKeepFixedTarget() {
    let seg = ZoomTimelineSegment(
      startMs: 1000,
      endMs: 2000,
      focusMode: .followCursor,
      fixedTarget: ZoomFixedTarget(dx: 0.4, dy: 0.6)
    )
    XCTAssertNil(seg.fixedTarget,
      "followCursor segment must drop any provided fixedTarget")
  }

  func testFixedTargetSegmentDefaultsToCenterWhenMissing() {
    let seg = ZoomTimelineSegment(
      startMs: 1000,
      endMs: 2000,
      focusMode: .fixedTarget,
      fixedTarget: nil
    )
    XCTAssertEqual(seg.fixedTarget?.dx, 0.5)
    XCTAssertEqual(seg.fixedTarget?.dy, 0.5)
  }

  func testFixedTargetSegmentRoundTripsExplicitTarget() {
    let seg = ZoomTimelineSegment(
      startMs: 1000,
      endMs: 2000,
      focusMode: .fixedTarget,
      fixedTarget: ZoomFixedTarget(dx: 0.2, dy: 0.8)
    )
    XCTAssertEqual(seg.fixedTarget?.dx, 0.2)
    XCTAssertEqual(seg.fixedTarget?.dy, 0.8)
  }

  func testLegacyConstructorDefaultsToFollowCursor() {
    let seg = ZoomTimelineSegment(startMs: 0, endMs: 1000)
    XCTAssertEqual(seg.focusMode, .followCursor)
    XCTAssertNil(seg.fixedTarget)
  }
}
