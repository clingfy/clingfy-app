import XCTest

@testable import Clingfy

final class AppWindowWatcherTests: XCTestCase {

  private func window(id: Int, app: String, title: String) -> [String: Any] {
    ["windowId": NSNumber(value: id), "appName": app, "title": title]
  }

  // MARK: - Fingerprint

  func testAnUnchangedListFingerprintsIdentically() {
    let list = [
      window(id: 1, app: "Safari", title: "Docs"),
      window(id: 2, app: "Xcode", title: "Runner"),
    ]
    XCTAssertEqual(
      AppWindowWatcher.fingerprint(list),
      AppWindowWatcher.fingerprint(list))
  }

  func testAddingOrRemovingAWindowChangesTheFingerprint() {
    let before = [window(id: 1, app: "Safari", title: "Docs")]
    let after = before + [window(id: 2, app: "Xcode", title: "Runner")]
    XCTAssertNotEqual(
      AppWindowWatcher.fingerprint(before),
      AppWindowWatcher.fingerprint(after))
  }

  /// A browser switching tabs keeps the window id but renames the entry the
  /// user is choosing between. A picker still showing the old title is wrong
  /// in a way the user can see, so the title is part of the identity.
  func testATitleChangeAloneCountsAsAChange() {
    let before = [window(id: 1, app: "Safari", title: "Docs")]
    let after = [window(id: 1, app: "Safari", title: "Inbox")]
    XCTAssertNotEqual(
      AppWindowWatcher.fingerprint(before),
      AppWindowWatcher.fingerprint(after))
  }

  func testReorderingCountsAsAChangeBecauseThePickerIsOrdered() {
    let a = [
      window(id: 1, app: "Safari", title: "Docs"),
      window(id: 2, app: "Xcode", title: "Runner"),
    ]
    let b = [
      window(id: 2, app: "Xcode", title: "Runner"),
      window(id: 1, app: "Safari", title: "Docs"),
    ]
    XCTAssertNotEqual(AppWindowWatcher.fingerprint(a), AppWindowWatcher.fingerprint(b))
  }

  // MARK: - Change reporting

  func testPollReportsOnlyRealChanges() {
    var current = [window(id: 1, app: "Safari", title: "Docs")]
    let watcher = AppWindowWatcher(enumerate: { current })
    var changes = 0
    watcher.onChanged = { changes += 1 }

    // First poll establishes the baseline.
    watcher.poll()
    let afterBaseline = changes

    watcher.poll()
    watcher.poll()
    XCTAssertEqual(changes, afterBaseline, "a static desktop must not wake Flutter")

    current.append(window(id: 2, app: "Xcode", title: "Runner"))
    watcher.poll()
    XCTAssertEqual(changes, afterBaseline + 1)

    watcher.poll()
    XCTAssertEqual(changes, afterBaseline + 1, "the same list must not re-report")
  }

  // MARK: - Ref counting

  /// The Flutter sidebar picker and the native bar popover can both be open;
  /// neither may switch the other off.
  func testWatchingStopsOnlyWhenEveryHolderHasReleased() {
    let watcher = AppWindowWatcher(enumerate: { [] })
    XCTAssertFalse(watcher.isActive)

    watcher.retain()
    XCTAssertTrue(watcher.isActive)

    watcher.retain()
    watcher.release()
    XCTAssertTrue(watcher.isActive, "one holder remains")

    watcher.release()
    XCTAssertFalse(watcher.isActive)
  }

  func testReleasingMoreThanRetainedDoesNotGoNegative() {
    let watcher = AppWindowWatcher(enumerate: { [] })
    watcher.release()
    watcher.release()
    XCTAssertFalse(watcher.isActive)

    // A stray release must not leave the count negative, or the next retain
    // would fail to start watching.
    watcher.retain()
    XCTAssertTrue(watcher.isActive)
  }

  /// A recording makes the picker unusable, so everything must stop at once
  /// regardless of how many holders there were.
  func testReleaseAllStopsRegardlessOfHolderCount() {
    let watcher = AppWindowWatcher(enumerate: { [] })
    watcher.retain()
    watcher.retain()
    watcher.retain()
    XCTAssertTrue(watcher.isActive)

    watcher.releaseAll()
    XCTAssertFalse(watcher.isActive)
  }

  func testTimerActuallyReportsAChangeWhileActive() {
    var current = [window(id: 1, app: "Safari", title: "Docs")]
    let watcher = AppWindowWatcher(interval: 0.05, enumerate: { current })
    let changed = expectation(description: "changed")
    watcher.onChanged = { changed.fulfill() }

    watcher.retain()
    defer { watcher.releaseAll() }

    current.append(window(id: 2, app: "Xcode", title: "Runner"))
    wait(for: [changed], timeout: 3)
  }
}
