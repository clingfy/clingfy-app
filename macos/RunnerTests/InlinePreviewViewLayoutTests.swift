import Cocoa
import XCTest

@testable import Clingfy

final class InlinePreviewViewLayoutTests: XCTestCase {
  private let accuracy: CGFloat = 0.0001

  func testPreviewUpdatePlanKeepsZoomAndCursorChangesLightweight() {
    let oldParams = makeParams()
    let newParams = makeParams(
      cursorSize: 1.4,
      zoomFactor: 2.5,
      showCursor: false
    )
    let profile = makeProfile()

    let plan = InlinePreviewView.previewUpdatePlan(
      from: oldParams,
      to: newParams,
      oldProfile: profile,
      newProfile: profile
    )

    XCTAssertFalse(plan.requiresFullRebuild)
    XCTAssertFalse(plan.refreshCanvasGeometry)
    XCTAssertFalse(plan.refreshMask)
    XCTAssertFalse(plan.refreshBackground)
    XCTAssertFalse(plan.refreshAudioMix)
    XCTAssertTrue(plan.refreshOverlay)
  }

  func testPreviewUpdatePlanRefreshesMaskForCornerRadiusOnly() {
    let oldParams = makeParams(cornerRadius: 8)
    let newParams = makeParams(cornerRadius: 20)
    let profile = makeProfile()

    let plan = InlinePreviewView.previewUpdatePlan(
      from: oldParams,
      to: newParams,
      oldProfile: profile,
      newProfile: profile
    )

    XCTAssertFalse(plan.requiresFullRebuild)
    XCTAssertFalse(plan.refreshCanvasGeometry)
    XCTAssertTrue(plan.refreshMask)
    XCTAssertFalse(plan.refreshBackground)
    XCTAssertFalse(plan.refreshAudioMix)
    XCTAssertFalse(plan.refreshOverlay)
  }

  func testPreviewUpdatePlanRequiresFullRebuildForStructuralChanges() {
    let params = makeParams()
    let profile = makeProfile()
    let changedProfile = makeProfile(
      canvasRenderSize: CGSize(width: 960, height: 540),
      renderScale: 0.5
    )

    let scenarios: [(String, CompositionParams, PreviewProfile)] = [
      (
        "targetSize",
        makeParams(targetSize: CGSize(width: 1280, height: 720)),
        profile
      ),
      (
        "padding",
        makeParams(padding: 12),
        profile
      ),
      (
        "fitMode",
        makeParams(fitMode: "fill"),
        profile
      ),
      (
        "profile",
        params,
        changedProfile
      ),
    ]

    for (label, newParams, newProfile) in scenarios {
      let plan = InlinePreviewView.previewUpdatePlan(
        from: params,
        to: newParams,
        oldProfile: profile,
        newProfile: newProfile
      )

      XCTAssertTrue(plan.requiresFullRebuild, label)
      XCTAssertTrue(plan.refreshCanvasGeometry, label)
    }
  }

