import CoreGraphics
import Foundation
import XCTest

@testable import Clingfy

final class PreviewProfileTests: XCTestCase {
  func testFourKTargetUsesViewportSizedCanvasAndCap() {
    let profile = PreviewProfile.make(
      viewBounds: CGSize(width: 800, height: 450),
      backingScale: 2.0,
      targetSize: CGSize(width: 3840, height: 2160),
      fpsHint: 60
    )

    XCTAssertEqual(profile.canvasRenderSize.width, 1440)
    XCTAssertEqual(profile.canvasRenderSize.height, 810)
    XCTAssertEqual(profile.fps, 30)
    XCTAssertLessThanOrEqual(max(profile.canvasRenderSize.width, profile.canvasRenderSize.height), 1440)
  }

  func testSmallViewportDoesNotInflateToExportSize() {
    let profile = PreviewProfile.make(
      viewBounds: CGSize(width: 320, height: 180),
      backingScale: 2.0,
      targetSize: CGSize(width: 3840, height: 2160),
      fpsHint: 30
    )

    XCTAssertEqual(profile.canvasRenderSize.width, 640)
    XCTAssertEqual(profile.canvasRenderSize.height, 360)
    XCTAssertEqual(profile.fps, 30)
  }

  func testLowerFpsHintIsPreserved() {
    let profile = PreviewProfile.make(
      viewBounds: CGSize(width: 1200, height: 675),
      backingScale: 2.0,
      targetSize: CGSize(width: 1920, height: 1080),
      fpsHint: 24
    )

    XCTAssertEqual(profile.fps, 24)
  }

  func testInvalidBoundsFallBackToAspectFittedTargetCap() {
    let profile = PreviewProfile.make(
      viewBounds: .zero,
      backingScale: 0,
      targetSize: CGSize(width: 3840, height: 2160),
      fpsHint: 0
    )

    XCTAssertEqual(profile.canvasRenderSize.width, 1440)
    XCTAssertEqual(profile.canvasRenderSize.height, 810)
    XCTAssertEqual(profile.fps, 30)
  }

}

final class InlinePreviewViewLifecycleTests: XCTestCase {
  func testPreviewLifecyclePayloadIncludesSessionId() {
    let token = UUID()
    let payload = InlinePreviewView.previewLifecycleEventPayload(
      type: "previewReady",
      sessionId: "rec_session_1",
      path: "/tmp/test.mov",
      token: token,
      reason: "ready",
      error: nil
    )

    XCTAssertEqual(payload["type"] as? String, "previewReady")
    XCTAssertEqual(payload["sessionId"] as? String, "rec_session_1")
    XCTAssertEqual(payload["path"] as? String, "/tmp/test.mov")
    XCTAssertEqual(payload["token"] as? String, token.uuidString)
    XCTAssertEqual(payload["reason"] as? String, "ready")
  }

  func testPreviewReadyGateRequiresInitialCompositionToBeApplied() {
    XCTAssertFalse(
      InlinePreviewView.canEmitPreviewReady(
        hasEmittedReady: false,
        tokenMatches: true,
        itemReady: true,
        layerReady: true,
        initialCompositionApplied: false
      ))

    XCTAssertFalse(
      InlinePreviewView.canEmitPreviewReady(
        hasEmittedReady: false,
        tokenMatches: true,
        itemReady: false,
        layerReady: true,
        initialCompositionApplied: true
      ))

    XCTAssertTrue(
      InlinePreviewView.canEmitPreviewReady(
        hasEmittedReady: false,
        tokenMatches: true,
        itemReady: true,
        layerReady: true,
        initialCompositionApplied: true
      ))
  }
}

final class InlinePreviewRehydrationStateTests: XCTestCase {
  override func tearDown() {
    clearAllInlinePreviewState()
    inlinePreviewHostContainerInstance = nil
    inlinePreviewViewInstance = nil
    inlinePreviewPlayerEventSink = nil
    workflowLifecycleEventSink = nil
    super.tearDown()
  }

