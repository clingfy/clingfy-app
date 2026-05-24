import FlutterMacOS
import XCTest

@testable import Clingfy

/// Slice 6 / PR 21 guard: the pure decision helper extracted from the lower
/// half of `ScreenRecorderFacade.completeRecordingLifecycle(...)`. Pins the
/// "error wins" precedence over `mode`, the stage-label mapping
/// (`wasStarting → "start" | "finalize"`), the `errorMessage(from:)`
/// `FlutterError → message ?? code` fallback, and the ready/cancelled
/// payload routing. Side effects (manifest writes, callback fires) stay on
/// the facade and are exercised by `RecordingFailureRecoveryTests` /
/// `RunnerTests`.
final class RecordingFinalizerTests: XCTestCase {

  // MARK: - errorMessage(from:)

  func testErrorMessageReturnsFlutterErrorMessageWhenSet() {
    let e = FlutterError(code: "X", message: "boom", details: nil)
    XCTAssertEqual(RecordingFinalizer.errorMessage(from: e), "boom")
  }

  func testErrorMessageFallsBackToFlutterErrorCodeWhenMessageNil() {
    let e = FlutterError(code: "CODE_ONLY", message: nil, details: nil)
    XCTAssertEqual(RecordingFinalizer.errorMessage(from: e), "CODE_ONLY")
  }

  private struct StubError: LocalizedError {
    let msg: String
    var errorDescription: String? { msg }
  }

  func testErrorMessageUsesLocalizedDescriptionForNonFlutterErrors() {
    let e = StubError(msg: "non-flutter failure")
    XCTAssertEqual(RecordingFinalizer.errorMessage(from: e), "non-flutter failure")
  }

  // MARK: - stageLabel

  func testStageLabelMapsWasStartingToStartOtherwiseFinalize() {
    XCTAssertEqual(RecordingFinalizer.stageLabel(wasStarting: true), "start")
    XCTAssertEqual(RecordingFinalizer.stageLabel(wasStarting: false), "finalize")
  }

  // MARK: - decideAction error precedence

  func testErrorAlwaysProducesFailRegardlessOfMode() {
    let e = FlutterError(code: "RECORDING_ERROR", message: "boom", details: nil)
    let modes: [RecordingFinalizer.CompletionMode] = [.ready, .cancelled]
    for mode in modes {
      let action = RecordingFinalizer.decideAction(
        error: e,
        wasStarting: false,
        mode: mode,
        activeProjectPath: "/tmp/proj",
        activeSessionId: "sess-1",
        recordingErrorCode: "RECORDING_ERROR")

      XCTAssertEqual(
        action,
        .fail(errorMessage: "boom", code: "RECORDING_ERROR", stage: "finalize"),
        "mode \(mode) must still yield .fail when error is set")
    }
  }

  func testFailStageReflectsWasStarting() {
    let e = FlutterError(code: "X", message: "boom", details: nil)
    let action = RecordingFinalizer.decideAction(
      error: e,
      wasStarting: true,
      mode: .ready,
      activeProjectPath: nil,
      activeSessionId: nil,
      recordingErrorCode: "RECORDING_ERROR")

    XCTAssertEqual(action, .fail(errorMessage: "boom", code: "RECORDING_ERROR", stage: "start"))
  }

  // MARK: - decideAction success/cancelled routing

  func testReadyModeWithNoErrorReturnsReadyPayload() {
    let action = RecordingFinalizer.decideAction(
      error: nil,
      wasStarting: false,
      mode: .ready,
      activeProjectPath: "/tmp/proj",
      activeSessionId: "sess-1",
      recordingErrorCode: "RECORDING_ERROR")

    XCTAssertEqual(action, .ready(projectPath: "/tmp/proj", sessionId: "sess-1"))
  }

  func testReadyModeFlowsThroughNilProjectAndSession() {
    // The facade may call into finalize after the session refs were already
    // cleared (rare race). The decision must not crash and must echo nils
    // so the facade can decide whether to fire onRecordingFinalized.
    let action = RecordingFinalizer.decideAction(
      error: nil,
      wasStarting: false,
      mode: .ready,
      activeProjectPath: nil,
      activeSessionId: nil,
      recordingErrorCode: "RECORDING_ERROR")

    XCTAssertEqual(action, .ready(projectPath: nil, sessionId: nil))
  }

  func testCancelledModeReturnsCancelledWithProjectPath() {
    let action = RecordingFinalizer.decideAction(
      error: nil,
      wasStarting: false,
      mode: .cancelled,
      activeProjectPath: "/tmp/proj",
      activeSessionId: "sess-1",  // sessionId not echoed in cancelled
      recordingErrorCode: "RECORDING_ERROR")

    XCTAssertEqual(action, .cancelled(projectPath: "/tmp/proj"))
  }

  func testCancelledModeWithNilProjectStillReturnsCancelled() {
    let action = RecordingFinalizer.decideAction(
      error: nil,
      wasStarting: false,
      mode: .cancelled,
      activeProjectPath: nil,
      activeSessionId: nil,
      recordingErrorCode: "RECORDING_ERROR")

    XCTAssertEqual(action, .cancelled(projectPath: nil))
  }

  // MARK: - Recording-error-code is threaded through, not hardcoded

  func testRecordingErrorCodeIsPropagatedIntoFailAction() {
    // The facade passes NativeErrorCode.recordingError today but a future
    // caller could thread a different code through — verify the helper
    // doesn't bake the string in.
    let e = FlutterError(code: "X", message: "boom", details: nil)
    let action = RecordingFinalizer.decideAction(
      error: e,
      wasStarting: false,
      mode: .ready,
      activeProjectPath: nil,
      activeSessionId: nil,
      recordingErrorCode: "CUSTOM_RECORDING_CODE")

    XCTAssertEqual(action, .fail(errorMessage: "boom", code: "CUSTOM_RECORDING_CODE", stage: "finalize"))
  }
}