  func testApplyCanvasGeometryPreservesZoomTransformAndUsesBoundsPosition() {
    let container = CALayer()
    container.anchorPoint = CGPoint(x: 0.5, y: 0.5)

    let background = CALayer()
    background.anchorPoint = .zero
    background.bounds = CGRect(x: 0, y: 0, width: 40, height: 40)
    background.position = CGPoint(x: 10, y: 12)

    let zoomed = CALayer()
    zoomed.anchorPoint = .zero
    zoomed.bounds = CGRect(x: 0, y: 0, width: 60, height: 60)
    zoomed.position = CGPoint(x: 18, y: 24)

    let originalTransform = CGAffineTransform.identity
      .translatedBy(x: 24, y: 18)
      .scaledBy(x: 2.25, y: 2.25)
    zoomed.setAffineTransform(originalTransform)

    let metrics = try XCTUnwrap(
      InlinePreviewView.canvasLayoutMetrics(
        viewSize: CGSize(width: 900, height: 600),
        backingScale: 2.0,
        targetSize: CGSize(width: 300, height: 200)
      )
    )

    InlinePreviewView.applyCanvasGeometry(
      container: container,
      backgroundLayer: background,
      zoomedLayer: zoomed,
      metrics: metrics
    )

    XCTAssertEqual(container.bounds, CGRect(origin: .zero, size: metrics.targetSize))
    XCTAssertEqual(container.position.x, 450, accuracy: accuracy)
    XCTAssertEqual(container.position.y, 300, accuracy: accuracy)
    XCTAssertEqual(container.affineTransform().a, 3.0, accuracy: accuracy)
    XCTAssertEqual(container.affineTransform().d, 3.0, accuracy: accuracy)

    XCTAssertEqual(background.bounds, CGRect(origin: .zero, size: metrics.targetSize))
    XCTAssertEqual(background.position.x, 0, accuracy: accuracy)
    XCTAssertEqual(background.position.y, 0, accuracy: accuracy)

    XCTAssertEqual(zoomed.bounds, CGRect(origin: .zero, size: metrics.targetSize))
    XCTAssertEqual(zoomed.position.x, 0, accuracy: accuracy)
    XCTAssertEqual(zoomed.position.y, 0, accuracy: accuracy)

    let restoredTransform = zoomed.affineTransform()
    XCTAssertEqual(restoredTransform.a, originalTransform.a, accuracy: accuracy)
    XCTAssertEqual(restoredTransform.b, originalTransform.b, accuracy: accuracy)
    XCTAssertEqual(restoredTransform.c, originalTransform.c, accuracy: accuracy)
    XCTAssertEqual(restoredTransform.d, originalTransform.d, accuracy: accuracy)
    XCTAssertEqual(restoredTransform.tx, originalTransform.tx, accuracy: accuracy)
    XCTAssertEqual(restoredTransform.ty, originalTransform.ty, accuracy: accuracy)
  }

  func testCameraPreviewPlacementAnimatorInterpolatesStartMidAndEnd() throws {
    let from = CameraPreviewPresentation(
      frame: CGRect(x: 40, y: 60, width: 160, height: 120),
      opacity: 0.4
    )
    let to = CameraPreviewPresentation(
      frame: CGRect(x: 240, y: 180, width: 220, height: 160),
      opacity: 0.9
    )
    let transition = try XCTUnwrap(
      CameraPreviewPlacementAnimator.makeTransition(
        mode: .placementJump,
        from: from,
        to: to,
        startMediaTime: 10.0,
        duration: 0.20
      )
    )

    let start = CameraPreviewPlacementAnimator.resolvedPresentation(
      target: to,
      transition: transition,
      now: 10.0
    )
    let midpoint = CameraPreviewPlacementAnimator.resolvedPresentation(
      target: to,
      transition: transition,
      now: 10.10
    )
    let end = CameraPreviewPlacementAnimator.resolvedPresentation(
      target: to,
      transition: transition,
      now: 10.20
    )

    XCTAssertEqual(start.presentation.frame.origin.x, from.frame.origin.x, accuracy: accuracy)
    XCTAssertEqual(start.presentation.frame.origin.y, from.frame.origin.y, accuracy: accuracy)
    XCTAssertEqual(start.presentation.opacity, from.opacity, accuracy: 0.0001)

    XCTAssertEqual(midpoint.presentation.frame.origin.x, 140, accuracy: accuracy)
    XCTAssertEqual(midpoint.presentation.frame.origin.y, 120, accuracy: accuracy)
    XCTAssertEqual(midpoint.presentation.frame.size.width, 190, accuracy: accuracy)
    XCTAssertEqual(midpoint.presentation.frame.size.height, 140, accuracy: accuracy)
    XCTAssertEqual(midpoint.presentation.opacity, 0.65, accuracy: 0.0001)
    XCTAssertFalse(midpoint.isComplete)

    XCTAssertEqual(end.presentation.frame.origin.x, to.frame.origin.x, accuracy: accuracy)
    XCTAssertEqual(end.presentation.frame.origin.y, to.frame.origin.y, accuracy: accuracy)
    XCTAssertEqual(end.presentation.frame.size.width, to.frame.size.width, accuracy: accuracy)
    XCTAssertEqual(end.presentation.frame.size.height, to.frame.size.height, accuracy: accuracy)
    XCTAssertEqual(end.presentation.opacity, to.opacity, accuracy: 0.0001)
    XCTAssertTrue(end.isComplete)
  }

