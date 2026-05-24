import XCTest

@testable import Clingfy

/// Exhaustive table tests for the pure RecordingStateMachine (Commit 4) plus
/// the new state-ownership + `RecordingLifecycleEffects` surface introduced
/// in Slice 5 / PR 19. `@MainActor` because the type itself is
/// `@MainActor`-isolated — the facade only calls it from the main thread.
@MainActor
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

  // MARK: - Slice 5 / PR 19: state ownership + lifecycle effects

  /// Test double that records every `didTransition` callback so the order
  /// and from→to tuples can be asserted.
  @MainActor
  private final class EffectsRecorder: RecordingLifecycleEffects {
    var transitions: [(from: RecorderState, to: RecorderState)] = []
    func didTransition(to newState: RecorderState, from previousState: RecorderState) {
      transitions.append((previousState, newState))
    }
  }

  func testInitialStateIsIdle() {
    let sm = RecordingStateMachine()
    XCTAssertEqual(sm.state, .idle)
  }

  func testTransitionUpdatesStateAndFiresEffectsWithFromAndTo() {
    let sm = RecordingStateMachine()
    let observer = EffectsRecorder()
    sm.effects = observer

    sm.transition(to: .starting)
    XCTAssertEqual(sm.state, .starting)
    XCTAssertEqual(observer.transitions.count, 1)
    XCTAssertEqual(observer.transitions.last?.from, .idle)
    XCTAssertEqual(observer.transitions.last?.to, .starting)

    sm.transition(to: .recording)
    XCTAssertEqual(sm.state, .recording)
    XCTAssertEqual(observer.transitions.last?.from, .starting)
    XCTAssertEqual(observer.transitions.last?.to, .recording)
  }

  func testSelfTransitionStillFiresEffects() {
    // Matches Swift property setter semantics — `state = .recording` even
    // when already `.recording` would re-fire any willSet/didSet. We mirror
    // that so the observer surface is predictable.
    let sm = RecordingStateMachine()
    let observer = EffectsRecorder()
    sm.effects = observer

    sm.transition(to: .recording)
    sm.transition(to: .recording)

    XCTAssertEqual(observer.transitions.count, 2)
    XCTAssertEqual(observer.transitions.last?.from, .recording)
    XCTAssertEqual(observer.transitions.last?.to, .recording)
  }

  func testEffectsReferenceIsWeak() {
    let sm = RecordingStateMachine()
    weak var weakObserver: EffectsRecorder?
    do {
      let observer = EffectsRecorder()
      sm.effects = observer
      weakObserver = observer
      XCTAssertNotNil(weakObserver, "observer should be alive while in scope")
    }
    // Observer went out of scope. The `weak` effects reference must let
    // it deallocate; the state machine must not keep it alive.
    XCTAssertNil(weakObserver, "RecordingStateMachine.effects must be weak")

    // Transitions still work after the observer is gone — they just don't
    // fire any callback.
    sm.transition(to: .starting)
    XCTAssertEqual(sm.state, .starting)
  }

  func testHappyPathSequenceProducesExpectedTransitionTuples() {
    let sm = RecordingStateMachine()
    let observer = EffectsRecorder()
    sm.effects = observer

    // idle → starting → recording → paused → recording → stopping → idle
    sm.transition(to: .starting)
    sm.transition(to: .recording)
    sm.transition(to: .paused)
    sm.transition(to: .recording)
    sm.transition(to: .stopping)
    sm.transition(to: .idle)

    let expected: [(RecorderState, RecorderState)] = [
      (.idle, .starting),
      (.starting, .recording),
      (.recording, .paused),
      (.paused, .recording),
      (.recording, .stopping),
      (.stopping, .idle),
    ]
    XCTAssertEqual(observer.transitions.count, expected.count)
    for (i, e) in expected.enumerated() {
      XCTAssertEqual(observer.transitions[i].from, e.0, "step \(i) from")
      XCTAssertEqual(observer.transitions[i].to, e.1, "step \(i) to")
    }
  }
}
