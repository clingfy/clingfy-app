import Foundation
import XCTest

@testable import Clingfy

final class PauseResumeSupportTests: XCTestCase {
  func testRecordedDurationTrackerAccumulatesOnlyActiveSegments() {
    let start = Date(timeIntervalSince1970: 100)
    var tracker = RecordedDurationTracker()

    tracker.start(at: start)

    XCTAssertEqual(
      tracker.currentRecordedDuration(at: start.addingTimeInterval(5)),
      5,
      accuracy: 0.001
    )

    tracker.pause(at: start.addingTimeInterval(5))

    XCTAssertTrue(tracker.isPaused)
    XCTAssertEqual(
      tracker.currentRecordedDuration(at: start.addingTimeInterval(20)),
      5,
      accuracy: 0.001
    )

    tracker.resume(at: start.addingTimeInterval(20))
    tracker.stop(at: start.addingTimeInterval(27))

    XCTAssertFalse(tracker.isPaused)
    XCTAssertEqual(tracker.accumulatedRecordedDuration, 12, accuracy: 0.001)
    XCTAssertEqual(
      tracker.currentRecordedDuration(at: start.addingTimeInterval(40)),
      12,
      accuracy: 0.001
    )
  }

  func testRecordingPauseResumeCapabilitiesAsMapUsesWireValues() {
    let capabilities = RecordingPauseResumeCapabilities(
      canPauseResume: true,
      backend: .screenCaptureKit,
      strategy: .recordingOutputSegmentation
    )

    let encoded = capabilities.asMap()

    XCTAssertEqual(encoded["canPauseResume"] as? Bool, true)
    XCTAssertEqual(encoded["backend"] as? String, "screencapturekit")
    XCTAssertEqual(encoded["strategy"] as? String, "recording_output_segmentation")
  }
}
