import CoreGraphics
import XCTest

@testable import Clingfy

/// Slice 5 / PR 20 guard: the two preflight clusters extracted into
/// `RecordingSessionCoordinator` reproduce the exact truth table of the
/// inline gates that used to live in `ScreenRecorderFacade.startRecording`
/// (Slice 3 / PR 14's pure helpers + Slice 3 / PR 12's target resolver).
@MainActor
final class RecordingSessionCoordinatorTests: XCTestCase {

  // MARK: - Display-service stub

  /// Stub `CaptureDisplayResolving` driven by closures so each test can
  /// dictate exactly what the target resolver sees.
  private final class StubDisplayResolver: CaptureDisplayResolving {
    var displayIDForAppWindowOrMainResult: CGDirectDisplayID = 1
    var displayIDUnderMouseResult: CGDirectDisplayID? = 1
    var captureTargetForWindowIDResult: (displayID: CGDirectDisplayID, rect: CGRect)? = nil

    func displayIDForAppWindowOrMain() -> CGDirectDisplayID {
      displayIDForAppWindowOrMainResult
    }
    func displayIDUnderMouse() -> CGDirectDisplayID? {
      displayIDUnderMouseResult
    }
    func captureTarget(forWindowID id: CGWindowID) -> (
      displayID: CGDirectDisplayID, rect: CGRect
    )? {
      captureTargetForWindowIDResult
    }
  }

  private func makeCoordinator() -> RecordingSessionCoordinator {
    RecordingSessionCoordinator(captureTargetResolver: CaptureTargetResolver())
  }

  private func explicitIDInput(displayID: CGDirectDisplayID = 1)
    -> CaptureTargetResolver.Input
  {
    .init(
      displayMode: .explicitID, selectedDisplayID: displayID,
      selectedAppWindowID: nil, areaRect: nil, areaDisplayId: nil)
  }

  // MARK: - Cluster 1: screen permission + capture-target resolution

  func testFailsImmediatelyWhenScreenPermissionDenied() {
    let coord = makeCoordinator()
    let outcome = coord.evaluateScreenPermissionAndTarget(
      screenRecordingSatisfied: { false },
      captureTargetInput: explicitIDInput(),
      displayService: StubDisplayResolver())

    XCTAssertEqual(outcome, .fail(errorCode: NativeErrorCode.screenRecordingPermission))
  }

  func testProceedsWithResolvedTargetWhenScreenPermissionGranted() {
    let coord = makeCoordinator()
    let outcome = coord.evaluateScreenPermissionAndTarget(
      screenRecordingSatisfied: { true },
      captureTargetInput: explicitIDInput(displayID: 42),
      displayService: StubDisplayResolver())

    switch outcome {
    case .proceed(let target):
      XCTAssertEqual(target.displayID, 42)
      XCTAssertEqual(target.mode, .explicitID)
    case .fail(let code):
      XCTFail("expected .proceed, got .fail(\(code))")
    }
  }

  func testMapsNoWindowSelectedToNoWindowSelectedCode() {
    let coord = makeCoordinator()
    let outcome = coord.evaluateScreenPermissionAndTarget(
      screenRecordingSatisfied: { true },
      captureTargetInput: .init(
        displayMode: .singleAppWindow, selectedDisplayID: nil,
        selectedAppWindowID: nil, areaRect: nil, areaDisplayId: nil),
      displayService: StubDisplayResolver())

    XCTAssertEqual(outcome, .fail(errorCode: NativeErrorCode.noWindowSelected))
  }

  func testMapsWindowUnavailableToWindowNotAvailableCode() {
    let coord = makeCoordinator()
    let stub = StubDisplayResolver()
    stub.captureTargetForWindowIDResult = nil  // window vanished
    let outcome = coord.evaluateScreenPermissionAndTarget(
      screenRecordingSatisfied: { true },
      captureTargetInput: .init(
        displayMode: .singleAppWindow, selectedDisplayID: nil,
        selectedAppWindowID: 999, areaRect: nil, areaDisplayId: nil),
      displayService: stub)

    XCTAssertEqual(outcome, .fail(errorCode: NativeErrorCode.windowNotAvailable))
  }