  func testRehydrateActivePreviewOpensNewHostAndQueuesLatestState() {
    let sessionId = "preview-session"
    let mediaSources = makeMediaSources(name: "rehydrate")
    let committedCameraParams = makeCameraParams(
      normalizedCanvasCenter: CGPoint(x: 0.24, y: 0.76)
    )
    let committedScene = PreviewScene(
      mediaSources: mediaSources,
      screenParams: makeParams(audioGainDb: 3.0, audioVolumePercent: 88.0),
      cameraParams: committedCameraParams
    )
    let previewCameraParams = makeCameraParams(
      normalizedCanvasCenter: CGPoint(x: 0.61, y: 0.38)
    )
    let zoomSegments = [
      ZoomTimelineSegment(startMs: 1200, endMs: 2400),
      ZoomTimelineSegment(startMs: 3600, endMs: 4300),
    ]
    let playbackSnapshot = PreviewPlaybackSnapshot(
      positionMs: 4200,
      isPlaying: false
    )

    beginActiveInlinePreviewSession(sessionId: sessionId, mediaSources: mediaSources)
    updateActiveInlinePreviewScene(sessionId: sessionId, scene: committedScene)
    updateActiveInlinePreviewZoomSegments(sessionId: sessionId, segments: zoomSegments)
    updateActiveInlinePreviewAudioMixOverride(
      sessionId: sessionId,
      gainDb: 7.0,
      volumePercent: 64.0
    )
    updateActiveInlinePreviewCameraPlacementOverride(
      sessionId: sessionId,
      cameraParams: previewCameraParams,
      changeKind: .dragPreview
    )
    updateActiveInlinePreviewPlaybackSnapshot(
      sessionId: sessionId,
      positionMs: playbackSnapshot.positionMs,
      isPlaying: playbackSnapshot.isPlaying
    )

    let view = InlinePreviewView(viewIdentifier: 1, arguments: nil, messenger: nil)
    XCTAssertTrue(rehydrateActivePreviewIfNeeded(on: view))

    XCTAssertEqual(view.currentSessionId, sessionId)
    XCTAssertEqual(view._testCurrentMediaSources(), mediaSources)
    XCTAssertEqual(view._testCurrentScene()?.screenParams, committedScene.screenParams)
    XCTAssertEqual(view._testCurrentScene()?.cameraParams, previewCameraParams)
    XCTAssertEqual(view._testCurrentCameraCompositionParams(), previewCameraParams)
    XCTAssertEqual(view._testPendingZoomSegments(), zoomSegments)
    XCTAssertEqual(view._testPendingPlaybackRestoreSnapshot(), playbackSnapshot)
    XCTAssertEqual(
      activeInlinePreviewState?.cameraPlacementOverride,
      PreviewCameraPlacementOverride(
        cameraParams: previewCameraParams,
        changeKind: .dragPreview
      )
    )
    XCTAssertEqual(
      activeInlinePreviewState?.audioMixOverride,
      PreviewAudioMixOverride(gainDb: 7.0, volumePercent: 64.0)
    )
  }

  func testCommittedSceneClearsSupersededPreviewOverrides() {
    let sessionId = "preview-session"
    let mediaSources = makeMediaSources(name: "committed")
    let cameraParams = makeCameraParams(
      normalizedCanvasCenter: CGPoint(x: 0.48, y: 0.42)
    )
    let scene = PreviewScene(
      mediaSources: mediaSources,
      screenParams: makeParams(audioGainDb: 6.0, audioVolumePercent: 72.0),
      cameraParams: cameraParams
    )

    beginActiveInlinePreviewSession(sessionId: sessionId, mediaSources: mediaSources)
    updateActiveInlinePreviewAudioMixOverride(
      sessionId: sessionId,
      gainDb: 6.0,
      volumePercent: 72.0
    )
    updateActiveInlinePreviewCameraPlacementOverride(
      sessionId: sessionId,
      cameraParams: cameraParams,
      changeKind: .placementJump
    )

    updateActiveInlinePreviewScene(sessionId: sessionId, scene: scene)

    XCTAssertEqual(activeInlinePreviewState?.latestScene, scene)
    XCTAssertNil(activeInlinePreviewState?.audioMixOverride)
    XCTAssertNil(activeInlinePreviewState?.cameraPlacementOverride)
  }

  func testClearAllInlinePreviewStateClearsPendingAndActivePreviewState() {
    let sessionId = "preview-session"
    let mediaSources = makeMediaSources(name: "clear")
    let scene = PreviewScene(
      mediaSources: mediaSources,
      screenParams: makeParams(),
      cameraParams: makeCameraParams()
    )

    beginActiveInlinePreviewSession(sessionId: sessionId, mediaSources: mediaSources)
    pendingPreviewOpenRequest = PendingPreviewOpenRequest(
      sessionId: sessionId,
      mediaSources: mediaSources
    )
    pendingPreviewSceneRequest = PendingPreviewSceneRequest(
      sessionId: sessionId,
      scene: scene
    )
    pendingPreviewZoomSegments = [ZoomTimelineSegment(startMs: 0, endMs: 1000)]

    clearAllInlinePreviewState()

    XCTAssertNil(activeInlinePreviewState)
    XCTAssertNil(pendingPreviewOpenRequest)
    XCTAssertNil(pendingPreviewSceneRequest)
    XCTAssertNil(pendingPreviewZoomSegments)
  }

  func testResetPlaybackWithDeinitReasonDoesNotClearActivePreviewState() {
    let sessionId = "preview-session"
    let mediaSources = makeMediaSources(name: "deinit")

    beginActiveInlinePreviewSession(sessionId: sessionId, mediaSources: mediaSources)

    let view = InlinePreviewView(viewIdentifier: 2, arguments: nil, messenger: nil)
    view.resetPlayback(reason: "deinit")

    XCTAssertEqual(activeInlinePreviewState?.sessionId, sessionId)
    XCTAssertEqual(activeInlinePreviewState?.mediaSources, mediaSources)
  }

