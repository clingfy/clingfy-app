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