  func testMapsNoAreaSelectedToNoAreaSelectedCode() {
    let coord = makeCoordinator()
    let outcome = coord.evaluateScreenPermissionAndTarget(
      screenRecordingSatisfied: { true },
      captureTargetInput: .init(
        displayMode: .areaRecording, selectedDisplayID: nil,
        selectedAppWindowID: nil, areaRect: nil, areaDisplayId: nil),
      displayService: StubDisplayResolver())

    XCTAssertEqual(outcome, .fail(errorCode: NativeErrorCode.noAreaSelected))
  }

  // MARK: - Cluster 2: microphone + accessibility preflight

  private var anyTarget: CaptureTarget {
    CaptureTarget(mode: .explicitID, displayID: 1, cropRect: nil, windowID: nil)
  }

  func testMicAndAccessibilityProceedsOnHappyPath() {
    let coord = makeCoordinator()
    let outcome = coord.evaluateMicAndAccessibility(
      target: anyTarget,
      sessionDisableMicrophone: false,
      audioDeviceId: nil,  // no mic selected ⇒ no auth required
      audioAuthorized: false,
      cursorEnabledForRecording: false,
      cursorLinked: false,
      accessibilityAllowed: true)

    if case .proceed(let echoed) = outcome {
      XCTAssertEqual(echoed.displayID, 1)
    } else {
      XCTFail("expected .proceed, got \(outcome)")
    }
  }

  func testMicFailureIsReturnedBeforeAccessibility() {
    let coord = makeCoordinator()
    // Both gates would fail: real mic selected + unauthorized,
    // AND accessibility-blocking config. Mic wins as the first failure.
    let outcome = coord.evaluateMicAndAccessibility(
      target: anyTarget,
      sessionDisableMicrophone: false,
      audioDeviceId: "mic-1",
      audioAuthorized: false,
      cursorEnabledForRecording: true,
      cursorLinked: true,
      accessibilityAllowed: false)

    XCTAssertEqual(outcome, .fail(errorCode: NativeErrorCode.microphonePermissionRequired))
  }

  func testAccessibilityFailureSurfacesWhenMicPasses() {
    let coord = makeCoordinator()
    let outcome = coord.evaluateMicAndAccessibility(
      target: anyTarget,
      sessionDisableMicrophone: true,  // mic gate satisfied
      audioDeviceId: "mic-1",
      audioAuthorized: false,
      cursorEnabledForRecording: true,
      cursorLinked: true,
      accessibilityAllowed: false)

    XCTAssertEqual(outcome, .fail(errorCode: NativeErrorCode.accessibilityPermissionRequired))
  }

  func testNoMicSelectedSkipsMicGateRegardlessOfAuth() {
    let coord = makeCoordinator()
    for sentinel in [nil, "", "__none__"] as [String?] {
      let outcome = coord.evaluateMicAndAccessibility(
        target: anyTarget,
        sessionDisableMicrophone: false,
        audioDeviceId: sentinel,
        audioAuthorized: false,
        cursorEnabledForRecording: false,
        cursorLinked: false,
        accessibilityAllowed: true)

      if case .proceed = outcome { /* ok */ } else {
        XCTFail("expected .proceed for audioDeviceId=\(sentinel ?? "nil"), got \(outcome)")
      }
    }
  }

  // MARK: - Slice 7 / PR 23: prepareStart

