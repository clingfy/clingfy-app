import CoreGraphics
import Foundation

/// Slice 5 / PR 20: stateless coordinator that consumes the Slice-3 services
/// (`CaptureTargetResolver`, `RecordingPreflightService`) and exposes the two
/// pure preflight clusters of `ScreenRecorderFacade.startRecording`:
///
/// 1. **Screen permission + capture-target resolution** — replaces lines
///    298-334 of the original `startRecording`. Returns either the resolved
///    `CaptureTarget` or the `NativeErrorCode` for the first failing gate.
/// 2. **Microphone + accessibility preflight** — replaces lines 356-377 of
///    the original `startRecording`. Echoes the input target on success or
///    returns the first failing `NativeErrorCode`.
///
/// The coordinator is intentionally NOT involved in: the `state = .starting`
/// transition, `startResult` assignment, request parsing, session-disable
/// field writes, `CGRequestScreenCaptureAccess()`, `finishStartWithError`,
/// `AreaPreviewOverlay.hide()`, workspace-dir creation, the `target` rebuild,
/// `frameRate`/`systemAudioEnabled` parsing, project skeleton, low-storage
/// preflight, capture-backend setup, camera permission, or
/// `prepareCameraOverlayForRecordingStart(...)`. Those all stay on the facade
/// because they either own facade state mutations or run between the two
/// preflight clusters — moving them would change observable side-effect
/// ordering (e.g. you'd hide the area preview before a screen-permission
/// failure that today never gets that far). They migrate later in
/// Slice 6 (`RecordingFinalizer`) and Slice 7 (`CaptureBackendBinder`).
///
/// Engine-domain; see `windows-port-inventory.md` §7.
@MainActor
struct RecordingSessionCoordinator {

  let captureTargetResolver: CaptureTargetResolver

  /// First-failing-gate outcome for a preflight cluster.
  /// `errorCode` is one of the string constants in `NativeErrorCode`.
  enum PreflightOutcome: Equatable {
    case proceed(CaptureTarget)
    case fail(errorCode: String)
  }

  // MARK: - Cluster 1: screen permission + capture-target resolution

  /// Verbatim from `startRecording` lines 298-334. Runs the screen-recording
  /// permission preflight; on satisfied, resolves the capture target via the
  /// Slice-3 resolver and maps the four `CaptureTargetError` variants to the
  /// matching `NativeErrorCode` strings.
  ///
  /// `screenRecordingSatisfied` is injected (defaults to the real
  /// `RecordingPreflightService.screenRecordingSatisfied` from Slice 3 /
  /// PR 14) so this method is testable without touching real TCC.
  func evaluateScreenPermissionAndTarget(
    screenRecordingSatisfied: () -> Bool = {
      RecordingPreflightService.screenRecordingSatisfied()
    },
    captureTargetInput: CaptureTargetResolver.Input,
    displayService: CaptureDisplayResolving
  ) -> PreflightOutcome {
    if !screenRecordingSatisfied() {
      return .fail(errorCode: NativeErrorCode.screenRecordingPermission)
    }

    do {
      let target = try captureTargetResolver.resolve(
        captureTargetInput, displayService: displayService)
      return .proceed(target)
    } catch CaptureTargetError.noWindowSelected {
      return .fail(errorCode: NativeErrorCode.noWindowSelected)
    } catch CaptureTargetError.windowUnavailable {
      return .fail(errorCode: NativeErrorCode.windowNotAvailable)
    } catch CaptureTargetError.noAreaSelected {
      return .fail(errorCode: NativeErrorCode.noAreaSelected)
    } catch {
      return .fail(errorCode: NativeErrorCode.targetError)
    }
  }

  // MARK: - Cluster 2: microphone + accessibility preflight

  /// Verbatim from `startRecording` lines 356-377. Runs the microphone
  /// preflight first (matches the original ordering); on satisfied, runs
  /// the accessibility-blocks-recording check. Mic wins as the first failure
  /// when both would fail.
  ///
  /// The `target` input is echoed back on success purely to keep the
  /// `PreflightOutcome` shape symmetric across the two clusters and let
  /// callers chain switches without unwrapping a separate value.
  func evaluateMicAndAccessibility(
    target: CaptureTarget,
    sessionDisableMicrophone: Bool,
    audioDeviceId: String?,
    audioAuthorized: Bool,
    cursorEnabledForRecording: Bool,
    cursorLinked: Bool,
    accessibilityAllowed: Bool
  ) -> PreflightOutcome {
    if !RecordingPreflightService.microphoneSatisfied(
      disableMicrophone: sessionDisableMicrophone,
      audioDeviceId: audioDeviceId,
      audioAuthorized: audioAuthorized
    ) {
      return .fail(errorCode: NativeErrorCode.microphonePermissionRequired)
    }

    if RecordingPreflightService.accessibilityBlocksRecording(
      cursorEnabledForRecording: cursorEnabledForRecording,
      cursorLinked: cursorLinked,
      accessibilityAllowed: accessibilityAllowed
    ) {
      return .fail(errorCode: NativeErrorCode.accessibilityPermissionRequired)
    }

    return .proceed(target)
  }
}
