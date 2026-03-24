import CoreGraphics
import XCTest

@testable import Clingfy

final class OverlayUpdateDeduperTests: XCTestCase {
  func testFirstWindowIDSendPassesAndDuplicateIsSuppressed() {
    var deduper = OverlayUpdateDeduper()

    XCTAssertTrue(deduper.shouldSend(27503))
    XCTAssertFalse(deduper.shouldSend(27503))
  }

  func testDetachToNilSendsOnceThenSuppressesRepeatNil() {
    var deduper = OverlayUpdateDeduper()

    XCTAssertTrue(deduper.shouldSend(27503))
    XCTAssertTrue(deduper.shouldSend(nil))
    XCTAssertFalse(deduper.shouldSend(nil))
  }

  func testResetAllowsSameValueToSendAgain() {
    var deduper = OverlayUpdateDeduper()

    XCTAssertTrue(deduper.shouldSend(nil))
    XCTAssertFalse(deduper.shouldSend(nil))

    deduper.reset()

    XCTAssertTrue(deduper.shouldSend(nil))
    XCTAssertFalse(deduper.shouldSend(nil))
  }

  func testOverlayRefreshPlanReusesVisibleWindowOnSameDisplayAndSize() {
    let plan = OverlayRefreshPlan.make(
      isShowing: true,
      currentTargetDisplayID: 1,
      desiredTargetDisplayID: 1,
      currentPreferredSize: 200.0,
      desiredSize: 200.0
    )

    XCTAssertEqual(plan.action, .reuseVisibleWindow)
  }

  func testOverlayRefreshPlanResizesVisibleWindowWhenOnlySizeChanges() {
    let plan = OverlayRefreshPlan.make(
      isShowing: true,
      currentTargetDisplayID: 1,
      desiredTargetDisplayID: 1,
      currentPreferredSize: 200.0,
      desiredSize: 240.0
    )

    XCTAssertEqual(plan.action, .resize)
  }

  func testOverlayRefreshPlanShowsWhenDisplayChangesOrWindowIsHidden() {
    let displayChangedPlan = OverlayRefreshPlan.make(
      isShowing: true,
      currentTargetDisplayID: 1,
      desiredTargetDisplayID: 2,
      currentPreferredSize: 200.0,
      desiredSize: 200.0
    )
    let hiddenPlan = OverlayRefreshPlan.make(
      isShowing: false,
      currentTargetDisplayID: 1,
      desiredTargetDisplayID: 1,
      currentPreferredSize: 200.0,
      desiredSize: 200.0
    )

    XCTAssertEqual(displayChangedPlan.action, .show)
    XCTAssertEqual(hiddenPlan.action, .show)
  }
}
