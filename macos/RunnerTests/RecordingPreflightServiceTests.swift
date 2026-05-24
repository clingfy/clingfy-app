import XCTest

@testable import Clingfy

/// PR 14 guard: the extracted preflight decisions reproduce the exact
/// truth tables of the old inline startRecording checks. Pure / deterministic.
final class RecordingPreflightServiceTests: XCTestCase {

  func testScreenRecordingSatisfiedReflectsInjectedPreflight() {
    XCTAssertTrue(RecordingPreflightService.screenRecordingSatisfied(preflight: { true }))
    XCTAssertFalse(RecordingPreflightService.screenRecordingSatisfied(preflight: { false }))
  }

  func testMicrophoneSatisfiedTruthTable() {
    // Disabled for the session ⇒ always satisfied regardless of auth/device.
    XCTAssertTrue(
      RecordingPreflightService.microphoneSatisfied(
        disableMicrophone: true, audioDeviceId: "mic-1", audioAuthorized: false))

    // No real device selected ⇒ satisfied (nil / empty / "__none__").
    XCTAssertTrue(
      RecordingPreflightService.microphoneSatisfied(
        disableMicrophone: false, audioDeviceId: nil, audioAuthorized: false))
    XCTAssertTrue(
      RecordingPreflightService.microphoneSatisfied(
        disableMicrophone: false, audioDeviceId: "", audioAuthorized: false))
    XCTAssertTrue(
      RecordingPreflightService.microphoneSatisfied(
        disableMicrophone: false, audioDeviceId: "__none__", audioAuthorized: false))

    // Real device selected ⇒ gated strictly by authorization.
    XCTAssertFalse(
      RecordingPreflightService.microphoneSatisfied(
        disableMicrophone: false, audioDeviceId: "mic-1", audioAuthorized: false))
    XCTAssertTrue(
      RecordingPreflightService.microphoneSatisfied(
        disableMicrophone: false, audioDeviceId: "mic-1", audioAuthorized: true))
  }

  func testAccessibilityBlocksRecordingAllEightCombos() {
    for cursorEnabled in [true, false] {
      for cursorLinked in [true, false] {
        for allowed in [true, false] {
          let expected = cursorEnabled && cursorLinked && !allowed
          XCTAssertEqual(
            RecordingPreflightService.accessibilityBlocksRecording(
              cursorEnabledForRecording: cursorEnabled,
              cursorLinked: cursorLinked,
              accessibilityAllowed: allowed),
            expected,
            "cursorEnabled=\(cursorEnabled) cursorLinked=\(cursorLinked) allowed=\(allowed)")
        }
      }
    }
  }
}
