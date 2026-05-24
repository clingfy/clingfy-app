import CoreGraphics
import Foundation

/// Slice 9 / PR 33b: a typed, immutable snapshot of every facade-state and
/// preference value that `ScreenRecorderFacade.startRecording` reads.
///
/// Why this exists — dependency reduction, not behavior change. The audit
/// for the eventual `startRecording`-into-`RecordingEngine` move (PR 33b
/// finding) showed `startRecording` reads ~16 scattered values directly off
/// the facade: `prefs.*`, `selectedDisplayID`/`selectedAppWindowID`, and the
/// facade-private `effective*` computed properties. Moving the method while
/// it still reaches for those would force a ~20-closure signature or a
/// ~30-member host protocol. Collecting the reads into one value object
/// shrinks that future seam to a single parameter.
///
/// **Ordering contract.** Three of these values (`effectiveOverlay…`,
/// `effectiveCursor…`, `effectiveCameraCaptureMode…`, and the derived
/// `shouldRecordSeparateCameraAsset`) depend on the per-session
/// `sessionDisable*` flags that `startRecording` writes near the top of the
/// method. The context MUST therefore be built *after* those flags are set.
/// `prefs.*` and the selection fields are not mutated anywhere inside
/// `startRecording` (including its async camera-permission / overlay tail),
/// so a single snapshot is observably identical to the original live reads.
///
/// **Intentionally excluded:** `shouldSuppressOverlayWindowDuringCapture`.
/// It depends on the capture backend, which `startRecording` swaps in via
/// `setCaptureBackend(...)` partway through the method — snapshotting it
/// early would capture a stale value. It stays a live facade read.
///
/// Engine-domain DTO; see `windows-port-inventory.md` §7.
struct StartRecordingContext: Equatable {

  // MARK: Request + args-derived

  /// Parsed `startRecording` method-channel arguments.
  let request: StartRecordingRequest
  /// `args["frameRate"]`, default 60 — matches the inline parse.
  let frameRate: Int
  /// `args["systemAudioEnabled"]`, default false — matches the inline parse.
  let systemAudioEnabled: Bool

  // MARK: Capture-target selection (facade fields)

  let selectedDisplayID: CGDirectDisplayID?
  let selectedAppWindowID: CGWindowID?

  // MARK: Preference reads

  let displayMode: DisplayTargetMode
  let areaRect: CGRect?
  let areaDisplayId: Int?
  let audioDeviceId: String?
  let recordingQuality: RecordingQuality
  let cursorLinked: Bool
  let excludeRecorderApp: Bool
  let videoDeviceId: String?
  let overlayMirror: Bool
  let overlayLinked: Bool

  // MARK: Effective (session-flag-adjusted) decisions

  /// `prefs.overlayEnabled && !sessionDisableCameraOverlay`.
  let effectiveOverlayEnabledForRecording: Bool
  /// `CursorHighlightCoordinator.effectiveCursorEnabledForRecording(...)`.
  let effectiveCursorEnabledForRecording: Bool
  /// `prefs.cameraCaptureMode` (session flags do not currently alter it,
  /// but the facade resolves it through the `effective*` accessor).
  let effectiveCameraCaptureModeForRecording: CameraCaptureMode
  /// `effectiveOverlayEnabledForRecording && overlayLinked
  ///   && effectiveCameraCaptureModeForRecording == .separateCameraAsset`.
  let shouldRecordSeparateCameraAsset: Bool

  /// Assembles the context from the facade's `startRecording` locals. The
  /// caller (the facade) passes the four `effective*` values explicitly
  /// because they are facade-private computed properties — and it must do
  /// so *after* writing the `sessionDisable*` flags (see ordering contract
  /// in the type doc).
  @MainActor
  static func from(
    request: StartRecordingRequest,
    args: [String: Any]?,
    prefs: PreferencesStore,
    selectedDisplayID: CGDirectDisplayID?,
    selectedAppWindowID: CGWindowID?,
    effectiveOverlayEnabledForRecording: Bool,
    effectiveCursorEnabledForRecording: Bool,
    effectiveCameraCaptureModeForRecording: CameraCaptureMode,
    shouldRecordSeparateCameraAsset: Bool
  ) -> StartRecordingContext {
    StartRecordingContext(
      request: request,
      frameRate: args?["frameRate"] as? Int ?? 60,
      systemAudioEnabled: args?["systemAudioEnabled"] as? Bool ?? false,
      selectedDisplayID: selectedDisplayID,
      selectedAppWindowID: selectedAppWindowID,
      displayMode: prefs.displayMode,
      areaRect: prefs.areaRect,
      areaDisplayId: prefs.areaDisplayId,
      audioDeviceId: prefs.audioDeviceId,
      recordingQuality: prefs.recordingQuality,
      cursorLinked: prefs.cursorLinked,
      excludeRecorderApp: prefs.excludeRecorderApp,
      videoDeviceId: prefs.videoDeviceId,
      overlayMirror: prefs.overlayMirror,
      overlayLinked: prefs.overlayLinked,
      effectiveOverlayEnabledForRecording: effectiveOverlayEnabledForRecording,
      effectiveCursorEnabledForRecording: effectiveCursorEnabledForRecording,
      effectiveCameraCaptureModeForRecording: effectiveCameraCaptureModeForRecording,
      shouldRecordSeparateCameraAsset: shouldRecordSeparateCameraAsset
    )
  }
}
