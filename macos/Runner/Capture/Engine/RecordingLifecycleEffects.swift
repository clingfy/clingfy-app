import Foundation

/// Slice 5 / PR 19: notification surface fired by `RecordingStateMachine` on
/// every `state` transition. The state machine owns the storage; consumers
/// (today: `ScreenRecorderFacade`) observe transitions via this protocol and
/// run the side effects that used to be inline next to `state = X` writes.
///
/// PR 19 introduces the protocol and routes ownership; the facade
/// implementation is intentionally minimal so the diff stays
/// behavior-preserving. PR 20 (`RecordingSessionCoordinator`) will populate
/// it with the start/stop orchestration.
///
/// `@MainActor`-isolated because every transition the facade owns happens on
/// the main thread (`runOnMainIfNeeded(...)` is the lifecycle entry point).
/// Engine-domain; see `windows-port-inventory.md` §7.
@MainActor
protocol RecordingLifecycleEffects: AnyObject {
  /// Called after `RecordingStateMachine.state` has been set to `newState`.
  /// Self-transitions (`newState == previousState`) still fire so callers can
  /// implement idempotent log/audit hooks without special-casing.
  func didTransition(to newState: RecorderState, from previousState: RecorderState)
}
