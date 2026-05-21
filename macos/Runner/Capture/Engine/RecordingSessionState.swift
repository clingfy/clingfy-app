import CoreGraphics
import FlutterMacOS
import Foundation

/// Slice 10 / PR 35: a single owner for the per-recording-session mutable
/// state that previously lived as ~10 loose `var`s directly on
/// `ScreenRecorderFacade`.
///
/// Why this exists. The Slice 9 audit (see `windows-port-inventory.md`
/// §7.1) found that `startRecording` / `finishStartWithError` / the
/// `CaptureBackendEventHandling` callback bodies can't move into
/// `RecordingEngine` without a ~20-closure signature or a ~30-member host
/// protocol — because they read and write a scattered set of facade
/// fields. Giving those fields one owner turns "pass 10 closures" into
/// "pass one `sessionState`", which is the prerequisite for any further
/// lifecycle migration.
///
/// PR 35 (this file) moves the **passive** fields only — the ones that are
/// plain reads/writes with no once-only-resolution contract:
///   - `activeRecordingProjectRoot` / `activeRecordingWorkflowSessionId`
///   - `pendingMetadata`
///   - `currentCaptureDisplayID`
///   - `sessionDisable{Microphone,CameraOverlay,CursorHighlight}`
///   - `pendingStartCaptureConfig`
///
/// The pending Flutter-result slots (`startResult` / `stopResult` /
/// `pauseResult` / `resumeResult`) and the start/recovery flags
/// (`pendingStop`, `cancelRequestedDuringStart`, the backend-fallback
/// fields) are deliberately left on the facade for now — they move in
/// PR 36 / PR 37 because their resolve-exactly-once / fallback semantics
/// need their own focused review.
///
/// Field names are kept **identical** to the old facade fields so this PR
/// is a pure mechanical relocation (`x` → `sessionState.x`), trivially
/// verifiable as behavior-preserving. Cleaner names + reset/snapshot
/// helpers come in PR 38.
///
/// `@MainActor` + `final class`: reference semantics so the facade and its
/// extensions (e.g. `StorageDiagnosticsService`) share one instance, and
/// main-actor isolation because every access today is already on the
/// facade's main actor. Engine-domain; see `windows-port-inventory.md` §7.
@MainActor
final class RecordingSessionState {

  /// Project bundle root for the active recording (`nil` when idle).
  var activeRecordingProjectRoot: URL?

  /// Workflow session id from the `startRecording` request (`nil` when idle).
  var activeRecordingWorkflowSessionId: String?

  /// Screen metadata written on start, updated on finish.
  var pendingMetadata: RecordingMetadata?

  /// Display id the active capture is bound to (`nil` when idle).
  var currentCaptureDisplayID: CGDirectDisplayID?

  /// Per-session suppression flags, set from the `startRecording` request.
  var sessionDisableMicrophone = false
  var sessionDisableCameraOverlay = false
  var sessionDisableCursorHighlight = false

  /// The `CaptureStartConfig` retained for the ScreenCaptureKit →
  /// AVFoundation start-fallback retry path.
  var pendingStartCaptureConfig: CaptureStartConfig?

  /// Pending Flutter-result slots for the four lifecycle calls (PR 36).
  ///
  /// Each must be completed **exactly once** and then cleared to `nil` —
  /// the facade's resolve sites (`finishStartWithError`,
  /// `completeRecordingLifecycle`, `resolvePauseResume{Failure,
  /// SuccessIfNeeded}`, `backendDidStart`) own that contract. Moving the
  /// slots here is a pure relocation; the fire-then-nil ordering at every
  /// call site is unchanged.
  var startResult: FlutterResult?
  var stopResult: FlutterResult?
  var pauseResult: FlutterResult?
  var resumeResult: FlutterResult?

  /// Start / recovery flags (PR 37).
  ///
  /// `pendingStop` — a stop was requested while still starting or while a
  /// pause/resume mutation was in flight; drained once the recorder
  /// settles. `cancelRequestedDuringStart` — the stop arrived mid-start so
  /// the finished recording is finalized as cancelled rather than ready.
  ///
  /// The three `*Fallback*` fields drive the ScreenCaptureKit →
  /// AVFoundation start-retry path: whether a fallback has been attempted,
  /// the original SCK error to surface if the fallback also fails, and the
  /// warning message to emit once the fallback succeeds.
  var pendingStop = false
  var cancelRequestedDuringStart = false
  var hasAttemptedStartBackendFallback = false
  var pendingStartFallbackOriginalError: Error?
  var pendingStartFallbackWarningMessage: String?
}
