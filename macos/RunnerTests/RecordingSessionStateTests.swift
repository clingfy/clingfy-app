import XCTest

@testable import Clingfy

/// Slice 10 / PR 38 guard: the `RecordingSessionState` mutation helpers.
/// Each helper is a verbatim relocation of an assignment cluster the
/// facade used to inline; these tests pin exactly which fields each helper
/// touches (and, by omission, which it leaves alone) so a later edit that
/// drops or adds a field is caught.
@MainActor
final class RecordingSessionStateTests: XCTestCase {

  func testApplyStartRequestSetsWorkflowIdAndSuppressionFlags() {
    let state = RecordingSessionState()
    let request = StartRecordingRequest(
      sessionId: "session-42",
      disableMicrophone: true,
      disableCameraOverlay: false,
      disableCursorHighlight: true,
      allowLowStorageBypass: false)

    state.applyStartRequest(request)

    XCTAssertEqual(state.activeRecordingWorkflowSessionId, "session-42")
    XCTAssertTrue(state.sessionDisableMicrophone)
    XCTAssertFalse(state.sessionDisableCameraOverlay)
    XCTAssertTrue(state.sessionDisableCursorHighlight)
  }

  func testResetStartRecoveryClearsAllFourFallbackFields() {
    let state = RecordingSessionState()
    state.hasAttemptedStartBackendFallback = true
    state.pendingStartFallbackOriginalError = NSError(domain: "t", code: 1)
    state.pendingStartFallbackWarningMessage = "warn"
    state.pendingStartCaptureConfig = nil  // already nil; documents the field

    state.resetStartRecovery()

    XCTAssertNil(state.pendingStartCaptureConfig)
    XCTAssertFalse(state.hasAttemptedStartBackendFallback)
    XCTAssertNil(state.pendingStartFallbackOriginalError)
    XCTAssertNil(state.pendingStartFallbackWarningMessage)
  }

  func testClearSessionSuppressionsClearsOnlyTheThreeFlags() {
    let state = RecordingSessionState()
    state.sessionDisableMicrophone = true
    state.sessionDisableCameraOverlay = true
    state.sessionDisableCursorHighlight = true
    state.activeRecordingWorkflowSessionId = "still-here"

    state.clearSessionSuppressions()

    XCTAssertFalse(state.sessionDisableMicrophone)
    XCTAssertFalse(state.sessionDisableCameraOverlay)
    XCTAssertFalse(state.sessionDisableCursorHighlight)
    // Unrelated field untouched.
    XCTAssertEqual(state.activeRecordingWorkflowSessionId, "still-here")
  }

  func testMarkFallbackAttemptedRecordsErrorAndWarning() {
    let state = RecordingSessionState()
    let error = NSError(domain: "sck", code: -3801)

    state.markFallbackAttempted(originalError: error, warningMessage: "fell back")

    XCTAssertTrue(state.hasAttemptedStartBackendFallback)
    XCTAssertEqual((state.pendingStartFallbackOriginalError as NSError?)?.code, -3801)
    XCTAssertEqual(state.pendingStartFallbackWarningMessage, "fell back")
  }

  func testClearTerminalSessionStateClearsProjectWorkflowAndCancelFlag() {
    let state = RecordingSessionState()
    state.activeRecordingProjectRoot = URL(fileURLWithPath: "/tmp/p.clingfyproj")
    state.activeRecordingWorkflowSessionId = "session-1"
    state.cancelRequestedDuringStart = true
    state.pendingMetadata = nil  // documents that pendingMetadata is NOT cleared here

    state.clearTerminalSessionState()

    XCTAssertNil(state.activeRecordingProjectRoot)
    XCTAssertNil(state.activeRecordingWorkflowSessionId)
    XCTAssertFalse(state.cancelRequestedDuringStart)
  }
}
