import XCTest

@testable import Clingfy

/// Slice 4 / PR 17 guard: the two pure helpers extracted into
/// `RecordingIndicatorCoordinator` reproduce the inline behavior of the old
/// facade-private `currentIndicatorState()` and `formattedElapsed()`. The
/// stateful `apply(...)` path is exercised end-to-end by the existing
/// `RecordingIndicatorViewTests` (the `_testIndicatorConfiguration` /
/// `_testCurrentIndicatorState` seams still drive it through the facade).
@MainActor
final class RecordingIndicatorCoordinatorTests: XCTestCase {

  // MARK: - indicatorState(for:) truth table

  func testRecordingRecorderStateMapsToRecordingViewState() {
    XCTAssertEqual(RecordingIndicatorCoordinator.indicatorState(for: .recording), .recording)
  }

  func testPausedRecorderStateMapsToPausedViewState() {
    XCTAssertEqual(RecordingIndicatorCoordinator.indicatorState(for: .paused), .paused)
  }

  func testStoppingRecorderStateMapsToStoppingViewState() {
    XCTAssertEqual(RecordingIndicatorCoordinator.indicatorState(for: .stopping), .stopping)
  }

  func testIdleRecorderStateMapsToHidden() {
    XCTAssertEqual(RecordingIndicatorCoordinator.indicatorState(for: .idle), .hidden)
  }

  func testStartingRecorderStateMapsToHidden() {
    // .starting collapses to .hidden — the indicator panel is not shown
    // until the recording actually begins.
    XCTAssertEqual(RecordingIndicatorCoordinator.indicatorState(for: .starting), .hidden)
  }

  // MARK: - formatElapsed(seconds:)

  func testFormatElapsedZero() {
    XCTAssertEqual(RecordingIndicatorCoordinator.formatElapsed(seconds: 0), "00:00:00")
  }

  func testFormatElapsedSubMinute() {
    XCTAssertEqual(RecordingIndicatorCoordinator.formatElapsed(seconds: 7), "00:00:07")
  }

  func testFormatElapsedExactMinute() {
    XCTAssertEqual(RecordingIndicatorCoordinator.formatElapsed(seconds: 60), "00:01:00")
  }

  func testFormatElapsedMixedHourMinuteSecond() {
    // 1 * 3600 + 23 * 60 + 45 = 5025
    XCTAssertEqual(RecordingIndicatorCoordinator.formatElapsed(seconds: 5025), "01:23:45")
  }

  func testFormatElapsedClampsNegativeToZero() {
    // Mirrors the old `max(0, Int(...))` clamp in `formattedElapsed()`.
    XCTAssertEqual(RecordingIndicatorCoordinator.formatElapsed(seconds: -42), "00:00:00")
  }

  func testFormatElapsedTenHoursStillRendersAsHHMMSS() {
    // 10 * 3600 + 4 = 36004
    XCTAssertEqual(RecordingIndicatorCoordinator.formatElapsed(seconds: 36004), "10:00:04")
  }
}
