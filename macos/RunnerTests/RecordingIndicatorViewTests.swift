import Cocoa
import XCTest

@testable import Clingfy

@MainActor
final class RecordingIndicatorViewTests: XCTestCase {
  private func makeView(
    state: IndicatorState,
    elapsed: String = "00:12:34"
  ) -> RecordingIndicatorView {
    let view = RecordingIndicatorView(
      frame: NSRect(origin: .zero, size: RecordingIndicatorView.preferredSize)
    )
    view.elapsedProvider = { elapsed }
    view.state = state
    view.layoutSubtreeIfNeeded()
    return view
  }

  func testRecordingStateShowsPrimaryStopOnly() {
    let view = makeView(state: .recording)

    XCTAssertFalse(view.debugPrimaryHitRect.isEmpty)
    XCTAssertTrue(view.debugSecondaryStopHitRect.isEmpty)
    XCTAssertEqual(view.debugDisplayedElapsedText, "00:12:34")
    XCTAssertEqual(view.debugPrimaryTooltip, "Stop recording")
    XCTAssertTrue(view.debugHasTickTimer)
  }

  func testPausedStateShowsResumeAndSecondaryStop() {
    let view = makeView(state: .paused)

    XCTAssertFalse(view.debugPrimaryHitRect.isEmpty)
    XCTAssertFalse(view.debugSecondaryStopHitRect.isEmpty)
    XCTAssertEqual(view.debugDisplayedElapsedText, "Paused • 00:12:34")
    XCTAssertEqual(view.debugPrimaryTooltip, "Resume recording")
    XCTAssertEqual(view.debugSecondaryTooltip, "Stop recording")
    XCTAssertFalse(view.debugHasTickTimer)
  }

  func testStoppingStateHasNoActionableHitTargets() {
    let view = makeView(state: .stopping)

    XCTAssertTrue(view.debugPrimaryHitRect.isEmpty)
    XCTAssertTrue(view.debugSecondaryStopHitRect.isEmpty)
    XCTAssertEqual(view.debugDisplayedElapsedText, "00:00:00")
    XCTAssertFalse(view.debugHasTickTimer)
  }

  func testRecordingPrimaryClickTriggersStop() {
    let view = makeView(state: .recording)
    var stopTapped = 0
    view.onStopTapped = { stopTapped += 1 }

    XCTAssertTrue(view.debugHandleClick(at: center(of: view.debugPrimaryHitRect)))
    XCTAssertEqual(stopTapped, 1)
  }

  func testPausedPrimaryClickTriggersResume() {
    let view = makeView(state: .paused)
    var resumeTapped = 0
    view.onResumeTapped = { resumeTapped += 1 }

    XCTAssertTrue(view.debugHandleClick(at: center(of: view.debugPrimaryHitRect)))
    XCTAssertEqual(resumeTapped, 1)
  }

  func testPausedSecondaryStopClickTriggersStop() {
    let view = makeView(state: .paused)
    var stopTapped = 0
    view.onStopTapped = { stopTapped += 1 }

    XCTAssertTrue(view.debugHandleClick(at: center(of: view.debugSecondaryStopHitRect)))
    XCTAssertEqual(stopTapped, 1)
  }

  func testFacadeMapsPausedStateToPausedIndicatorAndWiresCallbacks() {
    let facade = ScreenRecorderFacade()
    var stopTapped = 0
    var resumeTapped = 0
    facade.onIndicatorStopTapped = { stopTapped += 1 }
    facade.onIndicatorResumeTapped = { resumeTapped += 1 }
    facade._testSetRecorderState(.paused)

    XCTAssertEqual(facade._testCurrentIndicatorState(), .paused)

    let configuration = facade._testIndicatorConfiguration()
    XCTAssertEqual(configuration.state, .paused)
    XCTAssertNotNil(configuration.onStopTapped)
    XCTAssertNotNil(configuration.onResumeTapped)

    configuration.onResumeTapped?()
    configuration.onStopTapped?()

    XCTAssertEqual(resumeTapped, 1)
    XCTAssertEqual(stopTapped, 1)
  }

  private func center(of rect: CGRect) -> CGPoint {
    CGPoint(x: rect.midX, y: rect.midY)
  }
}
