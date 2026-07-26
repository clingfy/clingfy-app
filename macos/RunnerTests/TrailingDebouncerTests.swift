import XCTest

@testable import Clingfy

final class TrailingDebouncerTests: XCTestCase {

  /// The reason this type exists: one dock connect emits several screen
  /// notifications, and Flutter should re-enumerate displays once.
  func testABurstCollapsesToASingleTrailingCall() {
    let debouncer = TrailingDebouncer(delay: 0.05)
    let fired = expectation(description: "fired")
    var callCount = 0

    for _ in 0..<8 {
      debouncer.schedule {
        callCount += 1
        fired.fulfill()
      }
    }

    wait(for: [fired], timeout: 2)
    XCTAssertEqual(callCount, 1)
  }

  /// Trailing, not leading — the state worth reporting is the one after the
  /// burst settles. A leading debouncer would report the half-attached
  /// configuration and never correct it.
  func testTheLastScheduledActionIsTheOneThatRuns() {
    let debouncer = TrailingDebouncer(delay: 0.05)
    let fired = expectation(description: "fired")
    var observed: String?

    debouncer.schedule { observed = "first" }
    debouncer.schedule { observed = "second" }
    debouncer.schedule {
      observed = "last"
      fired.fulfill()
    }

    wait(for: [fired], timeout: 2)
    XCTAssertEqual(observed, "last")
  }

  func testCancelPreventsAPendingCall() {
    let debouncer = TrailingDebouncer(delay: 0.05)
    var callCount = 0

    debouncer.schedule { callCount += 1 }
    debouncer.cancel()

    let settled = expectation(description: "settled")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
    wait(for: [settled], timeout: 2)

    XCTAssertEqual(callCount, 0)
  }

  /// Separated bursts must each produce their own call — coalescing must not
  /// swallow a genuinely new event.
  func testSeparatedBurstsEachFire() {
    let debouncer = TrailingDebouncer(delay: 0.05)
    var callCount = 0

    let first = expectation(description: "first")
    debouncer.schedule {
      callCount += 1
      first.fulfill()
    }
    wait(for: [first], timeout: 2)

    let second = expectation(description: "second")
    debouncer.schedule {
      callCount += 1
      second.fulfill()
    }
    wait(for: [second], timeout: 2)

    XCTAssertEqual(callCount, 2)
  }
}
