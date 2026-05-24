import FlutterMacOS
import Foundation

/// Slice 8 / PR 29: the Recording engine — currently a **composition
/// root**, not the full owner of the recording lifecycle. The facade
/// still drives every transition; the engine just holds the lifecycle-
/// adjacent collaborators that used to be a flat list of facade fields:
///
/// - `stateMachine: RecordingStateMachine` — owns `state: RecorderState`
///   + fires `RecordingLifecycleEffects` on every transition (Slice 5 /
///   PR 19).
/// - `sessionCoordinator: RecordingSessionCoordinator` — preflight
///   clusters + `prepareStart` + `beginCaptureFlow` + `startCapture`
///   orchestration (Slice 5 / PR 20, Slice 7 / PRs 23-26).
/// - `captureBackendBinder: CaptureBackendBinder` — binds the 6 backend
///   callback slots to a `CaptureBackendEventHandling` conformance
///   (Slice 6 / PR 22).
///
/// What's intentionally NOT in the engine yet:
/// - `RecordingFinalizer` — it's an `enum` namespace (static helpers),
///   no instance to own; called as `RecordingFinalizer.decideAction(...)`.
/// - `CameraCoordinationController`, `OverlayVisibilityController`,
///   `CursorHighlightCoordinator`, `RecordingIndicatorCoordinator` —
///   each holds per-session state (pending camera session, dedup memory,
///   panel ownership, etc.). Migrating their ownership is a separate
///   lifecycle-ownership slice; they stay on the facade for now.
/// - `CaptureStartConfigBuilder`, `CaptureTargetResolver` — stateless
///   structs that the session coordinator already consumes; including
///   them on the engine would create two ownership paths.
///
/// Why a class, not a struct: the embedded `stateMachine` is a class
/// (Slice 5) with a `weak effects` reference back to the facade — the
/// engine needs reference semantics to keep the wiring honest. The
/// facade keeps a single `recordingEngine: RecordingEngine` instance
/// and exposes the two collaborators via computed forwarders so the
/// existing ~16 call sites read unchanged.
///
/// Engine-domain; see `windows-port-inventory.md` §7.
@MainActor
final class RecordingEngine {

  let stateMachine: RecordingStateMachine
  let sessionCoordinator: RecordingSessionCoordinator
  let captureBackendBinder: CaptureBackendBinder

  init(captureTargetResolver: CaptureTargetResolver) {
    self.stateMachine = RecordingStateMachine()
    self.sessionCoordinator = RecordingSessionCoordinator(
      captureTargetResolver: captureTargetResolver)
    self.captureBackendBinder = CaptureBackendBinder()
  }
}

// MARK: - Lifecycle entry points (PR 33a)
//
// Stop / pause / resume / togglePause lifecycle bodies, moved off the
// facade. Each method takes the facade-owned state it needs to make the
// decision (read inputs), and closures for every side effect it has to
// trigger (writes + capture-backend calls + the `beginStoppingCapture`
// facade-private helper). This matches the Slice 7
// `RecordingSessionCoordinator.prepareStart` / `beginCaptureFlow` style:
// engine owns the decision branches + the typed dispatch; facade still
// owns the mutable session state and the capture-backend reference.
//
// `startRecording` (the 224-line orchestration) is intentionally not in
// this PR; it lands in PR 33b once the small-fish lifecycle methods are
// proven green.
extension RecordingEngine {

  /// Mirrors the old facade-private `stopRecording(result:)`. Five branches:
  /// - `.notRecording` → result(error)
  /// - `.cancelDuringStart` → set pendingStop + cancelRequestedDuringStart + stopResult
  /// - `.queueUntilMutation` → set stopResult + pendingStop + log
  /// - `.beginStopping` → set stopResult + call `beginStoppingCapture`
  /// - `.alreadyStopping` → result(nil)
  func stopRecording(
    state: RecorderState,
    isPauseResumeMutationInFlight: Bool,
    setStopResult: (FlutterResult?) -> Void,
    setPendingStop: (Bool) -> Void,
    setCancelRequestedDuringStart: (Bool) -> Void,
    beginStoppingCapture: () -> Void,
    result: @escaping FlutterResult
  ) {
    switch stateMachine.stopDecision(
      from: state, isPauseResumeMutationInFlight: isPauseResumeMutationInFlight
    ) {
    case .notRecording:
      result(flutterError(NativeErrorCode.notRecording, ""))
    case .cancelDuringStart:
      setPendingStop(true)
      setCancelRequestedDuringStart(true)
      setStopResult(result)
    case .queueUntilMutation:
      setStopResult(result)
      setPendingStop(true)
      NativeLogger.i(
        "RecordingEngine", "Queued stop until pause/resume mutation completes",
        context: ["state": String(describing: state)])
    case .beginStopping:
      setStopResult(result)
      beginStoppingCapture()
    case .alreadyStopping:
      result(nil)
    }
  }

