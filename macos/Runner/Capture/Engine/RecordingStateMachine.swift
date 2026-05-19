import Foundation

/// Pure decision table for the recorder lifecycle
/// (idle → starting → recording ↔ paused → stopping → idle).
///
/// Commit 4 of the strangler refactor introduces this as a *validator only*:
/// the facade still owns `var state` and the in-flight/stop flags and performs
/// every side effect. This type just answers "given the current state (and
/// relevant flags), what should happen?" — a faithful, pure extraction of the
/// `switch state` tables previously inlined in
/// ScreenRecorderFacade.{startRecording,stopRecording,pauseRecording,
/// resumeRecording,togglePauseRecording}. Behavior is unchanged: each decision
/// case maps 1:1 to the original branch.
///
/// Engine-domain core (the future video-editing engine and Windows port build
/// on this — see windows-port-inventory §7). State ownership migration is a
/// later, separate slice.
struct RecordingStateMachine {

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
