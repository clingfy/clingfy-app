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

  // MARK: - Slice 7 / PR 23: project + camera-session preparation

  /// Inputs the facade gathers from prefs / per-session state before calling
  /// `prepareStart(...)`. Bundled into one struct purely to keep the call
  /// site readable — every field maps 1:1 to a value that used to be read
  /// inline in `startRecording`.
  struct PrepareStartInputs {
    let captureTarget: CaptureTarget
    let frameRate: Int
    let displayMode: DisplayTargetMode
    let selectedAppWindowID: CGWindowID?
    let recordingQuality: RecordingQuality
    let cursorEnabledForRecording: Bool
    let cursorLinked: Bool
    let excludeRecorderApp: Bool
    let shouldRecordSeparateCameraAsset: Bool
    let videoDeviceId: String?
    let overlayMirror: Bool
    let editorSeed: RecordingMetadata.EditorSeed
  }

  /// Result returned to the facade. The facade applies state mutations in
  /// the order it always did:
  ///   1. `activeRecordingProjectRoot = nil` (before the call)
  ///   2. `cameraCoordination.setPendingRecordingSession(nil)` (before the call)
  ///   3. `cancelRequestedDuringStart = false` (before the call)
  ///   4. `onProjectRootResolved` callback fires inside the coordinator — the
  ///      facade sets `activeRecordingProjectRoot = projectRoot` + logs
  ///   5. `cameraCoordination.setPendingRecordingSession(prepared.cameraSession)`
  ///      (after the call returns)
  ///   6. `pendingMetadata = prepared.metadata` (after the call returns)
  struct PreparedStart {
    let projectRoot: URL
    let projectId: String
    let screenVideoURL: URL
    let metadata: RecordingMetadata
    let cameraSession: CameraRecordingSession?
  }

  /// Moves the project-preparation block of `startRecording` (lines 378-429
  /// pre-PR-23) into the coordinator: create skeleton → preflight storage →
  /// hand control back to the facade so it can claim
  /// `activeRecordingProjectRoot` + log → optionally build the
  /// camera-recording session → write the project files.
  ///
  /// Error-mode preservation is critical here: the original code sets
  /// `activeRecordingProjectRoot = projectRoot` BETWEEN the storage preflight
  /// and `writeProjectFiles`. `finishStartWithError` later reads that field
  /// to decide whether to mark the manifest `.failed`. That means:
  ///   - storage preflight throws → `activeRecordingProjectRoot` stays nil →
  ///     no manifest update on cleanup (no project exists yet).
  ///   - `writeProjectFiles` throws → `activeRecordingProjectRoot` IS set →
  ///     manifest gets marked `.failed` on cleanup.
  ///
  /// The `onProjectRootResolved` callback is what bridges those two states:
  /// it fires only after the storage preflight succeeds, so the facade owns
  /// the claim-the-project-root side effect at exactly the original timing.
  ///
  /// `preflightStorage` is also a closure rather than a direct call: it
  /// hides `preflightCaptureDestination` (facade method that uses the
  /// already-extracted Slice-1 `CaptureDestinationPreflightPolicy` + still
  /// reads facade state for the storage diagnostic).
  func prepareStart(
    inputs: PrepareStartInputs,
    projectService: RecordingProjectService,
    cameraCoordination: CameraCoordinationController,
    preflightStorage: (URL) throws -> Void,
    onProjectRootResolved: (_ projectRoot: URL, _ screenVideoURL: URL) -> Void
  ) throws -> PreparedStart {
    let skeleton = try projectService.createSkeleton()

    try preflightStorage(skeleton.screenVideoURL)

    // Facade owns `activeRecordingProjectRoot` + the "Prepared recording
    // project" log; this callback fires at the exact pre-PR-23 timing so
    // `finishStartWithError`'s manifest-failure decision is unchanged.
    onProjectRootResolved(skeleton.projectRoot, skeleton.screenVideoURL)

    let cameraSession: CameraRecordingSession? =
      inputs.shouldRecordSeparateCameraAsset
      ? cameraCoordination.makeRecordingSession(
        projectRoot: skeleton.projectRoot,
        deviceId: inputs.videoDeviceId,
        mirrored: inputs.overlayMirror)
      : nil

    let metadata = try projectService.writeProjectFiles(
      projectRoot: skeleton.projectRoot,
      projectId: skeleton.projectId,
      metadataInputs: .init(
        displayMode: inputs.displayMode,
        displayID: inputs.captureTarget.displayID,
        cropRect: inputs.captureTarget.cropRect,
        frameRate: inputs.frameRate,
        quality: inputs.recordingQuality,
        cursorEnabled: inputs.cursorEnabledForRecording,
        cursorLinked: inputs.cursorLinked,
        windowID: (inputs.displayMode == .singleAppWindow ? inputs.selectedAppWindowID : nil),
        excludedRecorderApp: inputs.excludeRecorderApp
      ),
      cameraCaptureInfo: cameraCoordination.makeCaptureInfo(
        projectRoot: skeleton.projectRoot,
        shouldRecordSeparateCameraAsset: inputs.shouldRecordSeparateCameraAsset,
        deviceId: inputs.videoDeviceId,
        mirrored: inputs.overlayMirror),
      editorSeed: inputs.editorSeed,
      includeCameraInManifest: inputs.shouldRecordSeparateCameraAsset
    )

    return PreparedStart(
      projectRoot: skeleton.projectRoot,
      projectId: skeleton.projectId,
      screenVideoURL: skeleton.screenVideoURL,
      metadata: metadata,
      cameraSession: cameraSession
    )
  }

  // MARK: - Slice 7 / PR 24: begin-capture branching

  /// Owns the "separate camera asset first vs. straight to screen" branch
  /// that used to live inline in `startRecording`'s `startScreenCapture`
  /// closure. The two side effects (`cameraRecorder.begin(session:)` +
  /// `handleCameraRecorderBeginResult(...)`) and the inner
  /// `beginCapture()` body (which touches `suppressOverlayWindowDuring
  /// SeparateCameraCapture`, `updateOverlayVisibility()`, and
  /// `startCapture(...)`) stay on the facade — the coordinator never sees
  /// `target` / `frameRate` / `outputURL` / `overlayID` / `systemAudio
  /// Enabled`. They were captured in the outer closure when it was built;
  /// the `beginScreenCapture` closure passed in here carries them.
  ///
  /// Ordering preserved exactly:
  ///   - no separate camera (or no pending session) → `beginScreenCapture`
  ///   - separate camera + session → `beginCameraRecording(session)` then
  ///     `handleCameraBeginResult(result, beginScreenCapture)` (the existing
  ///     `handleCameraRecorderBeginResult` on the facade is what wraps the
  ///     error into FlutterError + dispatches to `beginCapture` /
  ///     `finishStartWithError` on success / failure).
  func beginCaptureFlow(
    shouldRecordSeparateCameraAsset: Bool,
    cameraSession: CameraRecordingSession?,
    beginScreenCapture: @escaping () -> Void,
    beginCameraRecording: (
      CameraRecordingSession, @escaping (Result<Void, Error>) -> Void
    ) -> Void,
    handleCameraBeginResult: @escaping (
      Result<Void, Error>, @escaping () -> Void
    ) -> Void
  ) {
    guard shouldRecordSeparateCameraAsset, let session = cameraSession else {
      beginScreenCapture()
      return
    }

    beginCameraRecording(session) { result in
      handleCameraBeginResult(result, beginScreenCapture)
    }
  }

  // MARK: - Slice 7 / PR 26: startCapture orchestration

  /// Inputs the facade gathers for `startCapture`. Three fields are closures
  /// instead of plain values because the coordinator first runs
  /// `updateOverlayVisibility` (which can rebuild the camera overlay and
  /// change `camera.overlayWindowID` / `camera.isShowing`); the
  /// `effectiveOverlayID` resolution that follows must read FRESH camera
  /// state to match the pre-PR-26 behavior.
  struct StartCaptureInput {
    let target: CaptureTarget
    let frameRate: Int
    let outputURL: () throws -> URL
    let overlayID: CGWindowID?
    let systemAudioEnabled: Bool

    let shouldRecordSeparateCameraAsset: Bool
    let shouldSuppressOverlayWindowDuringCapture: Bool

    // Closures — read AFTER updateOverlayVisibility runs.
    let effectiveOverlayEnabledForRecording: () -> Bool
    let cameraIsShowing: () -> Bool
    let cameraOverlayWindowID: () -> CGWindowID?

    let audioDeviceID: String?
    let disableMicrophone: Bool
    let excludeRecorderApp: Bool
    let excludeMicFromSystemAudio: Bool
  }

  /// Side-effect surface the facade implements. Each field is one named
  /// step from the old `startCapture` / `beginCapture` body so the
  /// orchestration ordering can be asserted by tests against a recording
  /// mock.
  struct StartCaptureEffects {
    let setSuppressOverlayDuringCapture: (Bool) -> Void
    let updateOverlayVisibility: () -> Void
    let resetMicrophoneLevelFlag: () -> Void
    let logStartCaptureEntry: () -> Void
    let logEffectiveOverlayID: (CGWindowID?) -> Void
    let setPendingStartCaptureConfig: (CaptureStartConfig) -> Void
    let startCapture: (CaptureStartConfig) -> Void
  }

  /// Pre-PR-26 ordering — preserved byte-for-byte:
  ///   1. set `suppressOverlayWindowDuringSeparateCameraCapture` (was in
  ///      the inline `beginCapture` closure)
  ///   2. `updateOverlayVisibility()` (was in the inline `beginCapture`
  ///      closure — runs BEFORE effectiveOverlayID is computed)
  ///   3. `hasReceivedRecordingMicrophoneLevel = false` (was first line
  ///      of startCapture)
  ///   4. entry log (was second statement of startCapture)
  ///   5. compute `effectiveOverlayID` (reads fresh camera state via the
  ///      input closures, matching the original `if let overlayID;
  ///      guard effectiveOverlayEnabledForRecording, camera.isShowing;
  ///      return camera.overlayWindowID` block)
  ///   6. effectiveOverlayID log
  ///   7. build `CaptureStartConfig` via the Slice-7 / PR-25 builder
  ///   8. `pendingStartCaptureConfig = cfg`
  ///   9. `capture.start(config: cfg)`
  func startCapture(
    input: StartCaptureInput,
    configBuilder: CaptureStartConfigBuilder,
    effects: StartCaptureEffects
  ) {
    effects.setSuppressOverlayDuringCapture(input.shouldSuppressOverlayWindowDuringCapture)
    effects.updateOverlayVisibility()

    effects.resetMicrophoneLevelFlag()
    effects.logStartCaptureEntry()

    let effectiveOverlayID: CGWindowID? = {
      if let overlayID = input.overlayID { return overlayID }
      guard input.effectiveOverlayEnabledForRecording(),
        input.cameraIsShowing()
      else { return nil }
      return input.cameraOverlayWindowID()
    }()

    effects.logEffectiveOverlayID(effectiveOverlayID)

    let cfg = configBuilder.build(
      .init(
        target: input.target,
        frameRate: input.frameRate,
        outputURL: input.outputURL,
        effectiveOverlayID: effectiveOverlayID,
        systemAudioEnabled: input.systemAudioEnabled,
        audioDeviceID: input.audioDeviceID,
        disableMicrophone: input.disableMicrophone,
        excludeRecorderApp: input.excludeRecorderApp,
        shouldRecordSeparateCameraAsset: input.shouldRecordSeparateCameraAsset,
        excludeMicFromSystemAudio: input.excludeMicFromSystemAudio))

    effects.setPendingStartCaptureConfig(cfg)
    effects.startCapture(cfg)
  }
}
