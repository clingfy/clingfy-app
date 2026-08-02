import AppKit
import XCTest

@testable import Clingfy

final class DeviceChangeFanOutTests: XCTestCase {

  // MARK: - Fan-out

  /// The whole reason this exists: the facade's callbacks are
  /// single-assignment and already owned by the Flutter bridge, so the bar
  /// cannot take them. Notifications allow a second observer without
  /// unhooking the first.
  func testEveryObserverReceivesTheSamePost() {
    var firstCount = 0
    var secondCount = 0
    let center = NotificationCenter.default

    let first = center.addObserver(
      forName: .deviceDisplaysChanged, object: nil, queue: .main
    ) { _ in firstCount += 1 }
    let second = center.addObserver(
      forName: .deviceDisplaysChanged, object: nil, queue: .main
    ) { _ in secondCount += 1 }
    defer {
      center.removeObserver(first)
      center.removeObserver(second)
    }

    DeviceChangeNotification.post(.deviceDisplaysChanged)

    XCTAssertEqual(firstCount, 1)
    XCTAssertEqual(secondCount, 1)
  }

  func testTheFourNamesAreDistinct() {
    let names: Set<Notification.Name> = [
      .deviceAudioSourcesChanged,
      .deviceVideoSourcesChanged,
      .deviceDisplaysChanged,
      .deviceAppWindowsChanged,
    ]
    XCTAssertEqual(names.count, 4, "a duplicated name would cross-wire two pickers")
  }

  /// A change detected on the CoreAudio HAL thread or a capture queue must
  /// still arrive on main, because every observer touches AppKit.
  func testAPostFromABackgroundThreadArrivesOnMain() {
    let delivered = expectation(description: "delivered")
    var wasMain = false

    let observer = NotificationCenter.default.addObserver(
      forName: .deviceAudioSourcesChanged, object: nil, queue: .main
    ) { _ in
      wasMain = Thread.isMainThread
      delivered.fulfill()
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    DispatchQueue.global().async {
      DeviceChangeNotification.post(.deviceAudioSourcesChanged)
    }

    wait(for: [delivered], timeout: 3)
    XCTAssertTrue(wasMain)
  }

  // MARK: - Popover routing

  /// A device change must refresh only the picker it affects. Rebuilding an
  /// unrelated open popover would shift the list under the user's cursor for
  /// no reason.
  func testEachPopoverKindMapsToItsOwnNotification() {
    XCTAssertEqual(
      PreRecordingBarController.PopoverKind.display.changeNotification,
      .deviceDisplaysChanged)
    XCTAssertEqual(
      PreRecordingBarController.PopoverKind.window.changeNotification,
      .deviceAppWindowsChanged)
    XCTAssertEqual(
      PreRecordingBarController.PopoverKind.mic.changeNotification,
      .deviceAudioSourcesChanged)
    XCTAssertEqual(
      PreRecordingBarController.PopoverKind.camera.changeNotification,
      .deviceVideoSourcesChanged)
  }

  func testNoTwoKindsShareANotification() {
    let kinds: [PreRecordingBarController.PopoverKind] = [
      .display, .window, .mic, .camera,
    ]
    let names = Set(kinds.map(\.changeNotification))
    XCTAssertEqual(names.count, kinds.count)
  }
}