  func testHostRemountAttachesExistingPreviewContentViewWithoutLifecycleEvents() {
    let sessionId = "preview-session"
    let mediaSources = makeMediaSources(name: "host-remount")
    let scene = PreviewScene(
      mediaSources: mediaSources,
      screenParams: makeParams(),
      cameraParams: makeCameraParams()
    )

    beginActiveInlinePreviewSession(sessionId: sessionId, mediaSources: mediaSources)
    updateActiveInlinePreviewScene(sessionId: sessionId, scene: scene)

    let previewView = InlinePreviewView(viewIdentifier: 10, arguments: nil, messenger: nil)
    XCTAssertTrue(rehydrateActivePreviewIfNeeded(on: previewView))
    inlinePreviewViewInstance = previewView

    var lifecycleEvents = [[String: Any]]()
    previewView.workflowEventSink = { event in
      if let payload = event as? [String: Any] {
        lifecycleEvents.append(payload)
      }
    }

    let firstHost = InlinePreviewHostContainerView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
    XCTAssertTrue(attachExistingInlinePreviewContentViewIfPossible(to: firstHost))
    XCTAssertTrue(firstHost.subviews.contains(where: { $0 === previewView }))

    let secondHost = InlinePreviewHostContainerView(frame: CGRect(x: 0, y: 0, width: 500, height: 320))
    XCTAssertTrue(attachExistingInlinePreviewContentViewIfPossible(to: secondHost))
    XCTAssertTrue(secondHost.subviews.contains(where: { $0 === previewView }))
    XCTAssertTrue(firstHost.subviews.isEmpty)
    XCTAssertTrue(inlinePreviewHostContainerInstance === secondHost)
    XCTAssertEqual(lifecycleEvents.count, 0)
  }

  func testDisposeInlinePreviewContentViewIfMatchingClearsPersistentInstance() {
    let sessionId = "preview-session"
    let mediaSources = makeMediaSources(name: "dispose")
    let scene = PreviewScene(
      mediaSources: mediaSources,
      screenParams: makeParams(),
      cameraParams: makeCameraParams()
    )

    beginActiveInlinePreviewSession(sessionId: sessionId, mediaSources: mediaSources)
    updateActiveInlinePreviewScene(sessionId: sessionId, scene: scene)

    let previewView = InlinePreviewView(viewIdentifier: 11, arguments: nil, messenger: nil)
    XCTAssertTrue(rehydrateActivePreviewIfNeeded(on: previewView))
    inlinePreviewViewInstance = previewView

    let host = InlinePreviewHostContainerView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
    XCTAssertTrue(attachExistingInlinePreviewContentViewIfPossible(to: host))

    XCTAssertTrue(
      disposeInlinePreviewContentViewIfMatching(
        sessionId: sessionId,
        reason: "flutterRequest"
      )
    )
    XCTAssertNil(inlinePreviewViewInstance)
    XCTAssertNil(inlinePreviewHostContainerInstance)
    XCTAssertNil(previewView.superview)
  }

  private func makeMediaSources(name: String) -> PreviewMediaSources {
    let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(
      "inline-preview-\(name)-\(UUID().uuidString).mov"
    )
    FileManager.default.createFile(atPath: path, contents: Data(), attributes: nil)
    return PreviewMediaSources(
      projectPath: path,
      screenPath: path,
      cameraPath: nil,
      metadataPath: nil,
      cursorPath: nil,
      zoomManualPath: nil
    )
  }

  private func makeParams(
    audioGainDb: Double = 0.0,
    audioVolumePercent: Double = 100.0
  ) -> CompositionParams {
    CompositionParams(
      targetSize: CGSize(width: 1920, height: 1080),
      padding: 0,
      cornerRadius: 12,
      backgroundColor: nil,
      backgroundImagePath: nil,
      cursorSize: 1.0,
      showCursor: true,
      zoomEnabled: true,
      zoomFactor: 2.0,
      followStrength: 0.5,
      fpsHint: 60,
      fitMode: "fit",
      audioGainDb: audioGainDb,
      audioVolumePercent: audioVolumePercent,
      zoomSegments: nil
    )
  }

  private func makeCameraParams(
    normalizedCanvasCenter: CGPoint? = CGPoint(x: 0.18, y: 0.82)
  ) -> CameraCompositionParams {
    CameraCompositionParams(
      visible: true,
      layoutPreset: .overlayBottomLeft,
      normalizedCanvasCenter: normalizedCanvasCenter,
      sizeFactor: 0.22,
      shape: .circle,
      cornerRadius: 0.0,
      opacity: 1.0,
      mirror: true,
      contentMode: .fill,
      zoomBehavior: .fixed,
      zoomScaleMultiplier: CameraCompositionParams.defaultZoomScaleMultiplier,
      introPreset: .none,
      outroPreset: .none,
      zoomEmphasisPreset: .none,
      introDurationMs: CameraCompositionParams.defaultIntroDurationMs,
      outroDurationMs: CameraCompositionParams.defaultOutroDurationMs,
      zoomEmphasisStrength: CameraCompositionParams.defaultZoomEmphasisStrength,
      borderWidth: 0.0,
      borderColorArgb: nil,
      shadowPreset: 0,
      chromaKeyEnabled: false,
      chromaKeyStrength: 0.4,
      chromaKeyColorArgb: nil
    )
  }
}
