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
}
