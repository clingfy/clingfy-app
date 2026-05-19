import FlutterMacOS
import XCTest

@testable import Clingfy

/// PR 9 guard: the preview/scene/camera-composition resolution still resolves
/// and keeps its "project not found" contracts after being moved into the
/// PreviewSceneResolver extension. Deterministic / side-effect-free (unknown
/// project paths only).
@MainActor
final class PreviewSceneResolverTests: XCTestCase {
  private let missing = "/no/such/recording/project"

  func testResolvePreviewMediaSourcesNilForUnknownProject() {
    XCTAssertNil(ScreenRecorderFacade().resolvePreviewMediaSources(projectPath: missing))
  }

  func testResolveCameraCompositionParamsNilForUnknownProjectWithoutArgs() {
    XCTAssertNil(
      ScreenRecorderFacade().resolveCameraCompositionParams(projectPath: missing, args: nil))
  }

  func testResolvePreviewSceneNilForUnknownProject() {
    let params = CompositionParams(
      targetSize: .zero, padding: 0, cornerRadius: 0, backgroundColor: nil,
      backgroundImagePath: nil, cursorSize: 1, showCursor: true, zoomEnabled: false,
      zoomFactor: 1, followStrength: 0, fpsHint: 30, fitMode: "fit",
      audioGainDb: 0, audioVolumePercent: 100, zoomSegments: nil)
    let scene = ScreenRecorderFacade().resolvePreviewScene(
      projectPath: missing,
      screenParams: params
    )
    XCTAssertNil(scene)
  }

  func testGetRecordingSceneInfoReturnsSceneInputMissingError() {
    var captured: Any?
    ScreenRecorderFacade().getRecordingSceneInfo(projectPath: missing) { captured = $0 }
    let error = captured as? FlutterError
    XCTAssertEqual(error?.code, "SCENE_INPUT_MISSING")
    XCTAssertEqual(error?.details as? String, missing)
  }
}