  /// Mirrors the old facade-private `pauseRecording(result:)`. Capability
  /// precondition (system + capture-backend) is checked first. Then four
  /// decision branches:
  /// - `.alreadyPaused` / `.mutationInFlightNoop` → result(nil)
  /// - `.begin` → set mutation-in-flight + pauseResult + log + capture.pause
  /// - `.invalidState` → result(error)
  func pauseRecording(
    state: RecorderState,
    isPauseResumeMutationInFlight: Bool,
    captureCanPauseResume: Bool,
    setIsPauseResumeMutationInFlight: (Bool) -> Void,
    setPauseResult: (FlutterResult?) -> Void,
    beginPauseOnCapture: () -> Void,
    result: @escaping FlutterResult
  ) {
    let capabilities = RecordingPauseResumeCapabilities.current()
    guard capabilities.canPauseResume && captureCanPauseResume else {
      result(flutterError(NativeErrorCode.pauseResumeUnsupported, ""))
      return
    }
    switch stateMachine.pauseDecision(
      from: state, isPauseResumeMutationInFlight: isPauseResumeMutationInFlight
    ) {
    case .alreadyPaused:
      result(nil)
    case .mutationInFlightNoop:
      result(nil)
    case .begin:
      setIsPauseResumeMutationInFlight(true)
      setPauseResult(result)
      NativeLogger.i("RecordingEngine", "Pause requested")
      beginPauseOnCapture()
    case .invalidState:
      result(
        flutterError(
          NativeErrorCode.invalidRecordingState,
          "Pause is only valid while recording."
        ))
    }
  }

  /// Symmetric to `pauseRecording`. Same precondition + four branches:
  /// - `.alreadyRecording` / `.mutationInFlightNoop` → result(nil)
  /// - `.begin` → set mutation-in-flight + resumeResult + log + capture.resume
  /// - `.invalidState` → result(error)
  func resumeRecording(
    state: RecorderState,
    isPauseResumeMutationInFlight: Bool,
    captureCanPauseResume: Bool,
    setIsPauseResumeMutationInFlight: (Bool) -> Void,
    setResumeResult: (FlutterResult?) -> Void,
    beginResumeOnCapture: () -> Void,
    result: @escaping FlutterResult
  ) {
    let capabilities = RecordingPauseResumeCapabilities.current()
    guard capabilities.canPauseResume && captureCanPauseResume else {
      result(flutterError(NativeErrorCode.pauseResumeUnsupported, ""))
      return
    }
    switch stateMachine.resumeDecision(
      from: state, isPauseResumeMutationInFlight: isPauseResumeMutationInFlight
    ) {
    case .alreadyRecording:
      result(nil)
    case .mutationInFlightNoop:
      result(nil)
    case .begin:
      setIsPauseResumeMutationInFlight(true)
      setResumeResult(result)
      NativeLogger.i("RecordingEngine", "Resume requested")
      beginResumeOnCapture()
    case .invalidState:
      result(
        flutterError(
          NativeErrorCode.invalidRecordingState,
          "Resume is only valid while paused."
        ))
    }
  }

  /// Typed dispatch for togglePause. Engine resolves the decision; facade
  /// dispatches by calling its own pause/resume method when needed (so the
  /// capability precondition + capture-backend ownership stay on the
  /// facade for free — no need to re-pass all the pause/resume closures
  /// through toggle).
  enum ToggleDispatch: Equatable {
    case pause
    case resume
    /// Engine already invoked `result(...)` with the invalid-state error.
    case handled
  }

  func togglePauseRecording(
    state: RecorderState,
    result: @escaping FlutterResult
  ) -> ToggleDispatch {
    switch stateMachine.toggleDecision(from: state) {
    case .pause:
      return .pause
    case .resume:
      return .resume
    case .invalidState:
      result(
        flutterError(
          NativeErrorCode.invalidRecordingState,
          "Pause/resume is only valid for an active recording."
        ))
      return .handled
    }
  }
}