  /// Real-FS helper — `RecordingProjectService.createSkeleton` writes the
  /// `.clingfyproj` folder tree under `AppPaths.recordingsRoot()`. Each test
  /// resets the workspace so the artifacts don't collide.
  private func resetRecordingsWorkspace() {
    let root = AppPaths.recordingsRoot()
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  private func makeEditorSeed() -> RecordingMetadata.EditorSeed {
    // Mirrors `makeBasicEditorSeed()` in `RecordingProjectServiceTests` —
    // any valid `EditorSeed` is fine here because `prepareStart` just
    // threads it through to `writeProjectFiles`.
    RecordingMetadata.EditorSeed(
      cameraVisible: true,
      cameraLayoutPreset: .overlayBottomRight,
      cameraNormalizedCenter: nil,
      cameraSizeFactor: 0.18,
      cameraShape: .circle,
      cameraCornerRadius: 0.0,
      cameraBorderWidth: 0.0,
      cameraBorderColorArgb: nil,
      cameraShadow: 0,
      cameraOpacity: 1.0,
      cameraMirror: true,
      cameraContentMode: .fill,
      cameraZoomBehavior: CameraCompositionParams.defaultZoomBehavior,
      cameraChromaKeyEnabled: false,
      cameraChromaKeyStrength: 0.4,
      cameraChromaKeyColorArgb: nil
    )
  }

  private func makeInputs(
    shouldRecordSeparateCameraAsset: Bool = false,
    selectedAppWindowID: CGWindowID? = nil,
    displayMode: DisplayTargetMode = .explicitID
  ) -> RecordingSessionCoordinator.PrepareStartInputs {
    .init(
      captureTarget: CaptureTarget(
        mode: displayMode, displayID: 1, cropRect: nil,
        windowID: displayMode == .singleAppWindow ? selectedAppWindowID : nil),
      frameRate: 60,
      displayMode: displayMode,
      selectedAppWindowID: selectedAppWindowID,
      recordingQuality: .fhd,
      cursorEnabledForRecording: true,
      cursorLinked: false,
      excludeRecorderApp: false,
      shouldRecordSeparateCameraAsset: shouldRecordSeparateCameraAsset,
      videoDeviceId: nil,
      overlayMirror: false,
      editorSeed: makeEditorSeed()
    )
  }

  func testPrepareStartPropagatesCreateSkeletonError() {
    resetRecordingsWorkspace()
    let coord = makeCoordinator()

    // Force createSkeleton to fail by pre-creating a file where the root
    // recordings dir wants to be a directory.
    let root = AppPaths.recordingsRoot()
    try? FileManager.default.removeItem(at: root)
    FileManager.default.createFile(atPath: root.path, contents: nil)

    var onResolvedFired = false
    XCTAssertThrowsError(
      try coord.prepareStart(
        inputs: makeInputs(),
        projectService: RecordingProjectService(),
        cameraCoordination: CameraCoordinationController(),
        preflightStorage: { _ in },
        onProjectRootResolved: { _, _ in onResolvedFired = true }
      )
    )
    XCTAssertFalse(
      onResolvedFired,
      "onProjectRootResolved must not fire when createSkeleton throws")

    // Cleanup so subsequent tests can use the workspace.
    try? FileManager.default.removeItem(at: root)
  }

  func testPrepareStartPropagatesStoragePreflightError() throws {
    resetRecordingsWorkspace()
    let coord = makeCoordinator()
    struct StorageFull: Error {}
    var onResolvedFired = false

    XCTAssertThrowsError(
      try coord.prepareStart(
        inputs: makeInputs(),
        projectService: RecordingProjectService(),
        cameraCoordination: CameraCoordinationController(),
        preflightStorage: { _ in throw StorageFull() },
        onProjectRootResolved: { _, _ in onResolvedFired = true }
      )
    ) { error in
      XCTAssertTrue(error is StorageFull)
    }
    XCTAssertFalse(
      onResolvedFired,
      "onProjectRootResolved must not fire when storage preflight throws")
  }

  func testPrepareStartFiresOnProjectRootResolvedBetweenPreflightAndWrite() throws {
    resetRecordingsWorkspace()
    let coord = makeCoordinator()
    var callbackArgs: (projectRoot: URL, screenVideoURL: URL)?

    let prepared = try coord.prepareStart(
      inputs: makeInputs(),
      projectService: RecordingProjectService(),
      cameraCoordination: CameraCoordinationController(),
      preflightStorage: { _ in },
      onProjectRootResolved: { projectRoot, screenVideoURL in
        callbackArgs = (projectRoot, screenVideoURL)
      }
    )

    XCTAssertNotNil(callbackArgs, "onProjectRootResolved must fire on success")
    XCTAssertEqual(callbackArgs?.projectRoot, prepared.projectRoot)
    XCTAssertEqual(callbackArgs?.screenVideoURL, prepared.screenVideoURL)
  }

  func testPrepareStartReturnsNilCameraSessionWhenNotSeparateCameraAsset() throws {
    resetRecordingsWorkspace()
    let coord = makeCoordinator()

    let prepared = try coord.prepareStart(
      inputs: makeInputs(shouldRecordSeparateCameraAsset: false),
      projectService: RecordingProjectService(),
      cameraCoordination: CameraCoordinationController(),
      preflightStorage: { _ in },
      onProjectRootResolved: { _, _ in }
    )

    XCTAssertNil(prepared.cameraSession)
    XCTAssertNil(
      prepared.metadata.camera,
      "no camera asset section when shouldRecordSeparateCameraAsset is false")
  }

  func testPrepareStartBuildsCameraSessionWhenSeparateCameraAsset() throws {
    resetRecordingsWorkspace()
    let coord = makeCoordinator()

    let prepared = try coord.prepareStart(
      inputs: makeInputs(shouldRecordSeparateCameraAsset: true),
      projectService: RecordingProjectService(),
      cameraCoordination: CameraCoordinationController(),
      preflightStorage: { _ in },
      onProjectRootResolved: { _, _ in }
    )

    XCTAssertNotNil(prepared.cameraSession)
    XCTAssertEqual(prepared.cameraSession?.mirroredRaw, false)
    XCTAssertEqual(
      prepared.cameraSession?.outputURL,
      RecordingProjectPaths.cameraRawURL(for: prepared.projectRoot))
    // Manifest reflects camera presence.
    XCTAssertNotNil(prepared.metadata.camera)
    XCTAssertEqual(prepared.metadata.camera?.enabled, true)
  }

  func testPrepareStartWritesManifestToProjectRootAndReturnsInMemoryMetadata() throws {
    resetRecordingsWorkspace()
    let coord = makeCoordinator()

    let prepared = try coord.prepareStart(
      inputs: makeInputs(),
      projectService: RecordingProjectService(),
      cameraCoordination: CameraCoordinationController(),
      preflightStorage: { _ in },
      onProjectRootResolved: { _, _ in }
    )

    // Only the manifest is persisted by writeProjectFiles; the screen
    // metadata sidecar is held in-memory in `prepared.metadata` and
    // written by the facade later (via `writeMetadataSidecar` on
    // backendDidStart).
    let manifestURL = RecordingProjectPaths.manifestURL(for: prepared.projectRoot)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: manifestURL.path),
      "manifest must exist after writeProjectFiles")
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: RecordingProjectPaths.screenMetadataURL(for: prepared.projectRoot).path),
      "screen metadata sidecar must NOT be written by prepareStart — facade owns that on start")

    XCTAssertEqual(prepared.projectId.hasPrefix("rec_"), true)
    XCTAssertEqual(prepared.metadata.screen.frameRate, 60)
  }

  func testPrepareStartThreadsWindowIDOnlyForSingleAppWindowMode() throws {
    resetRecordingsWorkspace()
    let coord = makeCoordinator()

    // For singleAppWindow, the metadata's windowID should reflect selectedAppWindowID.
    let preparedSingleWindow = try coord.prepareStart(
      inputs: makeInputs(
        selectedAppWindowID: 4242, displayMode: .singleAppWindow),
      projectService: RecordingProjectService(),
      cameraCoordination: CameraCoordinationController(),
      preflightStorage: { _ in },
      onProjectRootResolved: { _, _ in }
    )
    XCTAssertEqual(preparedSingleWindow.metadata.screen.windowId, 4242)

    // For any other mode, the windowId is dropped even if selectedAppWindowID is set.
    let preparedExplicit = try coord.prepareStart(
      inputs: makeInputs(selectedAppWindowID: 4242, displayMode: .explicitID),
      projectService: RecordingProjectService(),
      cameraCoordination: CameraCoordinationController(),
      preflightStorage: { _ in },
      onProjectRootResolved: { _, _ in }
    )
    XCTAssertNil(preparedExplicit.metadata.screen.windowId)
  }

  // MARK: - Slice 7 / PR 24: beginCaptureFlow

  /// Test-only camera session — `CameraRecordingSession` doesn't have a
  /// default initializer and the binder doesn't care what's in it (it's
  /// purely a payload threaded through to `beginCameraRecording`), so a
  /// minimal instance is enough.
  private func makeCameraSessionStub() -> CameraRecordingSession {
    CameraRecordingSession(
      outputURL: URL(fileURLWithPath: "/tmp/cam-raw.mov"),
      metadataURL: URL(fileURLWithPath: "/tmp/cam-meta.json"),
      segmentDirectoryURL: URL(fileURLWithPath: "/tmp/cam-segments"),
      deviceId: "cam-1",
      mirroredRaw: false,
      nominalFrameRate: 30,
      dimensions: CameraRecordingMetadata.Dimensions(width: 1280, height: 720))
  }

  func testBeginCaptureFlowGoesStraightToScreenWhenSeparateCameraDisabled() {
    let coord = makeCoordinator()
    var beginScreenCalls = 0
    var beginCameraCalls = 0
    var handleResultCalls = 0

    coord.beginCaptureFlow(
      shouldRecordSeparateCameraAsset: false,
      cameraSession: makeCameraSessionStub(),  // ignored when flag is false
      beginScreenCapture: { beginScreenCalls += 1 },
      beginCameraRecording: { _, _ in beginCameraCalls += 1 },
      handleCameraBeginResult: { _, _ in handleResultCalls += 1 }
    )

    XCTAssertEqual(beginScreenCalls, 1)
    XCTAssertEqual(beginCameraCalls, 0)
    XCTAssertEqual(handleResultCalls, 0)
  }

  func testBeginCaptureFlowGoesStraightToScreenWhenCameraSessionIsNil() {
    // Defensive guard — separate-camera-asset is on, but the pending
    // session is unexpectedly nil. Original code falls through to
    // `beginCapture()` rather than failing the start.
    let coord = makeCoordinator()
    var beginScreenCalls = 0
    var beginCameraCalls = 0

    coord.beginCaptureFlow(
      shouldRecordSeparateCameraAsset: true,
      cameraSession: nil,
      beginScreenCapture: { beginScreenCalls += 1 },
      beginCameraRecording: { _, _ in beginCameraCalls += 1 },
      handleCameraBeginResult: { _, _ in }
    )

    XCTAssertEqual(beginScreenCalls, 1)
    XCTAssertEqual(beginCameraCalls, 0)
  }

  func testBeginCaptureFlowStartsCameraFirstThenForwardsResultToHandler() {
    let coord = makeCoordinator()
    let session = makeCameraSessionStub()

    var beginScreenCalls = 0
    var beginCameraReceivedSession: CameraRecordingSession?
    var handlerReceivedResult: Result<Void, Error>?

    // Capture the camera-completion so we can fire it ourselves to drive
    // the test through the success/failure paths.
    var capturedCameraCompletion: ((Result<Void, Error>) -> Void)?

    coord.beginCaptureFlow(
      shouldRecordSeparateCameraAsset: true,
      cameraSession: session,
      beginScreenCapture: { beginScreenCalls += 1 },
      beginCameraRecording: { s, completion in
        beginCameraReceivedSession = s
        capturedCameraCompletion = completion
      },
      handleCameraBeginResult: { result, beginScreen in
        handlerReceivedResult = result
        // Mirror what the facade's handleCameraRecorderBeginResult does on
        // success — call beginScreenCapture. We do it inline here so the
        // test can assert beginScreenCalls reflects the dispatch.
        if case .success = result {
          beginScreen()
        }
      }
    )

    // beginCameraRecording was invoked with the supplied session; screen
    // capture has NOT started yet.
    XCTAssertEqual(beginCameraReceivedSession?.outputURL.lastPathComponent, "cam-raw.mov")
    XCTAssertEqual(beginScreenCalls, 0)
    XCTAssertNil(handlerReceivedResult)

    // Camera finished beginning — happy path. handler should fire, and
    // it should call beginScreen, bumping the screen counter.
    capturedCameraCompletion?(.success(()))

    if case .success = handlerReceivedResult { /* ok */ } else {
      XCTFail("expected .success forwarded to handler, got \(String(describing: handlerReceivedResult))")
    }
    XCTAssertEqual(beginScreenCalls, 1)
  }

  func testBeginCaptureFlowForwardsCameraFailureToHandlerWithoutStartingScreen() {
    let coord = makeCoordinator()
    let session = makeCameraSessionStub()
    struct CameraFailure: Error, Equatable { let code: String }

    var beginScreenCalls = 0
    var handlerReceivedError: Error?
    var capturedCameraCompletion: ((Result<Void, Error>) -> Void)?

    coord.beginCaptureFlow(
      shouldRecordSeparateCameraAsset: true,
      cameraSession: session,
      beginScreenCapture: { beginScreenCalls += 1 },
      beginCameraRecording: { _, completion in
        capturedCameraCompletion = completion
      },
      handleCameraBeginResult: { result, _ in
        if case .failure(let e) = result { handlerReceivedError = e }
        // On failure the facade's real handler does NOT call beginScreen.
      }
    )

    capturedCameraCompletion?(.failure(CameraFailure(code: "CAM_BUSY")))

    XCTAssertEqual((handlerReceivedError as? CameraFailure)?.code, "CAM_BUSY")
    XCTAssertEqual(beginScreenCalls, 0, "screen capture must not start on camera failure")
  }

  // MARK: - Slice 7 / PR 26: startCapture orchestration

  /// Records the ordering of every effect the coordinator triggers, so
  /// `startCapture` tests can assert "suppress-flag set BEFORE update
  /// overlay BEFORE config set BEFORE capture.start" — the exact pre-PR-26
  /// sequence.
  private final class StartCaptureSpy {
    enum Event: Equatable {
      case setSuppress(Bool)
      case updateOverlay
      case resetMicLevel
      case logEntry
      case logEffective(CGWindowID?)
      case setPending  // CaptureStartConfig isn't Equatable — store presence only
      case startCapture  // ditto
    }
    private(set) var events: [Event] = []
    private(set) var pendingConfig: CaptureStartConfig?
    private(set) var startedConfig: CaptureStartConfig?

    func makeEffects() -> RecordingSessionCoordinator.StartCaptureEffects {
      .init(
        setSuppressOverlayDuringCapture: { [self] v in events.append(.setSuppress(v)) },
        updateOverlayVisibility: { [self] in events.append(.updateOverlay) },
        resetMicrophoneLevelFlag: { [self] in events.append(.resetMicLevel) },
        logStartCaptureEntry: { [self] in events.append(.logEntry) },
        logEffectiveOverlayID: { [self] id in events.append(.logEffective(id)) },
        setPendingStartCaptureConfig: { [self] cfg in
          events.append(.setPending)
          pendingConfig = cfg
        },
        startCapture: { [self] cfg in
          events.append(.startCapture)
          startedConfig = cfg
        })
    }
  }

  private func makeStartCaptureInput(
    overlayID: CGWindowID? = nil,
    effectiveOverlayEnabledForRecording: @escaping () -> Bool = { false },
    cameraIsShowing: @escaping () -> Bool = { false },
    cameraOverlayWindowID: @escaping () -> CGWindowID? = { nil },
    shouldSuppressOverlayWindowDuringCapture: Bool = false,
    shouldRecordSeparateCameraAsset: Bool = false,
    systemAudioEnabled: Bool = false,
    audioDeviceID: String? = nil,
    disableMicrophone: Bool = true,
    excludeRecorderApp: Bool = false,
    excludeMicFromSystemAudio: Bool = true
  ) -> RecordingSessionCoordinator.StartCaptureInput {
    .init(
      target: CaptureTarget(mode: .explicitID, displayID: 1, cropRect: nil, windowID: nil),
      frameRate: 60,
      outputURL: { URL(fileURLWithPath: "/tmp/out.mov") },
      overlayID: overlayID,
      systemAudioEnabled: systemAudioEnabled,
      shouldRecordSeparateCameraAsset: shouldRecordSeparateCameraAsset,
      shouldSuppressOverlayWindowDuringCapture: shouldSuppressOverlayWindowDuringCapture,
      effectiveOverlayEnabledForRecording: effectiveOverlayEnabledForRecording,
      cameraIsShowing: cameraIsShowing,
      cameraOverlayWindowID: cameraOverlayWindowID,
      audioDeviceID: audioDeviceID,
      disableMicrophone: disableMicrophone,
      excludeRecorderApp: excludeRecorderApp,
      excludeMicFromSystemAudio: excludeMicFromSystemAudio)
  }

  func testStartCaptureRunsTheSevenEffectsInTheExactPreRefactorOrder() {
    let coord = makeCoordinator()
    let spy = StartCaptureSpy()

    coord.startCapture(
      input: makeStartCaptureInput(shouldSuppressOverlayWindowDuringCapture: true),
      configBuilder: CaptureStartConfigBuilder(),
      effects: spy.makeEffects())

    // Critical: setSuppress runs FIRST so updateOverlayVisibility sees the
    // post-suppress state; resetMicLevel + logEntry run BEFORE effective
    // overlay id is computed; setPending runs BEFORE startCapture.
    XCTAssertEqual(
      spy.events,
      [
        .setSuppress(true),
        .updateOverlay,
        .resetMicLevel,
        .logEntry,
        .logEffective(nil),
        .setPending,
        .startCapture,
      ])
  }

  func testStartCaptureUsesExplicitOverlayIDWhenProvided() {
    let coord = makeCoordinator()
    let spy = StartCaptureSpy()

    coord.startCapture(
      input: makeStartCaptureInput(
        overlayID: 42,
        // Even if the closures say "overlay enabled + camera showing", the
        // explicit overlayID parameter wins — verbatim from the original
        // `if let overlayID { return overlayID }` branch.
        effectiveOverlayEnabledForRecording: { true },
        cameraIsShowing: { true },
        cameraOverlayWindowID: { 99 }),
      configBuilder: CaptureStartConfigBuilder(),
      effects: spy.makeEffects())

    XCTAssertEqual(spy.pendingConfig?.cameraOverlayWindowID, 42)
    XCTAssertEqual(spy.events.first(where: {
      if case .logEffective = $0 { return true }
      return false
    }), .logEffective(42))
  }

  func testStartCaptureFallsBackToCameraOverlayWindowIDWhenOverlayEnabledAndShowing() {
    let coord = makeCoordinator()
    let spy = StartCaptureSpy()

    coord.startCapture(
      input: makeStartCaptureInput(
        overlayID: nil,
        effectiveOverlayEnabledForRecording: { true },
        cameraIsShowing: { true },
        cameraOverlayWindowID: { 77 }),
      configBuilder: CaptureStartConfigBuilder(),
      effects: spy.makeEffects())

    XCTAssertEqual(spy.pendingConfig?.cameraOverlayWindowID, 77)
  }

  func testStartCaptureYieldsNilOverlayIDWhenOverlayDisabledOrCameraHidden() {
    let coord = makeCoordinator()

    // overlay disabled → nil
    let spyDisabled = StartCaptureSpy()
    coord.startCapture(
      input: makeStartCaptureInput(
        overlayID: nil,
        effectiveOverlayEnabledForRecording: { false },
        cameraIsShowing: { true },
        cameraOverlayWindowID: { 99 }),
      configBuilder: CaptureStartConfigBuilder(),
      effects: spyDisabled.makeEffects())
    XCTAssertNil(spyDisabled.pendingConfig?.cameraOverlayWindowID)

    // overlay enabled but camera hidden → nil
    let spyHidden = StartCaptureSpy()
    coord.startCapture(
      input: makeStartCaptureInput(
        overlayID: nil,
        effectiveOverlayEnabledForRecording: { true },
        cameraIsShowing: { false },
        cameraOverlayWindowID: { 99 }),
      configBuilder: CaptureStartConfigBuilder(),
      effects: spyHidden.makeEffects())
    XCTAssertNil(spyHidden.pendingConfig?.cameraOverlayWindowID)
  }

  func testStartCaptureReadsCameraStateAfterUpdateOverlayVisibility() {
    // Behavior preservation: updateOverlayVisibility can rebuild the
    // overlay; the coordinator must read camera.overlayWindowID via the
    // injected closure AFTER updateOverlay fires, not from a value
    // snapshotted at coordinator-call time.
    //
    // The spy itself decorates `updateOverlayVisibility` with a closure that
    // mutates the camera-window-id source. The pendingConfig the spy ends
    // up with then reflects the POST-updateOverlay read.
    final class MutatingCameraSpy {
      var cameraWindowID: CGWindowID? = nil
      private(set) var pendingConfig: CaptureStartConfig?

      func makeEffects() -> RecordingSessionCoordinator.StartCaptureEffects {
        .init(
          setSuppressOverlayDuringCapture: { _ in },
          updateOverlayVisibility: { [self] in cameraWindowID = 555 },
          resetMicrophoneLevelFlag: {},
          logStartCaptureEntry: {},
          logEffectiveOverlayID: { _ in },
          setPendingStartCaptureConfig: { [self] cfg in pendingConfig = cfg },
          startCapture: { _ in })
      }
    }

    let coord = makeCoordinator()
    let spy = MutatingCameraSpy()

    coord.startCapture(
      input: makeStartCaptureInput(
        overlayID: nil,
        effectiveOverlayEnabledForRecording: { true },
        cameraIsShowing: { true },
        cameraOverlayWindowID: { spy.cameraWindowID }),
      configBuilder: CaptureStartConfigBuilder(),
      effects: spy.makeEffects())

    // 555 came from the post-updateOverlay read, NOT the pre-call snapshot
    // (which would have been nil).
    XCTAssertEqual(spy.pendingConfig?.cameraOverlayWindowID, 555)
  }

  func testStartCapturePassesAudioAndExclusionInputsToConfig() {
    let coord = makeCoordinator()
    let spy = StartCaptureSpy()

    coord.startCapture(
      input: makeStartCaptureInput(
        shouldRecordSeparateCameraAsset: true,
        systemAudioEnabled: true,
        audioDeviceID: "__none__",  // sentinel → no device
        disableMicrophone: false,
        excludeRecorderApp: true,
        excludeMicFromSystemAudio: false),
      configBuilder: CaptureStartConfigBuilder(),
      effects: spy.makeEffects())

    let cfg = spy.startedConfig
    XCTAssertNotNil(cfg)
    XCTAssertNil(cfg?.includeAudioDevice, "__none__ sentinel must yield no audio device")
    XCTAssertEqual(cfg?.includeSystemAudio, true)
    XCTAssertEqual(cfg?.excludeRecorderApp, true)
    XCTAssertEqual(cfg?.excludeCameraOverlayWindow, true)
    XCTAssertEqual(cfg?.excludeMicFromSystemAudio, false)
  }

  func testStartCaptureForwardsSameConfigToSetPendingAndStartCapture() {
    let coord = makeCoordinator()
    let spy = StartCaptureSpy()

    coord.startCapture(
      input: makeStartCaptureInput(),
      configBuilder: CaptureStartConfigBuilder(),
      effects: spy.makeEffects())

    // setPending and startCapture both receive the same config instance —
    // the original code: `pendingStartCaptureConfig = cfg; capture.start(config: cfg)`.
    // Both struct copies (not reference identity) must match field-wise.
    XCTAssertNotNil(spy.pendingConfig)
    XCTAssertNotNil(spy.startedConfig)
    XCTAssertEqual(spy.pendingConfig?.target, spy.startedConfig?.target)
    XCTAssertEqual(spy.pendingConfig?.frameRate, spy.startedConfig?.frameRate)
    XCTAssertEqual(spy.pendingConfig?.includeSystemAudio, spy.startedConfig?.includeSystemAudio)
    XCTAssertEqual(
      spy.pendingConfig?.cameraOverlayWindowID, spy.startedConfig?.cameraOverlayWindowID)
  }
}
