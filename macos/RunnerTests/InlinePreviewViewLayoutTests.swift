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
}
