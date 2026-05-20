import Foundation

/// Pure decision table for the recorder lifecycle
/// (idle → starting → recording ↔ paused → stopping → idle), now also the
/// owner of the lifecycle `state` itself (Slice 5 / PR 19).
///
/// Commit 4 of the strangler refactor introduced this as a *validator only*
/// (a value type that returned decisions but stored no state). PR 19 promotes
/// it to `final class` and migrates the `var state: RecorderState` field
/// previously held on `ScreenRecorderFacade`. Behavior is preserved: the
/// facade exposes `state` as a get/set computed property that proxies to this
/// type, so every existing reader (~50 call sites) sees the same value and
/// every writer (~10 call sites) routes through `transition(to:)`.
///
/// Why a class now: ownership semantics. We want a single shared mutable
/// `state` that the facade and (in PR 20) `RecordingSessionCoordinator` both
/// read/write through, plus a `weak` effects observer so `didTransition`
/// fires next to the storage update. A struct would force "the current
/// owner" model and copy ambiguity across the seam.
///
/// Engine-domain core (the future video-editing engine and Windows port build
/// on this — see windows-port-inventory §7). All pre-existing pure decision
/// methods are unchanged; only ownership + a `transition(to:)` writer were
/// added.
@MainActor
final class RecordingStateMachine {

  /// Lifecycle state, owned here. Read by the facade (via its computed
  /// `state` proxy) and by `transition(to:)`. Mutation is funnelled through
  /// `transition(to:)` so every write fires `effects?.didTransition(...)`.
  private(set) var state: RecorderState = .idle

  /// Receives `didTransition(to:from:)` on every `transition(to:)` call.
  /// `weak` to avoid a retain cycle with the facade that implements the
  /// protocol and owns this instance.
  weak var effects: RecordingLifecycleEffects?

  /// Set `state` to `newState` and fire `effects?.didTransition`. Self-
  /// transitions still fire — matches Swift property setter semantics and
  /// keeps the observer surface predictable (callers can dedup if they care).
  func transition(to newState: RecorderState) {
    let previous = state
    state = newState
    effects?.didTransition(to: newState, from: previous)
  }

  enum StartDecision: Equatable {
    /// Recorder is idle — proceed; caller should transition to `.starting`.
    case start
    /// A session is already active/in-flight — caller returns the active
    /// project path, or the `alreadyRecording` error.
    case alreadyActive
  }

  enum StopDecision: Equatable {
    case notRecording  // idle
    case cancelDuringStart  // starting
    case queueUntilMutation  // recording/paused while a pause/resume is in flight
    case beginStopping  // recording/paused, no mutation in flight
    case alreadyStopping  // stopping
  }

  enum PauseDecision: Equatable {
    case alreadyPaused
    case begin  // recording, no mutation in flight
    case mutationInFlightNoop  // recording, mutation already in flight
    case invalidState  // starting / stopping / idle
  }

  enum ResumeDecision: Equatable {
    case alreadyRecording
    case begin  // paused, no mutation in flight
    case mutationInFlightNoop  // paused, mutation already in flight
    case invalidState  // starting / stopping / idle
  }

  enum ToggleDecision: Equatable {
    case pause  // recording
    case resume  // paused
    case invalidState  // idle / starting / stopping
  }

  // MARK: start

  func startDecision(from state: RecorderState) -> StartDecision {
    state == .idle ? .start : .alreadyActive
  }

  /// Next state once a `.start` decision is acted on.
  func nextOnStart(from state: RecorderState) -> RecorderState { .starting }

  // MARK: stop

  func stopDecision(
    from state: RecorderState, isPauseResumeMutationInFlight: Bool
  ) -> StopDecision {
    switch state {
    case .idle:
      return .notRecording
    case .starting:
      return .cancelDuringStart
    case .recording, .paused:
      return isPauseResumeMutationInFlight ? .queueUntilMutation : .beginStopping
    case .stopping:
      return .alreadyStopping
    }
  }

  /// Next state once a `.beginStopping` decision is acted on.
  func nextOnBeginStopping(from state: RecorderState) -> RecorderState { .stopping }

  // MARK: pause

  func pauseDecision(
    from state: RecorderState, isPauseResumeMutationInFlight: Bool
  ) -> PauseDecision {
    switch state {
    case .paused:
      return .alreadyPaused
    case .recording:
      return isPauseResumeMutationInFlight ? .mutationInFlightNoop : .begin
    case .starting, .stopping, .idle:
      return .invalidState
    }
  }

  // MARK: resume

  func resumeDecision(
    from state: RecorderState, isPauseResumeMutationInFlight: Bool
  ) -> ResumeDecision {
    switch state {
    case .recording:
      return .alreadyRecording
    case .paused:
      return isPauseResumeMutationInFlight ? .mutationInFlightNoop : .begin
    case .starting, .stopping, .idle:
      return .invalidState
    }
  }

  // MARK: toggle

  func toggleDecision(from state: RecorderState) -> ToggleDecision {
    switch state {
    case .recording:
      return .pause
    case .paused:
      return .resume
    case .idle, .starting, .stopping:
      return .invalidState
    }
  }
}