  func testCameraPreviewPlacementAnimatorRetargetsFromCurrentInterpolatedPresentation() throws {
    let first = try XCTUnwrap(
      CameraPreviewPlacementAnimator.makeTransition(
        mode: .placementJump,
        from: CameraPreviewPresentation(
          frame: CGRect(x: 20, y: 30, width: 100, height: 80),
          opacity: 0.5
        ),
        to: CameraPreviewPresentation(
          frame: CGRect(x: 220, y: 160, width: 180, height: 140),
          opacity: 1.0
        ),
        startMediaTime: 5.0,
        duration: 0.20
      )
    )
    let current = CameraPreviewPlacementAnimator.currentPresentation(
      for: first,
      now: 5.10
    )
    let retarget = try XCTUnwrap(
      CameraPreviewPlacementAnimator.makeTransition(
        mode: .placementJump,
        from: current,
        to: CameraPreviewPresentation(
          frame: CGRect(x: 360, y: 220, width: 200, height: 150),
          opacity: 0.7
        ),
        startMediaTime: 5.10,
        duration: 0.20
      )
    )

    XCTAssertEqual(retarget.from.frame.origin.x, current.frame.origin.x, accuracy: accuracy)
    XCTAssertEqual(retarget.from.frame.origin.y, current.frame.origin.y, accuracy: accuracy)
    XCTAssertEqual(retarget.from.frame.size.width, current.frame.size.width, accuracy: accuracy)
    XCTAssertEqual(retarget.from.frame.size.height, current.frame.size.height, accuracy: accuracy)
    XCTAssertEqual(retarget.from.opacity, current.opacity, accuracy: 0.0001)
  }

  func testCameraPreviewPlacementAnimatorReduceMotionResolvesImmediately() {
    XCTAssertEqual(
      CameraPreviewPlacementAnimator.resolvedDuration(
        for: .placementJump,
        reduceMotionEnabled: true
      ),
      0
    )
    XCTAssertNil(
      CameraPreviewPlacementAnimator.makeTransition(
        mode: .placementJump,
        from: CameraPreviewPresentation(
          frame: CGRect(x: 0, y: 0, width: 80, height: 60),
          opacity: 1.0
        ),
        to: CameraPreviewPresentation(
          frame: CGRect(x: 200, y: 120, width: 120, height: 90),
          opacity: 0.6
        ),
        startMediaTime: 0,
        duration: CameraPreviewPlacementAnimator.resolvedDuration(
          for: .placementJump,
          reduceMotionEnabled: true
        )
      )
    )
  }

  func testCameraPreviewPlacementAnimatorUsesShorterDurationForDragPreview() {
    XCTAssertEqual(
      CameraPreviewPlacementAnimator.resolvedDuration(
        for: .placementJump,
        reduceMotionEnabled: false
      ),
      0.20
    )
    XCTAssertEqual(
      CameraPreviewPlacementAnimator.resolvedDuration(
        for: .dragPreview,
        reduceMotionEnabled: false
      ),
      0.08
    )
  }

  func testCameraPlacementPreviewUpdateKeepsCompositionAndRetargetsTransition() throws {
    let view = InlinePreviewView(
      viewIdentifier: 1,
      arguments: nil,
      messenger: nil
    )
    let initialCameraParams = makeCameraParams(
      normalizedCanvasCenter: CGPoint(x: 0.22, y: 0.74)
    )
    let initialScene = PreviewScene(
      mediaSources: PreviewMediaSources(
        projectPath: "/tmp/project.clingfyproj",
        screenPath: "/tmp/screen.mov",
        cameraPath: "/tmp/camera.mov",
        metadataPath: nil,
        cursorPath: nil,
        zoomManualPath: nil
      ),
      screenParams: makeParams(),
      cameraParams: initialCameraParams
    )

    view._testSeedCameraPlacementPreviewState(scene: initialScene)

    let originalCompositionParams = try XCTUnwrap(
      view._testCurrentCompositionParams()
    )
    var previewCameraParams = initialCameraParams
    previewCameraParams.normalizedCanvasCenter = CGPoint(x: 0.58, y: 0.36)

    view.updateCameraPlacementPreview(
      cameraParams: previewCameraParams,
      changeKind: .dragPreview
    )

    XCTAssertEqual(
      view._testCurrentCompositionParams(),
      originalCompositionParams
    )
    XCTAssertEqual(
      view._testCurrentScene()?.screenParams,
      initialScene.screenParams
    )
    XCTAssertEqual(
      view._testCurrentScene()?.cameraParams,
      previewCameraParams
    )
    XCTAssertEqual(
      view._testCurrentCameraCompositionParams(),
      previewCameraParams
    )
    XCTAssertEqual(
      view._testCurrentCameraPreviewTransitionMode(),
      .dragPreview
    )

    view.updateCameraPlacementPreview(
      cameraParams: previewCameraParams,
      changeKind: .placementJump
    )

    XCTAssertEqual(
      view._testCurrentCompositionParams(),
      originalCompositionParams
    )
    XCTAssertEqual(
      view._testCurrentCameraPreviewTransitionMode(),
      .placementJump
    )
  }

