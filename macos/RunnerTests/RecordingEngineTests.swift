import XCTest

@testable import Clingfy

/// Slice 8 / PR 29 guard: the `RecordingEngine` composition root.
/// Behavior tests of the embedded collaborators
/// (`RecordingStateMachine`, `RecordingSessionCoordinator`,
/// `CaptureBackendBinder`) already live in their own dedicated suites;
/// this file only pins the engine's wiring contract — initial state of
/// each collaborator + that the same instance is returned across reads
/// (so callers can hold the reference and use it like a let).
@MainActor
final class RecordingEngineTests: XCTestCase {

  func testEngineExposesAFreshIdleStateMachine() {
    let engine = RecordingEngine(captureTargetResolver: CaptureTargetResolver())
    XCTAssertEqual(engine.stateMachine.state, .idle)
  }

  func testEngineExposesAFunctionalSessionCoordinator() {
    let engine = RecordingEngine(captureTargetResolver: CaptureTargetResolver())

    // Smoke: the coordinator's preflight cluster returns a typed outcome
    // when invoked. Use the screen-recording denied path — fastest deterministic
    // outcome that doesn't touch real TCC.
    let outcome = engine.sessionCoordinator.evaluateScreenPermissionAndTarget(
      screenRecordingSatisfied: { false },
      captureTargetInput: .init(
        displayMode: .explicitID,
        selectedDisplayID: 1,
        selectedAppWindowID: nil,
        areaRect: nil,
        areaDisplayId: nil),
      displayService: makeAnyDisplayService())

    XCTAssertEqual(outcome, .fail(errorCode: NativeErrorCode.screenRecordingPermission))
  }

  func testEngineExposesACaptureBackendBinderInstance() {
    // Stateless — just verify it exists and `bind(_:to:)` is callable
    // (the binder's own tests already cover routing semantics).
    let engine = RecordingEngine(captureTargetResolver: CaptureTargetResolver())
    XCTAssertNotNil(engine.captureBackendBinder)
  }

  func testStateMachineReferenceIsStableAcrossReads() {
    // The engine exposes its collaborators as `let` properties so callers
    // can store the reference and write `engine.stateMachine.effects = ...`
    // without surprise — multiple reads must return the same instance.
    let engine = RecordingEngine(captureTargetResolver: CaptureTargetResolver())
    let first = engine.stateMachine
    let second = engine.stateMachine
    XCTAssertTrue(first === second, "stateMachine reads must return the same class instance")
  }

  // MARK: - Helpers

  private func makeAnyDisplayService() -> CaptureDisplayResolving {
    final class StubDisplay: CaptureDisplayResolving {
      func displayIDForAppWindowOrMain() -> CGDirectDisplayID { 1 }
      func displayIDUnderMouse() -> CGDirectDisplayID? { 1 }
      func captureTarget(forWindowID id: CGWindowID) -> (
        displayID: CGDirectDisplayID, rect: CGRect
      )? { nil }
    }
    return StubDisplay()
  }
}
