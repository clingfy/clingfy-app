import XCTest

@testable import Clingfy

/// Exhaustive table tests for the pure RecordingStateMachine (Commit 4).
/// These pin every decision the facade now delegates at its lifecycle entry
/// points, including the flag-dependent branches (stop during start, stop
/// queued behind a pause/resume mutation, no-op while a mutation is in flight).
final class RecordingStateMachineTests: XCTestCase {
  private let m = RecordingStateMachine()
  private let allStates: [RecorderState] = [.idle, .starting, .recording, .paused, .stopping]

  // MARK: start

  func testStartOnlyAllowedFromIdle() {
    for s in allStates {
      let expected: RecordingStateMachine.StartDecision = (s == .idle) ? .start : .alreadyActive
      XCTAssertEqual(m.startDecision(from: s), expected, "state \(s)")
    }
  }

  func testNextOnStartIsStarting() {
    XCTAssertEqual(m.nextOnStart(from: .idle), .starting)
  }

  func testHappyPathTransitions() {
    // idle -> starting -> recording -> stopping -> idle (ownership of the
    // actual mutation stays in the facade; here we assert the machine's
    // declared transitions for the acted-on decisions).
    XCTAssertEqual(m.startDecision(from: .idle), .start)
    XCTAssertEqual(m.nextOnStart(from: .idle), .starting)
    XCTAssertEqual(
      m.stopDecision(from: .recording, isPauseResumeMutationInFlight: false), .beginStopping)
    XCTAssertEqual(m.nextOnBeginStopping(from: .recording), .stopping)
  }

  // MARK: stop

  func testStopDecisionTable() {
    XCTAssertEqual(
      m.stopDecision(from: .idle, isPauseResumeMutationInFlight: false), .notRecording)
    XCTAssertEqual(
      m.stopDecision(from: .starting, isPauseResumeMutationInFlight: false), .cancelDuringStart)
    XCTAssertEqual(
      m.stopDecision(from: .starting, isPauseResumeMutationInFlight: true), .cancelDuringStart)
    XCTAssertEqual(
      m.stopDecision(from: .recording, isPauseResumeMutationInFlight: false), .beginStopping)
    XCTAssertEqual(
      m.stopDecision(from: .recording, isPauseResumeMutationInFlight: true), .queueUntilMutation)
    XCTAssertEqual(
      m.stopDecision(from: .paused, isPauseResumeMutationInFlight: false), .beginStopping)
    XCTAssertEqual(
      m.stopDecision(from: .paused, isPauseResumeMutationInFlight: true), .queueUntilMutation)
    XCTAssertEqual(
      m.stopDecision(from: .stopping, isPauseResumeMutationInFlight: false), .alreadyStopping)
  }

  // MARK: pause

  func testPauseDecisionTable() {
    XCTAssertEqual(
      m.pauseDecision(from: .paused, isPauseResumeMutationInFlight: false), .alreadyPaused)
    XCTAssertEqual(
      m.pauseDecision(from: .recording, isPauseResumeMutationInFlight: false), .begin)
    XCTAssertEqual(
      m.pauseDecision(from: .recording, isPauseResumeMutationInFlight: true),
      .mutationInFlightNoop)
    for s: RecorderState in [.starting, .stopping, .idle] {
      XCTAssertEqual(
        m.pauseDecision(from: s, isPauseResumeMutationInFlight: false), .invalidState, "state \(s)")
    }
  }

  // MARK: resume

  func testResumeDecisionTable() {
    XCTAssertEqual(
      m.resumeDecision(from: .recording, isPauseResumeMutationInFlight: false), .alreadyRecording)
    XCTAssertEqual(
      m.resumeDecision(from: .paused, isPauseResumeMutationInFlight: false), .begin)
    XCTAssertEqual(
      m.resumeDecision(from: .paused, isPauseResumeMutationInFlight: true),
      .mutationInFlightNoop)
    for s: RecorderState in [.starting, .stopping, .idle] {
      XCTAssertEqual(
        m.resumeDecision(from: s, isPauseResumeMutationInFlight: false), .invalidState,
        "state \(s)")
    }
  }

  // MARK: toggle

  func testToggleDecisionTable() {
    XCTAssertEqual(m.toggleDecision(from: .recording), .pause)
    XCTAssertEqual(m.toggleDecision(from: .paused), .resume)
    for s: RecorderState in [.idle, .starting, .stopping] {
      XCTAssertEqual(m.toggleDecision(from: s), .invalidState, "state \(s)")
    }
  }
}
