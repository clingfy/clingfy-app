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
}