  func testClampedManualNormalizedCenterUsesZoomedFrameBounds() throws {
    let view = InlinePreviewView(
      viewIdentifier: 1,
      arguments: nil,
      messenger: nil
    )
    let canvasSize = CGSize(width: 1920, height: 1080)
    var params = makeCameraParams(normalizedCanvasCenter: nil)
    params.zoomBehavior = .scaleWithScreenZoom
    params.zoomScaleMultiplier = 1.0
    params.shadowPreset = 3

    let center = try XCTUnwrap(
      view._testClampedManualNormalizedCenter(
        desiredCenter: CGPoint(x: canvasSize.width, y: canvasSize.height),
        canvasSize: canvasSize,
        cameraParams: params,
        time: 0.0,
        totalDuration: 10.0,
        screenZoom: 1.8
      )
    )

    let baseSize = min(canvasSize.width, canvasSize.height) * CGFloat(params.sizeFactor)
    let scaledSize = baseSize * 1.8
    let expectedX = (canvasSize.width - 28.0 - (scaledSize / 2.0)) / canvasSize.width
    let expectedY = (canvasSize.height - 28.0 - (scaledSize / 2.0)) / canvasSize.height

    XCTAssertEqual(center.x, expectedX, accuracy: 0.001)
    XCTAssertEqual(center.y, expectedY, accuracy: 0.001)
    XCTAssertLessThan(center.x, 1.0)
    XCTAssertLessThan(center.y, 1.0)
  }

  private func makeParams(
    targetSize: CGSize = CGSize(width: 1920, height: 1080),
    padding: Double = 0,
    cornerRadius: Double = 12,
    backgroundColor: Int? = nil,
    backgroundImagePath: String? = nil,
    cursorSize: Double = 1.0,
    showCursor: Bool = true,
    zoomEnabled: Bool = true,
    zoomFactor: CGFloat = 2.0,
    followStrength: CGFloat = 0.5,
    fpsHint: Int32 = 60,
    fitMode: String? = "fit",
    audioGainDb: Double = 0,
    audioVolumePercent: Double = 100,
    zoomSegments: [ZoomTimelineSegment]? = nil
  ) -> CompositionParams {
    var params = CompositionParams(
      targetSize: targetSize,
      padding: padding,
      cornerRadius: cornerRadius,
      backgroundColor: backgroundColor,
      backgroundImagePath: backgroundImagePath,
      cursorSize: cursorSize,
      showCursor: showCursor,
      zoomEnabled: zoomEnabled,
      zoomFactor: zoomFactor,
      followStrength: followStrength,
      fpsHint: fpsHint,
      fitMode: fitMode,
      audioGainDb: audioGainDb,
      audioVolumePercent: audioVolumePercent
    )
    params.zoomSegments = zoomSegments
    return params
  }

  private func makeProfile(
    canvasRenderSize: CGSize = CGSize(width: 1280, height: 720),
    renderScale: CGFloat = 0.6667,
    fps: Int32 = 30,
    maxLongEdge: CGFloat = PreviewProfile.defaultMaxLongEdge
  ) -> PreviewProfile {
    PreviewProfile(
      canvasRenderSize: canvasRenderSize,
      renderScale: renderScale,
      fps: fps,
      maxLongEdge: maxLongEdge
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
      borderWidth: 0.0,
      borderColorArgb: nil,
      shadowPreset: 0,
      chromaKeyEnabled: false,
      chromaKeyStrength: 0.4,
      chromaKeyColorArgb: nil
    )
  }
}
