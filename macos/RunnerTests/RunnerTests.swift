import AVFoundation
import Cocoa
import FlutterMacOS
import XCTest

@testable import Clingfy

final class AppPathsTests: XCTestCase {
  func testCameraArtifactsUseScreenRecordingStem() {
    let rawURL = URL(fileURLWithPath: "/tmp/recording.mov")

    XCTAssertEqual(AppPaths.cameraRawURL(for: rawURL).lastPathComponent, "recording.camera.mov")
    XCTAssertEqual(
      AppPaths.cameraMetadataSidecarURL(for: rawURL).lastPathComponent,
      "recording.camera.meta.json"
    )
    XCTAssertEqual(
      AppPaths.cameraSegmentDirectoryURL(for: rawURL).lastPathComponent,
      "recording.camera.segments"
    )

    let artifactNames = AppPaths.allRecordingArtifactURLs(for: rawURL).map(\.lastPathComponent)
    XCTAssertEqual(
      artifactNames,
      [
        "recording.mov",
        "recording.cursor.json",
        "recording.meta.json",
        "recording.zoom.manual.json",
        "recording.camera.mov",
        "recording.camera.meta.json",
        "recording.camera.segments",
      ]
    )
  }
}

final class RecordingMetadataTests: XCTestCase {
  func testVersion2RoundTripPreservesCameraAndEditorSeed() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let rawURL = tempDir.appendingPathComponent("recording.mov")
    let metadataURL = AppPaths.metadataSidecarURL(for: rawURL)
    let cameraInfo = RecordingMetadata.CameraCaptureInfo(
      mode: .separateCameraAsset,
      enabled: true,
      rawRelativePath: "recording.camera.mov",
      metadataRelativePath: "recording.camera.meta.json",
      deviceId: "camera-1",
      mirroredRaw: true,
      nominalFrameRate: 30,
      dimensions: .init(width: 1920, height: 1080),
      segments: [
        .init(
          index: 0,
          relativePath: "recording.camera.segments/segment_000.mov",
          startWallClock: RecordingMetadata.iso8601String(from: Date(timeIntervalSince1970: 0)),
          endWallClock: RecordingMetadata.iso8601String(from: Date(timeIntervalSince1970: 5))
        )
      ]
    )
    let editorSeed = RecordingMetadata.EditorSeed(
      cameraVisible: true,
      cameraLayoutPreset: .overlayTopLeft,
      cameraNormalizedCenter: .init(x: 0.4, y: 0.6),
      cameraSizeFactor: 0.22,
      cameraShape: .roundedRect,
      cameraCornerRadius: 0.25,
      cameraBorderWidth: 3.0,
      cameraBorderColorArgb: 0xFFFFFFFF,
      cameraShadow: 1,
      cameraOpacity: 0.8,
      cameraMirror: false,
      cameraContentMode: .fit,
      cameraZoomBehavior: .scaleWithScreenZoom,
      cameraZoomScaleMultiplier: 0.55,
      cameraChromaKeyEnabled: true,
      cameraChromaKeyStrength: 0.5,
      cameraChromaKeyColorArgb: 0xFF00FF00
    )
    let metadata = RecordingMetadata.create(
      rawURL: rawURL,
      displayMode: .explicitID,
      displayID: 123,
      cropRect: CGRect(x: 10, y: 20, width: 300, height: 200),
      frameRate: 60,
      quality: .fhd,
      cursorEnabled: true,
      cursorLinked: true,
      windowID: 77,
      excludedRecorderApp: true,
      camera: cameraInfo,
      editorSeed: editorSeed
    )

    try metadata.write(to: metadataURL)
    let decoded = try RecordingMetadata.read(from: metadataURL)

    XCTAssertEqual(decoded.version, 2)
    XCTAssertEqual(decoded.screen.rawRelativePath, "recording.mov")
    XCTAssertEqual(decoded.screen.windowId, 77)
    XCTAssertEqual(decoded.camera, cameraInfo)
    XCTAssertEqual(decoded.editorSeed, editorSeed)
  }

  func testLegacyV2EditorSeedDefaultsMissingCameraZoomAndAnimationFields() throws {
    let metadata = RecordingMetadata.create(
      rawURL: URL(fileURLWithPath: "/tmp/recording.mov"),
      displayMode: .explicitID,
      displayID: 123,
      cropRect: nil,
      frameRate: 60,
      quality: .fhd,
      cursorEnabled: true,
      cursorLinked: true,
      windowID: nil,
      excludedRecorderApp: false,
      camera: nil,
      editorSeed: RecordingMetadata.EditorSeed(
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
        cameraZoomBehavior: .fixed,
        cameraZoomScaleMultiplier: 0.35,
        cameraChromaKeyEnabled: false,
        cameraChromaKeyStrength: 0.4,
        cameraChromaKeyColorArgb: nil
      )
    )

    let encoded = try JSONEncoder().encode(metadata)
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    var editorSeed = try XCTUnwrap(json["editorSeed"] as? [String: Any])
    editorSeed.removeValue(forKey: "cameraZoomBehavior")
    editorSeed.removeValue(forKey: "cameraZoomScaleMultiplier")
    json["editorSeed"] = editorSeed

    let legacyData = try JSONSerialization.data(withJSONObject: json)
    let decoded = try JSONDecoder().decode(RecordingMetadata.self, from: legacyData)

    XCTAssertEqual(decoded.editorSeed.cameraZoomBehavior, .fixed)
    XCTAssertEqual(decoded.editorSeed.cameraZoomScaleMultiplier, 0.35, accuracy: 0.0001)
    XCTAssertEqual(decoded.editorSeed.cameraIntroPreset, .none)
    XCTAssertEqual(decoded.editorSeed.cameraOutroPreset, .none)
    XCTAssertEqual(decoded.editorSeed.cameraZoomEmphasisPreset, .none)
    XCTAssertEqual(
      decoded.editorSeed.cameraIntroDurationMs,
      CameraCompositionParams.defaultIntroDurationMs
    )
    XCTAssertEqual(
      decoded.editorSeed.cameraOutroDurationMs,
      CameraCompositionParams.defaultOutroDurationMs
    )
    XCTAssertEqual(
      decoded.editorSeed.cameraZoomEmphasisStrength,
      CameraCompositionParams.defaultZoomEmphasisStrength,
      accuracy: 0.0001
    )
  }

  func testLegacyMetadataReadMigratesToVersion2Schema() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let metadataURL = tempDir.appendingPathComponent("recording.meta.json")
    let legacyJSON = """
      {
        "schemaVersion": 1,
        "appVersion": "1.0.0",
        "bundleId": "com.clingfy.app",
        "startedAt": "2025-01-01T00:00:00.000Z",
        "endedAt": "2025-01-01T00:00:05.000Z",
        "displayMode": 0,
        "displayID": 123,
        "cropRect": {
          "x": 10,
          "y": 20,
          "width": 300,
          "height": 200
        },
        "frameRate": 60,
        "quality": "fhd",
        "cursorEnabled": true,
        "cursorLinked": true,
        "overlayEnabled": true,
        "windowID": 42,
        "excludedRecorderApp": true
      }
      """
    let data = try XCTUnwrap(legacyJSON.data(using: .utf8))
    try data.write(to: metadataURL)

    let decoded = try RecordingMetadata.read(from: metadataURL)

    XCTAssertEqual(decoded.version, 2)
    XCTAssertNil(decoded.camera)
    XCTAssertEqual(decoded.screen.rawRelativePath, "recording.mov")
    XCTAssertEqual(decoded.screen.windowId, 42)
    XCTAssertEqual(decoded.editorSeed.cameraVisible, true)
    XCTAssertEqual(decoded.editorSeed.cameraLayoutPreset, .overlayBottomRight)
  }

  private func makeTemporaryDirectory() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: nil
    )
    return url
  }
}

final class CameraRecorderTests: XCTestCase {
  func testRecordingStoppedErrorWithSuccessKeyIsTreatedAsSuccessfulFinish() {
    let error = NSError(
      domain: AVFoundationErrorDomain,
      code: AVError.unknown.rawValue,
      userInfo: [
        NSLocalizedDescriptionKey: "Recording Stopped",
        AVErrorRecordingSuccessfullyFinishedKey: true,
      ]
    )

    XCTAssertTrue(CameraRecorder._testRecordingFinishedSuccessfully(error))
  }

  func testRecordingStoppedErrorWithoutSuccessKeyIsTreatedAsFailure() {
    let error = NSError(
      domain: AVFoundationErrorDomain,
      code: AVError.unknown.rawValue,
      userInfo: [
        NSLocalizedDescriptionKey: "Recording Stopped"
      ]
    )

    XCTAssertFalse(CameraRecorder._testRecordingFinishedSuccessfully(error))
  }
}

final class CameraLayoutResolverTests: XCTestCase {
  func testManualFrameClampsIntoCanvasBounds() {
    let params = CameraCompositionParams(
      visible: true,
      layoutPreset: .overlayBottomRight,
      normalizedCanvasCenter: CGPoint(x: 1.2, y: -0.2),
      sizeFactor: 0.3,
      shape: .circle,
      cornerRadius: 0,
      opacity: 1,
      mirror: true,
      contentMode: .fill,
      zoomBehavior: .fixed,
      borderWidth: 0,
      borderColorArgb: nil,
      shadowPreset: 0,
      chromaKeyEnabled: false,
      chromaKeyStrength: 0.4,
      chromaKeyColorArgb: nil
    )

    let resolution = CameraLayoutResolver.effectiveFrame(
      canvasSize: CGSize(width: 1000, height: 600),
      params: params
    )

    XCTAssertTrue(resolution.shouldRender)
    XCTAssertEqual(resolution.zOrder, .aboveScreen)
    XCTAssertEqual(resolution.frame.maxX, 1000, accuracy: 0.001)
    XCTAssertEqual(resolution.frame.minY, 0, accuracy: 0.001)
  }

  func testBackgroundBehindUsesFullCanvasAndHiddenDoesNotRender() {
    var params = CameraCompositionParams.hidden
    params.visible = true
    params.layoutPreset = .backgroundBehind

    let background = CameraLayoutResolver.resolve(
      canvasSize: CGSize(width: 1280, height: 720),
      params: params
    )

    XCTAssertTrue(background.shouldRender)
    XCTAssertEqual(background.zOrder, .behindScreen)
    XCTAssertEqual(background.frame, CGRect(x: 0, y: 0, width: 1280, height: 720))

    let hidden = CameraLayoutResolver.resolve(
      canvasSize: CGSize(width: 1280, height: 720),
      params: .hidden
    )
    XCTAssertFalse(hidden.shouldRender)
    XCTAssertEqual(hidden.frame, .zero)
  }

  func testMaskPathMatchesRequestedShape() {
    let rect = CGRect(x: 0, y: 0, width: 200, height: 120)
    var params = CameraCompositionParams.hidden
    params.visible = true
    params.layoutPreset = .overlayBottomRight
    params.shape = .roundedRect
    params.cornerRadius = 0.25

    let roundedRect = CameraLayoutResolver.maskPath(in: rect, params: params)
    XCTAssertEqual(roundedRect.boundingBox, rect)

    params.shape = .circle
    let circle = CameraLayoutResolver.maskPath(in: rect, params: params)
    XCTAssertEqual(circle.boundingBox, rect)
  }
}

final class CameraTransformTimelineBuilderTests: XCTestCase {
  func testFixedModeKeepsBaseFrameDuringZoom() {
    let params = makeParams(behavior: .fixed, multiplier: 0.35)
    let base = CameraLayoutResolver.effectiveFrame(
      canvasSize: CGSize(width: 1000, height: 600),
      params: params
    )

    let resolved = CameraTransformTimelineBuilder.resolve(
      baseResolution: base,
      cameraParams: params,
      screenZoom: 1.8
    )

    XCTAssertEqual(resolved.scale, 1.0, accuracy: 0.0001)
    XCTAssertEqual(resolved.frame, base.frame)
  }

  func testScaleWithScreenZoomUsesMultiplierAndPreservesCenter() {
    let params = makeParams(behavior: .scaleWithScreenZoom, multiplier: 0.35)
    let base = CameraLayoutResolver.effectiveFrame(
      canvasSize: CGSize(width: 1000, height: 600),
      params: params
    )

    let resolved = CameraTransformTimelineBuilder.resolve(
      baseResolution: base,
      cameraParams: params,
      screenZoom: 1.8
    )

    XCTAssertEqual(resolved.scale, 1.28, accuracy: 0.0001)
    XCTAssertEqual(resolved.frame.midX, base.frame.midX, accuracy: 0.0001)
    XCTAssertEqual(resolved.frame.midY, base.frame.midY, accuracy: 0.0001)
    XCTAssertEqual(resolved.frame.width, base.frame.width * 1.28, accuracy: 0.0001)
    XCTAssertEqual(resolved.frame.height, base.frame.height * 1.28, accuracy: 0.0001)
  }

  func testZeroMultiplierBehavesLikeFixed() {
    let params = makeParams(behavior: .scaleWithScreenZoom, multiplier: 0.0)
    let base = CameraLayoutResolver.effectiveFrame(
      canvasSize: CGSize(width: 1000, height: 600),
      params: params
    )

    let resolved = CameraTransformTimelineBuilder.resolve(
      baseResolution: base,
      cameraParams: params,
      screenZoom: 2.0
    )

    XCTAssertEqual(resolved.scale, 1.0, accuracy: 0.0001)
    XCTAssertEqual(resolved.frame, base.frame)
  }

  func testFullMultiplierFollowsScreenZoom() {
    let params = makeParams(behavior: .scaleWithScreenZoom, multiplier: 1.0)
    let scale = CameraTransformTimelineBuilder.resolvedScale(
      layoutPreset: params.layoutPreset,
      behavior: params.zoomBehavior,
      multiplier: params.zoomScaleMultiplier,
      screenZoom: 1.8
    )

    XCTAssertEqual(scale, 1.8, accuracy: 0.0001)
  }

  func testBackgroundBehindIgnoresZoomScaling() {
    var params = makeParams(behavior: .scaleWithScreenZoom, multiplier: 1.0)
    params.layoutPreset = .backgroundBehind
    let base = CameraLayoutResolver.effectiveFrame(
      canvasSize: CGSize(width: 1000, height: 600),
      params: params
    )

    let resolved = CameraTransformTimelineBuilder.resolve(
      baseResolution: base,
      cameraParams: params,
      screenZoom: 2.0
    )

    XCTAssertEqual(resolved.scale, 1.0, accuracy: 0.0001)
    XCTAssertEqual(resolved.frame, base.frame)
  }

  func testManualPositionPreservesCenterWhileScaling() {
    var params = makeParams(behavior: .scaleWithScreenZoom, multiplier: 0.5)
    params.normalizedCanvasCenter = CGPoint(x: 0.2, y: 0.8)
    let base = CameraLayoutResolver.effectiveFrame(
      canvasSize: CGSize(width: 1000, height: 600),
      params: params
    )

    let resolved = CameraTransformTimelineBuilder.resolve(
      baseResolution: base,
      cameraParams: params,
      screenZoom: 1.6
    )

    XCTAssertEqual(resolved.frame.midX, base.frame.midX, accuracy: 0.0001)
    XCTAssertEqual(resolved.frame.midY, base.frame.midY, accuracy: 0.0001)
  }

  private func makeParams(
    behavior: CameraZoomBehavior,
    multiplier: Double
  ) -> CameraCompositionParams {
    CameraCompositionParams(
      visible: true,
      layoutPreset: .overlayBottomRight,
      normalizedCanvasCenter: nil,
      sizeFactor: 0.2,
      shape: .circle,
      cornerRadius: 0.0,
      opacity: 1.0,
      mirror: true,
      contentMode: .fill,
      zoomBehavior: behavior,
      zoomScaleMultiplier: multiplier,
      borderWidth: 0.0,
      borderColorArgb: nil,
      shadowPreset: 0,
      chromaKeyEnabled: false,
      chromaKeyStrength: 0.4,
      chromaKeyColorArgb: nil
    )
  }
}

final class CameraAnimationTimelineBuilderTests: XCTestCase {
  func testNoneKeepsFrameAndOpacityUnchanged() {
    let params = makeParams()
    let canvasSize = CGSize(width: 1000, height: 600)
    let base = CameraLayoutResolver.effectiveFrame(canvasSize: canvasSize, params: params)
    let transformed = CameraTransformTimelineBuilder.resolve(
      baseResolution: base,
      cameraParams: params,
      screenZoom: 1.0
    )

    let resolved = CameraAnimationTimelineBuilder.resolve(
      canvasSize: canvasSize,
      baseResolution: base,
      transformedResolution: transformed,
      cameraParams: params,
      time: 0.5,
      totalDuration: 2.0
    )

    XCTAssertEqual(resolved.frame, transformed.frame)
    XCTAssertEqual(resolved.opacity, 1.0, accuracy: 0.0001)
    XCTAssertFalse(resolved.shouldBypass)
  }

  func testPopScalesAroundCenter() {
    var params = makeParams()
    params.introPreset = .pop
    let canvasSize = CGSize(width: 1000, height: 600)
    let base = CameraLayoutResolver.effectiveFrame(canvasSize: canvasSize, params: params)
    let transformed = CameraTransformTimelineBuilder.resolve(
      baseResolution: base,
      cameraParams: params,
      screenZoom: 1.0
    )

    let resolved = CameraAnimationTimelineBuilder.resolve(
      canvasSize: canvasSize,
      baseResolution: base,
      transformedResolution: transformed,
      cameraParams: params,
      time: 0.0,
      totalDuration: 2.0
    )

    XCTAssertEqual(resolved.frame.midX, transformed.frame.midX, accuracy: 0.0001)
    XCTAssertEqual(resolved.frame.midY, transformed.frame.midY, accuracy: 0.0001)
    XCTAssertLessThan(resolved.frame.width, transformed.frame.width)
    XCTAssertEqual(resolved.opacity, 0.0, accuracy: 0.0001)
  }

  func testSlideUsesLayoutEdgeForTopRight() {
    var params = makeParams()
    params.layoutPreset = .overlayTopRight
    params.introPreset = .slide
    let canvasSize = CGSize(width: 1000, height: 600)
    let base = CameraLayoutResolver.effectiveFrame(canvasSize: canvasSize, params: params)
    let transformed = CameraTransformTimelineBuilder.resolve(
      baseResolution: base,
      cameraParams: params,
      screenZoom: 1.0
    )

    let resolved = CameraAnimationTimelineBuilder.resolve(
      canvasSize: canvasSize,
      baseResolution: base,
      transformedResolution: transformed,
      cameraParams: params,
      time: 0.0,
      totalDuration: 2.0
    )

    XCTAssertGreaterThan(resolved.frame.minX, canvasSize.width)
    XCTAssertEqual(resolved.opacity, 0.0, accuracy: 0.0001)
  }

  func testPulseOnlyAppliesDuringActiveZoom() {
    var params = makeParams()
    params.zoomEmphasisPreset = .pulse
    params.zoomEmphasisStrength = 0.10
    let canvasSize = CGSize(width: 1000, height: 600)
    let base = CameraLayoutResolver.effectiveFrame(canvasSize: canvasSize, params: params)
    let transformed = CameraTransformTimelineBuilder.resolve(
      baseResolution: base,
      cameraParams: params,
      screenZoom: 1.0
    )

    let inactive = CameraAnimationTimelineBuilder.resolve(
      canvasSize: canvasSize,
      baseResolution: base,
      transformedResolution: transformed,
      cameraParams: params,
      time: 0.5,
      totalDuration: 2.0,
      zoomState: .inactive
    )
    let active = CameraAnimationTimelineBuilder.resolve(
      canvasSize: canvasSize,
      baseResolution: base,
      transformedResolution: transformed,
      cameraParams: params,
      time: 0.5,
      totalDuration: 2.0,
      zoomState: CameraAnimationZoomState(isActive: true, localTime: 0.125)
    )

    XCTAssertEqual(inactive.frame, transformed.frame)
    XCTAssertEqual(active.frame.width, transformed.frame.width * 1.05, accuracy: 0.0001)
    XCTAssertEqual(active.frame.midX, transformed.frame.midX, accuracy: 0.0001)
    XCTAssertEqual(active.frame.midY, transformed.frame.midY, accuracy: 0.0001)
  }

  func testBackgroundBehindBypassesPresentationEffects() {
    var params = makeParams()
    params.layoutPreset = .backgroundBehind
    params.introPreset = .slide
    params.outroPreset = .fade
    params.zoomEmphasisPreset = .pulse
    let canvasSize = CGSize(width: 1000, height: 600)
    let base = CameraLayoutResolver.effectiveFrame(canvasSize: canvasSize, params: params)
    let transformed = CameraTransformTimelineBuilder.resolve(
      baseResolution: base,
      cameraParams: params,
      screenZoom: 2.0
    )

    let resolved = CameraAnimationTimelineBuilder.resolve(
      canvasSize: canvasSize,
      baseResolution: base,
      transformedResolution: transformed,
      cameraParams: params,
      time: 0.25,
      totalDuration: 2.0,
      zoomState: CameraAnimationZoomState(isActive: true, localTime: 0.125)
    )

    XCTAssertTrue(resolved.shouldBypass)
    XCTAssertEqual(resolved.frame, transformed.frame)
    XCTAssertEqual(resolved.opacity, params.opacity, accuracy: 0.0001)
  }

  func testResolvePresentationComposesZoomAndAnimationBuilders() {
    var params = makeParams()
    params.zoomBehavior = .scaleWithScreenZoom
    params.zoomScaleMultiplier = 0.35
    params.introPreset = .pop
    params.zoomEmphasisPreset = .pulse
    params.zoomEmphasisStrength = 0.10
    let canvasSize = CGSize(width: 1000, height: 600)
    let base = CameraLayoutResolver.effectiveFrame(canvasSize: canvasSize, params: params)

    let transformed = CameraTransformTimelineBuilder.resolve(
      baseResolution: base,
      cameraParams: params,
      screenZoom: 1.8
    )
    let stepwise = CameraAnimationTimelineBuilder.resolve(
      canvasSize: canvasSize,
      baseResolution: base,
      transformedResolution: transformed,
      cameraParams: params,
      time: 0.12,
      totalDuration: 2.0,
      zoomState: CameraAnimationZoomState(isActive: true, localTime: 0.125)
    )
    let composed = CameraAnimationTimelineBuilder.resolvePresentation(
      canvasSize: canvasSize,
      baseResolution: base,
      cameraParams: params,
      screenZoom: 1.8,
      time: 0.12,
      totalDuration: 2.0,
      zoomState: CameraAnimationZoomState(isActive: true, localTime: 0.125)
    )

    XCTAssertEqual(composed.frame.origin.x, stepwise.frame.origin.x, accuracy: 0.0001)
    XCTAssertEqual(composed.frame.origin.y, stepwise.frame.origin.y, accuracy: 0.0001)
    XCTAssertEqual(composed.frame.width, stepwise.frame.width, accuracy: 0.0001)
    XCTAssertEqual(composed.frame.height, stepwise.frame.height, accuracy: 0.0001)
    XCTAssertEqual(composed.opacity, stepwise.opacity, accuracy: 0.0001)
    XCTAssertEqual(composed.additionalScale, stepwise.additionalScale, accuracy: 0.0001)
  }

  private func makeParams() -> CameraCompositionParams {
    CameraCompositionParams(
      visible: true,
      layoutPreset: .overlayBottomRight,
      normalizedCanvasCenter: nil,
      sizeFactor: 0.2,
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

final class LetterboxExporterTests: XCTestCase {
  func testSeparateCameraExportUsesCameraPrepassForAdvancedStyling() {
    let exporter = LetterboxExporter()
    let params = CameraCompositionParams(
      visible: true,
      layoutPreset: .overlayBottomRight,
      normalizedCanvasCenter: nil,
      sizeFactor: 0.2,
      shape: .circle,
      cornerRadius: 0.0,
      opacity: 0.9,
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

    XCTAssertTrue(exporter._testShouldUseCameraPrepass(cameraParams: params))
  }

  func testSeparateCameraExportUsesCameraPrepassForChromaKeyOnly() {
    let exporter = LetterboxExporter()
    let params = CameraCompositionParams(
      visible: true,
      layoutPreset: .overlayBottomRight,
      normalizedCanvasCenter: nil,
      sizeFactor: 0.2,
      shape: .square,
      cornerRadius: 0.0,
      opacity: 0.9,
      mirror: true,
      contentMode: .fill,
      zoomBehavior: .fixed,
      borderWidth: 0.0,
      borderColorArgb: nil,
      shadowPreset: 0,
      chromaKeyEnabled: true,
      chromaKeyStrength: 0.25,
      chromaKeyColorArgb: 0xFF00FF00
    )

    XCTAssertTrue(exporter._testShouldUseCameraPrepass(cameraParams: params))
  }

  func testSeparateCameraExportSkipsCameraPrepassForGeometryOnlyParams() {
    let exporter = LetterboxExporter()
    let params = CameraCompositionParams(
      visible: true,
      layoutPreset: .overlayBottomRight,
      normalizedCanvasCenter: nil,
      sizeFactor: 0.2,
      shape: .square,
      cornerRadius: 0.0,
      opacity: 0.9,
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

    XCTAssertFalse(exporter._testShouldUseCameraPrepass(cameraParams: params))
  }

  func testCameraPrepassRendersNonBlackFrame() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let cameraURL = tempDir.appendingPathComponent("camera.mov")
    try makeSolidColorVideo(
      url: cameraURL,
      size: CGSize(width: 128, height: 128),
      durationSeconds: 1.0,
      color: .systemRed
    )

    let params = CameraCompositionParams(
      visible: true,
      layoutPreset: .overlayTopRight,
      normalizedCanvasCenter: nil,
      sizeFactor: 0.2,
      shape: .squircle,
      cornerRadius: 0.15,
      opacity: 1.0,
      mirror: true,
      contentMode: .fill,
      zoomBehavior: .fixed,
      borderWidth: 0.0,
      borderColorArgb: nil,
      shadowPreset: 2,
      chromaKeyEnabled: false,
      chromaKeyStrength: 0.4,
      chromaKeyColorArgb: nil
    )

    let exporter = LetterboxExporter()
    let renderExpectation = expectation(description: "camera prepass rendered")
    var renderResult: Result<CameraPreparedIntermediate, Error>?

    exporter._testPrepareCameraIntermediate(
      inputURL: cameraURL,
      canvasSize: CGSize(width: 640, height: 360),
      cameraParams: params,
      fpsHint: 30
    ) { result in
      renderResult = result
      renderExpectation.fulfill()
    }

    wait(for: [renderExpectation], timeout: 30.0)
    let prepared = try XCTUnwrap(try renderResult?.get())
    defer {
      prepared.temporaryArtifacts.forEach { try? FileManager.default.removeItem(at: $0) }
    }
    XCTAssertTrue(prepared.cameraAssetIsPreStyled)

    let ratio = try nonBlackRatio(
      for: sampleFrameImage(url: prepared.url),
      ignoreTransparentPixels: true
    )
    XCTAssertGreaterThan(ratio, 0.05)

    XCTAssertNil(
      exporter._testValidateStyledCameraIntermediate(
        rawCameraURL: cameraURL,
        styledCameraURL: prepared.url
      )
    )
  }

  func testChromaKeyCameraPrepassRemovesGreenBackgroundAndKeepsSubject() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let cameraURL = tempDir.appendingPathComponent("camera.mov")
    try makeGreenScreenSubjectVideo(
      url: cameraURL,
      size: CGSize(width: 128, height: 128),
      durationSeconds: 1.0
    )

    let params = CameraCompositionParams(
      visible: true,
      layoutPreset: .overlayTopRight,
      normalizedCanvasCenter: nil,
      sizeFactor: 0.2,
      shape: .square,
      cornerRadius: 0.0,
      opacity: 1.0,
      mirror: false,
      contentMode: .fill,
      zoomBehavior: .fixed,
      borderWidth: 0.0,
      borderColorArgb: nil,
      shadowPreset: 0,
      chromaKeyEnabled: true,
      chromaKeyStrength: 0.25,
      chromaKeyColorArgb: 0xFF00FF00
    )

    let exporter = LetterboxExporter()
    let renderExpectation = expectation(description: "camera prepass rendered")
    var renderResult: Result<CameraPreparedIntermediate, Error>?

    exporter._testPrepareCameraIntermediate(
      inputURL: cameraURL,
      canvasSize: CGSize(width: 640, height: 360),
      cameraParams: params,
      fpsHint: 30
    ) { result in
      renderResult = result
      renderExpectation.fulfill()
    }

    wait(for: [renderExpectation], timeout: 30.0)
    let prepared = try XCTUnwrap(try renderResult?.get())
    defer {
      prepared.temporaryArtifacts.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    let image = try sampleFrameImage(url: prepared.url)
    XCTAssertLessThan(try visibleRatio(for: image), 0.55)
    XCTAssertLessThan(try dominantGreenRatio(for: image, ignoreTransparentPixels: true), 0.10)
    XCTAssertGreaterThan(try dominantRedRatio(for: image, ignoreTransparentPixels: true), 0.60)
  }

  func testAdvancedSeparateCameraExportProducesNonBlackCameraCrop() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let screenURL = tempDir.appendingPathComponent("screen.mov")
    let cameraURL = tempDir.appendingPathComponent("camera.mov")
    try makeSolidColorVideo(
      url: screenURL,
      size: CGSize(width: 320, height: 180),
      durationSeconds: 1.0,
      color: .systemBlue
    )
    try makeSolidColorVideo(
      url: cameraURL,
      size: CGSize(width: 128, height: 128),
      durationSeconds: 1.0,
      color: .systemRed
    )

    let params = CameraCompositionParams(
      visible: true,
      layoutPreset: .overlayTopRight,
      normalizedCanvasCenter: nil,
      sizeFactor: 0.2,
      shape: .squircle,
      cornerRadius: 0.15,
      opacity: 1.0,
      mirror: true,
      contentMode: .fill,
      zoomBehavior: .fixed,
      borderWidth: 0.0,
      borderColorArgb: nil,
      shadowPreset: 2,
      chromaKeyEnabled: false,
      chromaKeyStrength: 0.4,
      chromaKeyColorArgb: nil
    )
    let target = CGSize(width: 640, height: 360)
    let outputURL = tempDir.appendingPathComponent("final.mov")

    let exporter = LetterboxExporter()
    let exportExpectation = expectation(description: "final export")
    var exportResult: Result<URL, Error>?

    exporter.export(
      inputURL: screenURL,
      cameraInputURL: cameraURL,
      target: target,
      padding: 0.0,
      cornerRadius: 0.0,
      backgroundColor: nil,
      backgroundImagePath: nil,
      cursorSize: 1.0,
      showCursor: false,
      zoomEnabled: false,
      zoomFactor: 1.5,
      followStrength: 0.15,
      fpsHint: 30,
      outputURL: outputURL,
      format: "mov",
      codec: "h264",
      bitrate: "auto",
      fitMode: "fit",
      audioGainDb: 0.0,
      audioVolumePercent: 100.0,
      autoNormalizeOnExport: false,
      targetLoudnessDbfs: -16.0,
      cameraParams: params
    ) { result in
      exportResult = result
      exportExpectation.fulfill()
    }

    wait(for: [exportExpectation], timeout: 30.0)
    let finalURL = try XCTUnwrap(try exportResult?.get())

    let resolution = CameraLayoutResolver.effectiveFrame(canvasSize: target, params: params)
    let cropRatio = try cropNonBlackRatio(
      for: sampleFrameImage(url: finalURL),
      canvasSize: target,
      cropRect: resolution.frame
    )
    XCTAssertGreaterThan(cropRatio, 0.05)
  }

  func testScaleWithScreenZoomAddsCameraTransformRampsToExportComposition() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let screenURL = tempDir.appendingPathComponent("screen.mov")
    let cameraURL = tempDir.appendingPathComponent("camera.mov")
    try makeSolidColorVideo(
      url: screenURL,
      size: CGSize(width: 320, height: 180),
      durationSeconds: 1.0,
      color: .systemBlue
    )
    try makeSolidColorVideo(
      url: cameraURL,
      size: CGSize(width: 128, height: 128),
      durationSeconds: 1.0,
      color: .systemRed
    )

    let params = CompositionParams(
      targetSize: CGSize(width: 640, height: 360),
      padding: 0.0,
      cornerRadius: 0.0,
      backgroundColor: nil,
      backgroundImagePath: nil,
      cursorSize: 1.0,
      showCursor: false,
      zoomEnabled: true,
      zoomFactor: 1.8,
      followStrength: 0.15,
      fpsHint: 30,
      fitMode: "fit",
      audioGainDb: 0.0,
      audioVolumePercent: 100.0
    )
    let cameraParams = CameraCompositionParams(
      visible: true,
      layoutPreset: .overlayTopRight,
      normalizedCanvasCenter: nil,
      sizeFactor: 0.2,
      shape: .square,
      cornerRadius: 0.0,
      opacity: 1.0,
      mirror: false,
      contentMode: .fill,
      zoomBehavior: .scaleWithScreenZoom,
      zoomScaleMultiplier: 0.35,
      borderWidth: 0.0,
      borderColorArgb: nil,
      shadowPreset: 0,
      chromaKeyEnabled: false,
      chromaKeyStrength: 0.4,
      chromaKeyColorArgb: nil
    )

    let builder = CompositionBuilder()
    let result = try XCTUnwrap(
      builder.buildExport(
        asset: AVAsset(url: screenURL),
        cameraAsset: AVAsset(url: cameraURL),
        params: params,
        cameraParams: cameraParams,
        cursorRecording: makeZoomCursorRecording(),
        cameraAssetIsPreStyled: false
      )
    )

    let instruction = try XCTUnwrap(
      result.videoComposition.instructions.first as? AVMutableVideoCompositionInstruction
    )
    let cameraInstruction = try XCTUnwrap(instruction.layerInstructions.first)
    var startTransform = CGAffineTransform.identity
    var endTransform = CGAffineTransform.identity
    var timeRange = CMTimeRange.zero

    let hasRamp = cameraInstruction.getTransformRamp(
      for: CMTime(seconds: 0.52, preferredTimescale: 600),
      start: &startTransform,
      end: &endTransform,
      timeRange: &timeRange
    )

    XCTAssertTrue(hasRamp)
    XCTAssertFalse(
      transformsApproximatelyEqual(startTransform, endTransform),
      "camera transform should vary during active zoom"
    )
    XCTAssertGreaterThan(timeRange.duration.seconds, 0.0)
  }

  func testFixedCameraZoomBehaviorKeepsStaticExportTransform() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let screenURL = tempDir.appendingPathComponent("screen.mov")
    let cameraURL = tempDir.appendingPathComponent("camera.mov")
    try makeSolidColorVideo(
      url: screenURL,
      size: CGSize(width: 320, height: 180),
      durationSeconds: 1.0,
      color: .systemBlue
    )
    try makeSolidColorVideo(
      url: cameraURL,
      size: CGSize(width: 128, height: 128),
      durationSeconds: 1.0,
      color: .systemRed
    )

    let params = CompositionParams(
      targetSize: CGSize(width: 640, height: 360),
      padding: 0.0,
      cornerRadius: 0.0,
      backgroundColor: nil,
      backgroundImagePath: nil,
      cursorSize: 1.0,
      showCursor: false,
      zoomEnabled: true,
      zoomFactor: 1.8,
      followStrength: 0.15,
      fpsHint: 30,
      fitMode: "fit",
      audioGainDb: 0.0,
      audioVolumePercent: 100.0
    )
    let cameraParams = CameraCompositionParams(
      visible: true,
      layoutPreset: .overlayTopRight,
      normalizedCanvasCenter: nil,
      sizeFactor: 0.2,
      shape: .square,
      cornerRadius: 0.0,
      opacity: 1.0,
      mirror: false,
      contentMode: .fill,
      zoomBehavior: .fixed,
      zoomScaleMultiplier: 0.35,
      borderWidth: 0.0,
      borderColorArgb: nil,
      shadowPreset: 0,
      chromaKeyEnabled: false,
      chromaKeyStrength: 0.4,
      chromaKeyColorArgb: nil
    )

    let builder = CompositionBuilder()
    let result = try XCTUnwrap(
      builder.buildExport(
        asset: AVAsset(url: screenURL),
        cameraAsset: AVAsset(url: cameraURL),
        params: params,
        cameraParams: cameraParams,
        cursorRecording: makeZoomCursorRecording(),
        cameraAssetIsPreStyled: false
      )
    )

    let instruction = try XCTUnwrap(
      result.videoComposition.instructions.first as? AVMutableVideoCompositionInstruction
    )
    let cameraInstruction = try XCTUnwrap(instruction.layerInstructions.first)
    var startTransform = CGAffineTransform.identity
    var endTransform = CGAffineTransform.identity
    var timeRange = CMTimeRange.zero

    let hasRamp = cameraInstruction.getTransformRamp(
      for: CMTime(seconds: 0.45, preferredTimescale: 600),
      start: &startTransform,
      end: &endTransform,
      timeRange: &timeRange
    )

    if hasRamp {
      XCTAssertTrue(
        transformsApproximatelyEqual(startTransform, endTransform),
        "fixed camera behavior should not produce a time-varying camera transform"
      )
    }
  }

  func testIntroFadeAddsCameraOpacityRampAtStart() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let screenURL = tempDir.appendingPathComponent("screen.mov")
    let cameraURL = tempDir.appendingPathComponent("camera.mov")
    try makeSolidColorVideo(
      url: screenURL,
      size: CGSize(width: 320, height: 180),
      durationSeconds: 1.0,
      color: .systemBlue
    )
    try makeSolidColorVideo(
      url: cameraURL,
      size: CGSize(width: 128, height: 128),
      durationSeconds: 1.0,
      color: .systemRed
    )

    let params = CompositionParams(
      targetSize: CGSize(width: 640, height: 360),
      padding: 0.0,
      cornerRadius: 0.0,
      backgroundColor: nil,
      backgroundImagePath: nil,
      cursorSize: 1.0,
      showCursor: false,
      zoomEnabled: true,
      zoomFactor: 1.8,
      followStrength: 0.15,
      fpsHint: 30,
      fitMode: "fit",
      audioGainDb: 0.0,
      audioVolumePercent: 100.0
    )
    var cameraParams = CameraCompositionParams(
      visible: true,
      layoutPreset: .overlayTopRight,
      normalizedCanvasCenter: nil,
      sizeFactor: 0.2,
      shape: .square,
      cornerRadius: 0.0,
      opacity: 1.0,
      mirror: false,
      contentMode: .fill,
      zoomBehavior: .fixed,
      borderWidth: 0.0,
      borderColorArgb: nil,
      shadowPreset: 0,
      chromaKeyEnabled: false,
      chromaKeyStrength: 0.4,
      chromaKeyColorArgb: nil
    )
    cameraParams.introPreset = .fade

    let builder = CompositionBuilder()
    let result = try XCTUnwrap(
      builder.buildExport(
        asset: AVAsset(url: screenURL),
        cameraAsset: AVAsset(url: cameraURL),
        params: params,
        cameraParams: cameraParams,
        cursorRecording: nil,
        cameraAssetIsPreStyled: false
      )
    )

    let instruction = try XCTUnwrap(
      result.videoComposition.instructions.first as? AVMutableVideoCompositionInstruction
    )
    let cameraInstruction = try XCTUnwrap(instruction.layerInstructions.first)
    var startOpacity: Float = 0
    var endOpacity: Float = 0
    var timeRange = CMTimeRange.zero

    let hasRamp = cameraInstruction.getOpacityRamp(
      for: CMTime(seconds: 0.05, preferredTimescale: 600),
      startOpacity: &startOpacity,
      endOpacity: &endOpacity,
      timeRange: &timeRange
    )

    XCTAssertTrue(hasRamp)
    XCTAssertLessThan(startOpacity, endOpacity)
    XCTAssertGreaterThan(timeRange.duration.seconds, 0.0)
  }

  func testOutroFadeAddsCameraOpacityRampAtEnd() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let screenURL = tempDir.appendingPathComponent("screen.mov")
    let cameraURL = tempDir.appendingPathComponent("camera.mov")
    try makeSolidColorVideo(
      url: screenURL,
      size: CGSize(width: 320, height: 180),
      durationSeconds: 1.0,
      color: .systemBlue
    )
    try makeSolidColorVideo(
      url: cameraURL,
      size: CGSize(width: 128, height: 128),
      durationSeconds: 1.0,
      color: .systemRed
    )

    let params = CompositionParams(
      targetSize: CGSize(width: 640, height: 360),
      padding: 0.0,
      cornerRadius: 0.0,
      backgroundColor: nil,
      backgroundImagePath: nil,
      cursorSize: 1.0,
      showCursor: false,
      zoomEnabled: true,
      zoomFactor: 1.8,
      followStrength: 0.15,
      fpsHint: 30,
      fitMode: "fit",
      audioGainDb: 0.0,
      audioVolumePercent: 100.0
    )
    var cameraParams = CameraCompositionParams(
      visible: true,
      layoutPreset: .overlayTopRight,
      normalizedCanvasCenter: nil,
      sizeFactor: 0.2,
      shape: .square,
      cornerRadius: 0.0,
      opacity: 1.0,
      mirror: false,
      contentMode: .fill,
      zoomBehavior: .fixed,
      borderWidth: 0.0,
      borderColorArgb: nil,
      shadowPreset: 0,
      chromaKeyEnabled: false,
      chromaKeyStrength: 0.4,
      chromaKeyColorArgb: nil
    )
    cameraParams.outroPreset = .fade

    let builder = CompositionBuilder()
    let result = try XCTUnwrap(
      builder.buildExport(
        asset: AVAsset(url: screenURL),
        cameraAsset: AVAsset(url: cameraURL),
        params: params,
        cameraParams: cameraParams,
        cursorRecording: nil,
        cameraAssetIsPreStyled: false
      )
    )

    let instruction = try XCTUnwrap(
      result.videoComposition.instructions.first as? AVMutableVideoCompositionInstruction
    )
    let cameraInstruction = try XCTUnwrap(instruction.layerInstructions.first)
    var startOpacity: Float = 0
    var endOpacity: Float = 0
    var timeRange = CMTimeRange.zero

    let hasRamp = cameraInstruction.getOpacityRamp(
      for: CMTime(seconds: 0.95, preferredTimescale: 600),
      startOpacity: &startOpacity,
      endOpacity: &endOpacity,
      timeRange: &timeRange
    )

    XCTAssertTrue(hasRamp)
    XCTAssertGreaterThan(startOpacity, endOpacity)
    XCTAssertGreaterThan(timeRange.duration.seconds, 0.0)
  }

  func testZoomPulseAddsTransformRampDuringActiveZoom() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let screenURL = tempDir.appendingPathComponent("screen.mov")
    let cameraURL = tempDir.appendingPathComponent("camera.mov")
    try makeSolidColorVideo(
      url: screenURL,
      size: CGSize(width: 320, height: 180),
      durationSeconds: 1.0,
      color: .systemBlue
    )
    try makeSolidColorVideo(
      url: cameraURL,
      size: CGSize(width: 128, height: 128),
      durationSeconds: 1.0,
      color: .systemRed
    )

    let params = CompositionParams(
      targetSize: CGSize(width: 640, height: 360),
      padding: 0.0,
      cornerRadius: 0.0,
      backgroundColor: nil,
      backgroundImagePath: nil,
      cursorSize: 1.0,
      showCursor: false,
      zoomEnabled: true,
      zoomFactor: 1.8,
      followStrength: 0.15,
      fpsHint: 30,
      fitMode: "fit",
      audioGainDb: 0.0,
      audioVolumePercent: 100.0
    )
    var cameraParams = CameraCompositionParams(
      visible: true,
      layoutPreset: .overlayTopRight,
      normalizedCanvasCenter: nil,
      sizeFactor: 0.2,
      shape: .square,
      cornerRadius: 0.0,
      opacity: 1.0,
      mirror: false,
      contentMode: .fill,
      zoomBehavior: .fixed,
      borderWidth: 0.0,
      borderColorArgb: nil,
      shadowPreset: 0,
      chromaKeyEnabled: false,
      chromaKeyStrength: 0.4,
      chromaKeyColorArgb: nil
    )
    cameraParams.zoomEmphasisPreset = .pulse
    cameraParams.zoomEmphasisStrength = 0.10

    let builder = CompositionBuilder()
    let result = try XCTUnwrap(
      builder.buildExport(
        asset: AVAsset(url: screenURL),
        cameraAsset: AVAsset(url: cameraURL),
        params: params,
        cameraParams: cameraParams,
        cursorRecording: makeZoomCursorRecording(),
        cameraAssetIsPreStyled: false
      )
    )

    let instruction = try XCTUnwrap(
      result.videoComposition.instructions.first as? AVMutableVideoCompositionInstruction
    )
    let cameraInstruction = try XCTUnwrap(instruction.layerInstructions.first)
    let probeTimes: [Double] = [0.50, 0.52, 0.55, 0.58, 0.62, 0.68]
    var foundVaryingRamp = false

    for probeTime in probeTimes {
      var startTransform = CGAffineTransform.identity
      var endTransform = CGAffineTransform.identity
      var timeRange = CMTimeRange.zero

      let hasRamp = cameraInstruction.getTransformRamp(
        for: CMTime(seconds: probeTime, preferredTimescale: 600),
        start: &startTransform,
        end: &endTransform,
        timeRange: &timeRange
      )

      if hasRamp,
        timeRange.duration.seconds > 0.0,
        !transformsApproximatelyEqual(startTransform, endTransform)
      {
        foundVaryingRamp = true
        break
      }
    }

    XCTAssertTrue(foundVaryingRamp)
  }

  func testIntroAnimationAppliesToPreStyledCameraAsset() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let screenURL = tempDir.appendingPathComponent("screen.mov")
    let cameraURL = tempDir.appendingPathComponent("camera.mov")
    try makeSolidColorVideo(
      url: screenURL,
      size: CGSize(width: 320, height: 180),
      durationSeconds: 1.0,
      color: .systemBlue
    )
    try makeSolidColorVideo(
      url: cameraURL,
      size: CGSize(width: 128, height: 128),
      durationSeconds: 1.0,
      color: .systemRed
    )

    let params = CompositionParams(
      targetSize: CGSize(width: 640, height: 360),
      padding: 0.0,
      cornerRadius: 0.0,
      backgroundColor: nil,
      backgroundImagePath: nil,
      cursorSize: 1.0,
      showCursor: false,
      zoomEnabled: true,
      zoomFactor: 1.8,
      followStrength: 0.15,
      fpsHint: 30,
      fitMode: "fit",
      audioGainDb: 0.0,
      audioVolumePercent: 100.0
    )
    var cameraParams = CameraCompositionParams(
      visible: true,
      layoutPreset: .overlayTopRight,
      normalizedCanvasCenter: nil,
      sizeFactor: 0.2,
      shape: .square,
      cornerRadius: 0.0,
      opacity: 1.0,
      mirror: false,
      contentMode: .fill,
      zoomBehavior: .fixed,
      borderWidth: 0.0,
      borderColorArgb: nil,
      shadowPreset: 0,
      chromaKeyEnabled: false,
      chromaKeyStrength: 0.4,
      chromaKeyColorArgb: nil
    )
    cameraParams.introPreset = .pop

    let builder = CompositionBuilder()
    let result = try XCTUnwrap(
      builder.buildExport(
        asset: AVAsset(url: screenURL),
        cameraAsset: AVAsset(url: cameraURL),
        params: params,
        cameraParams: cameraParams,
        cursorRecording: nil,
        cameraAssetIsPreStyled: true
      )
    )

    let instruction = try XCTUnwrap(
      result.videoComposition.instructions.first as? AVMutableVideoCompositionInstruction
    )
    let cameraInstruction = try XCTUnwrap(instruction.layerInstructions.first)
    var startTransform = CGAffineTransform.identity
    var endTransform = CGAffineTransform.identity
    var timeRange = CMTimeRange.zero

    let hasRamp = cameraInstruction.getTransformRamp(
      for: CMTime(seconds: 0.05, preferredTimescale: 600),
      start: &startTransform,
      end: &endTransform,
      timeRange: &timeRange
    )

    XCTAssertTrue(hasRamp)
    XCTAssertFalse(transformsApproximatelyEqual(startTransform, endTransform))
  }

  func testChromaKeySeparateCameraExportRemovesKeyColorInFinalCrop() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let screenURL = tempDir.appendingPathComponent("screen.mov")
    let cameraURL = tempDir.appendingPathComponent("camera.mov")
    try makeSolidColorVideo(
      url: screenURL,
      size: CGSize(width: 320, height: 180),
      durationSeconds: 1.0,
      color: .systemBlue
    )
    try makeGreenScreenSubjectVideo(
      url: cameraURL,
      size: CGSize(width: 128, height: 128),
      durationSeconds: 1.0
    )

    let params = CameraCompositionParams(
      visible: true,
      layoutPreset: .overlayTopRight,
      normalizedCanvasCenter: nil,
      sizeFactor: 0.2,
      shape: .square,
      cornerRadius: 0.0,
      opacity: 1.0,
      mirror: false,
      contentMode: .fill,
      zoomBehavior: .fixed,
      borderWidth: 0.0,
      borderColorArgb: nil,
      shadowPreset: 0,
      chromaKeyEnabled: true,
      chromaKeyStrength: 0.25,
      chromaKeyColorArgb: 0xFF00FF00
    )
    let target = CGSize(width: 640, height: 360)
    let outputURL = tempDir.appendingPathComponent("final.mov")

    let exporter = LetterboxExporter()
    let exportExpectation = expectation(description: "final export")
    var exportResult: Result<URL, Error>?

    exporter.export(
      inputURL: screenURL,
      cameraInputURL: cameraURL,
      target: target,
      padding: 0.0,
      cornerRadius: 0.0,
      backgroundColor: nil,
      backgroundImagePath: nil,
      cursorSize: 1.0,
      showCursor: false,
      zoomEnabled: false,
      zoomFactor: 1.5,
      followStrength: 0.15,
      fpsHint: 30,
      outputURL: outputURL,
      format: "mov",
      codec: "h264",
      bitrate: "auto",
      fitMode: "fit",
      audioGainDb: 0.0,
      audioVolumePercent: 100.0,
      autoNormalizeOnExport: false,
      targetLoudnessDbfs: -16.0,
      cameraParams: params
    ) { result in
      exportResult = result
      exportExpectation.fulfill()
    }

    wait(for: [exportExpectation], timeout: 30.0)
    let finalURL = try XCTUnwrap(try exportResult?.get())

    let resolution = CameraLayoutResolver.effectiveFrame(canvasSize: target, params: params)
    let crop = try XCTUnwrap(bestCropImage(
      for: sampleFrameImage(url: finalURL),
      canvasSize: target,
      cropRect: resolution.frame
    ))

    XCTAssertLessThan(try dominantGreenRatio(for: crop, ignoreTransparentPixels: false), 0.12)
    XCTAssertGreaterThan(try dominantRedRatio(for: crop, ignoreTransparentPixels: false), 0.05)
  }

  func testChromaKeySeparateCameraExportCleansTemporaryPrepassArtifactsOnSuccess() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let screenURL = tempDir.appendingPathComponent("screen.mov")
    let cameraURL = tempDir.appendingPathComponent("camera-\(UUID().uuidString).mov")
    try makeSolidColorVideo(
      url: screenURL,
      size: CGSize(width: 320, height: 180),
      durationSeconds: 1.0,
      color: .systemBlue
    )
    try makeGreenScreenSubjectVideo(
      url: cameraURL,
      size: CGSize(width: 128, height: 128),
      durationSeconds: 1.0
    )

    let params = CameraCompositionParams(
      visible: true,
      layoutPreset: .overlayTopRight,
      normalizedCanvasCenter: nil,
      sizeFactor: 0.2,
      shape: .square,
      cornerRadius: 0.0,
      opacity: 1.0,
      mirror: false,
      contentMode: .fill,
      zoomBehavior: .fixed,
      borderWidth: 0.0,
      borderColorArgb: nil,
      shadowPreset: 0,
      chromaKeyEnabled: true,
      chromaKeyStrength: 0.25,
      chromaKeyColorArgb: 0xFF00FF00
    )

    let exporter = LetterboxExporter()
    let exportExpectation = expectation(description: "final export")
    var exportResult: Result<URL, Error>?

    exporter.export(
      inputURL: screenURL,
      cameraInputURL: cameraURL,
      target: CGSize(width: 640, height: 360),
      padding: 0.0,
      cornerRadius: 0.0,
      backgroundColor: nil,
      backgroundImagePath: nil,
      cursorSize: 1.0,
      showCursor: false,
      zoomEnabled: false,
      zoomFactor: 1.5,
      followStrength: 0.15,
      fpsHint: 30,
      outputURL: tempDir.appendingPathComponent("final.mov"),
      format: "mov",
      codec: "h264",
      bitrate: "auto",
      fitMode: "fit",
      audioGainDb: 0.0,
      audioVolumePercent: 100.0,
      autoNormalizeOnExport: false,
      targetLoudnessDbfs: -16.0,
      cameraParams: params
    ) { result in
      exportResult = result
      exportExpectation.fulfill()
    }

    wait(for: [exportExpectation], timeout: 30.0)
    _ = try XCTUnwrap(try exportResult?.get())

    let sourceStem = cameraURL.deletingPathExtension().lastPathComponent
    let leftovers = try FileManager.default.contentsOfDirectory(
      at: AppPaths.tempRoot(),
      includingPropertiesForKeys: nil
    ).filter { url in
      let name = url.lastPathComponent
      return name.contains(sourceStem) && (name.contains(".keyed.") || name.contains(".styled."))
    }

    XCTAssertTrue(leftovers.isEmpty)
  }

  func testCameraPrepassCleansTemporaryArtifactsOnCancellation() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let cameraURL = tempDir.appendingPathComponent("camera-\(UUID().uuidString).mov")
    try makeGreenScreenSubjectVideo(
      url: cameraURL,
      size: CGSize(width: 128, height: 128),
      durationSeconds: 1.0
    )

    let params = CameraCompositionParams(
      visible: true,
      layoutPreset: .overlayTopRight,
      normalizedCanvasCenter: nil,
      sizeFactor: 0.2,
      shape: .square,
      cornerRadius: 0.0,
      opacity: 1.0,
      mirror: false,
      contentMode: .fill,
      zoomBehavior: .fixed,
      borderWidth: 0.0,
      borderColorArgb: nil,
      shadowPreset: 0,
      chromaKeyEnabled: true,
      chromaKeyStrength: 0.25,
      chromaKeyColorArgb: 0xFF00FF00
    )

    let pipeline = CameraStyledIntermediatePipeline()
    let renderExpectation = expectation(description: "camera prepass cancelled")
    var renderResult: Result<CameraPreparedIntermediate, Error>?

    pipeline.prepareIntermediate(
      inputURL: cameraURL,
      canvasSize: CGSize(width: 640, height: 360),
      params: params,
      fpsHint: 30,
      isCancelled: { true },
      onProgress: nil
    ) { result in
      renderResult = result
      renderExpectation.fulfill()
    }

    wait(for: [renderExpectation], timeout: 30.0)
    XCTAssertThrowsError(try XCTUnwrap(renderResult).get())
    XCTAssertTrue(temporaryCameraArtifacts(for: cameraURL).isEmpty)
  }

  func testCameraPrepassCleansTemporaryArtifactsOnFailure() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let cameraURL = tempDir.appendingPathComponent("camera-\(UUID().uuidString).mov")
    try Data("not-a-real-video".utf8).write(to: cameraURL)

    let params = CameraCompositionParams(
      visible: true,
      layoutPreset: .overlayTopRight,
      normalizedCanvasCenter: nil,
      sizeFactor: 0.2,
      shape: .squircle,
      cornerRadius: 0.15,
      opacity: 1.0,
      mirror: false,
      contentMode: .fill,
      zoomBehavior: .fixed,
      borderWidth: 0.0,
      borderColorArgb: nil,
      shadowPreset: 2,
      chromaKeyEnabled: false,
      chromaKeyStrength: 0.4,
      chromaKeyColorArgb: nil
    )

    let pipeline = CameraStyledIntermediatePipeline()
    let renderExpectation = expectation(description: "camera prepass failed")
    var renderResult: Result<CameraPreparedIntermediate, Error>?

    pipeline.prepareIntermediate(
      inputURL: cameraURL,
      canvasSize: CGSize(width: 640, height: 360),
      params: params,
      fpsHint: 30,
      isCancelled: { false },
      onProgress: nil
    ) { result in
      renderResult = result
      renderExpectation.fulfill()
    }

    wait(for: [renderExpectation], timeout: 30.0)
    XCTAssertThrowsError(try XCTUnwrap(renderResult).get())
    XCTAssertTrue(temporaryCameraArtifacts(for: cameraURL).isEmpty)
  }

  func testScreenOnlyExportProducesMp4WithoutCameraArtifacts() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let screenURL = tempDir.appendingPathComponent("screen.mov")
    try makeSolidColorVideo(
      url: screenURL,
      size: CGSize(width: 320, height: 180),
      durationSeconds: 1.0,
      color: .systemBlue
    )

    let exporter = LetterboxExporter()
    let exportExpectation = expectation(description: "screen-only export")
    var exportResult: Result<URL, Error>?

    exporter.export(
      inputURL: screenURL,
      cameraInputURL: nil,
      target: CGSize(width: 640, height: 360),
      padding: 0.0,
      cornerRadius: 0.0,
      backgroundColor: nil,
      backgroundImagePath: nil,
      cursorSize: 1.0,
      showCursor: false,
      zoomEnabled: false,
      zoomFactor: 1.5,
      followStrength: 0.15,
      fpsHint: 30,
      outputURL: tempDir.appendingPathComponent("screen-only.mp4"),
      format: "mp4",
      codec: "h264",
      bitrate: "auto",
      fitMode: "fit",
      audioGainDb: 0.0,
      audioVolumePercent: 100.0,
      autoNormalizeOnExport: false,
      targetLoudnessDbfs: -16.0,
      cameraParams: nil
    ) { result in
      exportResult = result
      exportExpectation.fulfill()
    }

    wait(for: [exportExpectation], timeout: 30.0)
    let finalURL = try XCTUnwrap(try exportResult?.get())
    XCTAssertEqual(finalURL.pathExtension.lowercased(), "mp4")
    XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
  }

  func testStyledCameraIntermediateValidationFailsForBlackStyledAsset() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let rawURL = tempDir.appendingPathComponent("raw.mov")
    let styledURL = tempDir.appendingPathComponent("styled.mov")
    try makeSolidColorVideo(
      url: rawURL,
      size: CGSize(width: 128, height: 128),
      durationSeconds: 1.0,
      color: .systemRed
    )
    try makeSolidColorVideo(
      url: styledURL,
      size: CGSize(width: 128, height: 128),
      durationSeconds: 1.0,
      color: .black
    )

    let exporter = LetterboxExporter()
    let error = exporter._testValidateStyledCameraIntermediate(
      rawCameraURL: rawURL,
      styledCameraURL: styledURL
    )

    XCTAssertEqual(error?.userInfo["stage"] as? String, "styled_intermediate_validation")
  }

  func testFinalStyledCameraExportValidationFailsForBlackFinalCrop() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let styledURL = tempDir.appendingPathComponent("styled.mov")
    let finalURL = tempDir.appendingPathComponent("final.mov")
    try makeSolidColorVideo(
      url: styledURL,
      size: CGSize(width: 128, height: 128),
      durationSeconds: 1.0,
      color: .systemRed
    )
    try makeSolidColorVideo(
      url: finalURL,
      size: CGSize(width: 640, height: 360),
      durationSeconds: 1.0,
      color: .black
    )

    let params = CameraCompositionParams(
      visible: true,
      layoutPreset: .overlayTopRight,
      normalizedCanvasCenter: nil,
      sizeFactor: 0.2,
      shape: .squircle,
      cornerRadius: 0.15,
      opacity: 1.0,
      mirror: true,
      contentMode: .fill,
      zoomBehavior: .fixed,
      borderWidth: 0.0,
      borderColorArgb: nil,
      shadowPreset: 2,
      chromaKeyEnabled: false,
      chromaKeyStrength: 0.4,
      chromaKeyColorArgb: nil
    )

    let exporter = LetterboxExporter()
    let error = exporter._testValidateFinalStyledCameraExport(
      styledCameraURL: styledURL,
      finalExportURL: finalURL,
      canvasSize: CGSize(width: 640, height: 360),
      cameraParams: params
    )

    XCTAssertEqual(error?.userInfo["stage"] as? String, "final_output_validation")
  }

  private func makeTemporaryDirectory() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: nil
    )
    return url
  }

  private func makeZoomCursorRecording() -> CursorRecording {
    let defaultPixels = Data([255, 255, 255, 255])
    return CursorRecording(
      sprites: [
        CursorSprite(id: 0, width: 1, height: 1, hotspotX: 0, hotspotY: 0, pixels: defaultPixels),
        CursorSprite(id: 1, width: 1, height: 1, hotspotX: 0, hotspotY: 0, pixels: defaultPixels),
      ],
      frames: [
        CursorFrame(t: 0.0, x: 0.5, y: 0.5, spriteID: 0),
        CursorFrame(t: 0.25, x: 0.8, y: 0.5, spriteID: 1),
        CursorFrame(t: 0.55, x: 0.8, y: 0.5, spriteID: 1),
        CursorFrame(t: 0.85, x: 0.5, y: 0.5, spriteID: 0),
      ]
    )
  }

  private func transformsApproximatelyEqual(
    _ lhs: CGAffineTransform,
    _ rhs: CGAffineTransform,
    epsilon: CGFloat = 0.0001
  ) -> Bool {
    abs(lhs.a - rhs.a) <= epsilon
      && abs(lhs.b - rhs.b) <= epsilon
      && abs(lhs.c - rhs.c) <= epsilon
      && abs(lhs.d - rhs.d) <= epsilon
      && abs(lhs.tx - rhs.tx) <= epsilon
      && abs(lhs.ty - rhs.ty) <= epsilon
  }

  private func temporaryCameraArtifacts(for sourceURL: URL) -> [URL] {
    let sourceStem = sourceURL.deletingPathExtension().lastPathComponent
    return (try? FileManager.default.contentsOfDirectory(
      at: AppPaths.tempRoot(),
      includingPropertiesForKeys: nil
    ).filter { url in
      let name = url.lastPathComponent
      return name.contains(sourceStem) && (name.contains(".keyed.") || name.contains(".styled."))
    }) ?? []
  }

  private func makeSolidColorVideo(
    url: URL,
    size: CGSize,
    durationSeconds: Double,
    color: NSColor
  ) throws {
    try? FileManager.default.removeItem(at: url)

    let writer = try AVAssetWriter(url: url, fileType: .mov)
    let settings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: Int(size.width),
      AVVideoHeightKey: Int(size.height),
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false

    let pixelAttributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: Int(size.width),
      kCVPixelBufferHeightKey as String: Int(size.height),
      kCVPixelBufferCGImageCompatibilityKey as String: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: pixelAttributes
    )

    XCTAssertTrue(writer.canAdd(input))
    writer.add(input)
    XCTAssertTrue(writer.startWriting())
    writer.startSession(atSourceTime: .zero)

    let fps: Int32 = 30
    let frameCount = max(6, Int(durationSeconds * Double(fps)))

    for frame in 0..<frameCount {
      while !input.isReadyForMoreMediaData {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
      }

      let pixelBuffer = try makePixelBuffer(size: size, color: color)
      let time = CMTime(value: CMTimeValue(frame), timescale: fps)
      XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: time))
    }

    input.markAsFinished()
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting {
      semaphore.signal()
    }
    semaphore.wait()

    if let error = writer.error {
      throw error
    }
    XCTAssertEqual(writer.status, .completed)
  }

  private func makeGreenScreenSubjectVideo(
    url: URL,
    size: CGSize,
    durationSeconds: Double
  ) throws {
    try? FileManager.default.removeItem(at: url)

    let writer = try AVAssetWriter(url: url, fileType: .mov)
    let settings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: Int(size.width),
      AVVideoHeightKey: Int(size.height),
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false

    let pixelAttributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: Int(size.width),
      kCVPixelBufferHeightKey as String: Int(size.height),
      kCVPixelBufferCGImageCompatibilityKey as String: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: pixelAttributes
    )

    XCTAssertTrue(writer.canAdd(input))
    writer.add(input)
    XCTAssertTrue(writer.startWriting())
    writer.startSession(atSourceTime: .zero)

    let fps: Int32 = 30
    let frameCount = max(6, Int(durationSeconds * Double(fps)))
    let subjectRect = CGRect(
      x: size.width * 0.28,
      y: size.height * 0.22,
      width: size.width * 0.44,
      height: size.height * 0.58
    )

    for frame in 0..<frameCount {
      while !input.isReadyForMoreMediaData {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
      }

      let pixelBuffer = try makePatternPixelBuffer(
        size: size,
        backgroundColor: .systemGreen,
        subjectRect: subjectRect,
        subjectColor: .systemRed
      )
      let time = CMTime(value: CMTimeValue(frame), timescale: fps)
      XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: time))
    }

    input.markAsFinished()
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting {
      semaphore.signal()
    }
    semaphore.wait()

    if let error = writer.error {
      throw error
    }
    XCTAssertEqual(writer.status, .completed)
  }

  private func makePixelBuffer(size: CGSize, color: NSColor) throws -> CVPixelBuffer {
    try makePatternPixelBuffer(
      size: size,
      backgroundColor: color,
      subjectRect: nil,
      subjectColor: nil
    )
  }

  private func makePatternPixelBuffer(
    size: CGSize,
    backgroundColor: NSColor,
    subjectRect: CGRect?,
    subjectColor: NSColor?
  ) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let attrs: [String: Any] = [
      kCVPixelBufferCGImageCompatibilityKey as String: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
    ]
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      Int(size.width),
      Int(size.height),
      kCVPixelFormatType_32BGRA,
      attrs as CFDictionary,
      &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
      throw NSError(domain: "RunnerTests", code: Int(status))
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let baseAddress = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
      .assumingMemoryBound(to: UInt8.self)

    fillPixelBuffer(
      baseAddress: baseAddress,
      bytesPerRow: bytesPerRow,
      width: width,
      height: height,
      color: backgroundColor
    )

    if let subjectRect, let subjectColor {
      let clampedRect = subjectRect.integral.intersection(
        CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
      )
      guard !clampedRect.isNull, !clampedRect.isEmpty else {
        return pixelBuffer
      }

      for y in Int(clampedRect.minY)..<Int(clampedRect.maxY) {
        let row = baseAddress.advanced(by: y * bytesPerRow)
        for x in Int(clampedRect.minX)..<Int(clampedRect.maxX) {
          writePixel(
            row: row,
            x: x,
            color: subjectColor
          )
        }
      }
    }

    return pixelBuffer
  }

  private func fillPixelBuffer(
    baseAddress: UnsafeMutablePointer<UInt8>,
    bytesPerRow: Int,
    width: Int,
    height: Int,
    color: NSColor
  ) {
    for y in 0..<height {
      let row = baseAddress.advanced(by: y * bytesPerRow)
      for x in 0..<width {
        writePixel(row: row, x: x, color: color)
      }
    }
  }

  private func writePixel(
    row: UnsafeMutablePointer<UInt8>,
    x: Int,
    color: NSColor
  ) {
    let deviceColor = color.usingColorSpace(.deviceRGB) ?? color
    let red = UInt8(max(0.0, min(255.0, deviceColor.redComponent * 255.0)))
    let green = UInt8(max(0.0, min(255.0, deviceColor.greenComponent * 255.0)))
    let blue = UInt8(max(0.0, min(255.0, deviceColor.blueComponent * 255.0)))
    let alpha = UInt8(max(0.0, min(255.0, deviceColor.alphaComponent * 255.0)))
    let offset = x * 4
    row[offset] = blue
    row[offset + 1] = green
    row[offset + 2] = red
    row[offset + 3] = alpha
  }

  private func exportComposition(
    _ result: CompositionBuilder.ExportCompositionResult,
    to outputURL: URL,
    preset: String
  ) throws {
    XCTAssertTrue(
      Set(AVAssetExportSession.exportPresets(compatibleWith: result.asset)).contains(preset)
    )
    let export = try XCTUnwrap(AVAssetExportSession(asset: result.asset, presetName: preset))
    export.videoComposition = result.videoComposition
    export.outputFileType = .mov
    export.outputURL = outputURL

    let semaphore = DispatchSemaphore(value: 0)
    export.exportAsynchronously {
      semaphore.signal()
    }
    semaphore.wait()

    if let error = export.error {
      throw error
    }
    XCTAssertEqual(export.status, .completed)
  }

  private func sampleFrameImage(url: URL) throws -> CGImage {
    let asset = AVAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    return try generator.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil)
  }

  private func nonBlackRatio(
    for image: CGImage,
    ignoreTransparentPixels: Bool
  ) throws -> Double {
    try colorRatio(
      for: image,
      ignoreTransparentPixels: ignoreTransparentPixels,
      predicate: { red, green, blue in
        max(red, max(green, blue)) > 12
      }
    )
  }

  private func visibleRatio(for image: CGImage) throws -> Double {
    let width = 64
    let height = 64
    let bytesPerRow = width * 4
    var buffer = [UInt8](repeating: 0, count: height * bytesPerRow)

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    try buffer.withUnsafeMutableBytes { rawBuffer in
      let context = try XCTUnwrap(
        CGContext(
          data: rawBuffer.baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: bytesPerRow,
          space: colorSpace,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        )
      )
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    var visiblePixels = 0
    for pixelIndex in 0..<(width * height) {
      let offset = pixelIndex * 4
      if buffer[offset + 3] > 8 {
        visiblePixels += 1
      }
    }

    return Double(visiblePixels) / Double(width * height)
  }

  private func dominantGreenRatio(
    for image: CGImage,
    ignoreTransparentPixels: Bool
  ) throws -> Double {
    try colorRatio(
      for: image,
      ignoreTransparentPixels: ignoreTransparentPixels,
      predicate: { red, green, blue in
        Int(green) > Int(red) + 20 && Int(green) > Int(blue) + 20
      }
    )
  }

  private func dominantRedRatio(
    for image: CGImage,
    ignoreTransparentPixels: Bool
  ) throws -> Double {
    try colorRatio(
      for: image,
      ignoreTransparentPixels: ignoreTransparentPixels,
      predicate: { red, green, blue in
        Int(red) > Int(green) + 20 && Int(red) > Int(blue) + 20
      }
    )
  }

  private func colorRatio(
    for image: CGImage,
    ignoreTransparentPixels: Bool,
    predicate: (UInt8, UInt8, UInt8) -> Bool
  ) throws -> Double {
    let width = 64
    let height = 64
    let bytesPerRow = width * 4
    var buffer = [UInt8](repeating: 0, count: height * bytesPerRow)

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    try buffer.withUnsafeMutableBytes { rawBuffer in
      let context = try XCTUnwrap(
        CGContext(
          data: rawBuffer.baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: bytesPerRow,
          space: colorSpace,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        )
      )
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    var visiblePixels = 0
    var matchingPixels = 0
    for pixelIndex in 0..<(width * height) {
      let offset = pixelIndex * 4
      let alpha = buffer[offset + 3]
      if ignoreTransparentPixels && alpha <= 8 {
        continue
      }
      visiblePixels += 1
      let red = buffer[offset]
      let green = buffer[offset + 1]
      let blue = buffer[offset + 2]
      if predicate(red, green, blue) {
        matchingPixels += 1
      }
    }

    guard visiblePixels > 0 else { return 0.0 }
    return Double(matchingPixels) / Double(visiblePixels)
  }

  private func bestCropImage(
    for image: CGImage,
    canvasSize: CGSize,
    cropRect: CGRect
  ) -> CGImage? {
    let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let scaleX = CGFloat(image.width) / max(canvasSize.width, 1.0)
    let scaleY = CGFloat(image.height) / max(canvasSize.height, 1.0)

    return [false, true]
      .compactMap { flipY -> (CGImage, Double)? in
        let sourceY = flipY ? (canvasSize.height - cropRect.maxY) : cropRect.minY
        let pixelRect = CGRect(
          x: cropRect.minX * scaleX,
          y: sourceY * scaleY,
          width: cropRect.width * scaleX,
          height: cropRect.height * scaleY
        ).integral.intersection(imageBounds)

        guard pixelRect.width >= 1.0, pixelRect.height >= 1.0 else { return nil }
        guard let cropped = image.cropping(to: pixelRect) else { return nil }
        let ratio = (try? nonBlackRatio(for: cropped, ignoreTransparentPixels: false)) ?? 0.0
        return (cropped, ratio)
      }
      .max(by: { lhs, rhs in
        lhs.1 < rhs.1
      })?
      .0
  }

  private func cropNonBlackRatio(
    for image: CGImage,
    canvasSize: CGSize,
    cropRect: CGRect
  ) throws -> Double {
    guard let cropped = bestCropImage(for: image, canvasSize: canvasSize, cropRect: cropRect) else {
      return 0.0
    }
    return try nonBlackRatio(for: cropped, ignoreTransparentPixels: false)
  }
}

final class ScreenCaptureKitOverlayFilterPolicyTests: XCTestCase {
  func testOverlayWindowExcludedWhenSeparateCameraModeKeepsRecorderVisible() {
    let windows = [
      ScreenCaptureKitOverlayFilterPolicy.WindowRecord(windowID: 11, bundleIdentifier: "com.clingfy.clingfy.dev"),
      ScreenCaptureKitOverlayFilterPolicy.WindowRecord(windowID: 12, bundleIdentifier: "com.apple.finder"),
    ]

    let excluded = ScreenCaptureKitOverlayFilterPolicy.excludedWindowIDs(
      windows: windows,
      selfBundleIdentifier: "com.clingfy.clingfy.dev",
      overlayWindowID: 11,
      excludeRecorderApp: false,
      excludeCameraOverlayWindow: true
    )

    XCTAssertEqual(excluded, [11])
  }

  func testOverlayAndRecorderWindowsExcludedTogetherWhenRecorderAppExcluded() {
    let windows = [
      ScreenCaptureKitOverlayFilterPolicy.WindowRecord(windowID: 11, bundleIdentifier: "com.clingfy.clingfy.dev"),
      ScreenCaptureKitOverlayFilterPolicy.WindowRecord(windowID: 13, bundleIdentifier: "com.clingfy.clingfy.dev"),
      ScreenCaptureKitOverlayFilterPolicy.WindowRecord(windowID: 12, bundleIdentifier: "com.apple.finder"),
    ]

    let excluded = ScreenCaptureKitOverlayFilterPolicy.excludedWindowIDs(
      windows: windows,
      selfBundleIdentifier: "com.clingfy.clingfy.dev",
      overlayWindowID: 11,
      excludeRecorderApp: true,
      excludeCameraOverlayWindow: true
    )

    XCTAssertEqual(excluded, [11, 13])
  }

  func testBakedOverlayKeepsOverlayWindowWhenRecorderAppExcluded() {
    let windows = [
      ScreenCaptureKitOverlayFilterPolicy.WindowRecord(windowID: 11, bundleIdentifier: "com.clingfy.clingfy.dev"),
      ScreenCaptureKitOverlayFilterPolicy.WindowRecord(windowID: 13, bundleIdentifier: "com.clingfy.clingfy.dev"),
      ScreenCaptureKitOverlayFilterPolicy.WindowRecord(windowID: 12, bundleIdentifier: "com.apple.finder"),
    ]

    let excluded = ScreenCaptureKitOverlayFilterPolicy.excludedWindowIDs(
      windows: windows,
      selfBundleIdentifier: "com.clingfy.clingfy.dev",
      overlayWindowID: 11,
      excludeRecorderApp: true,
      excludeCameraOverlayWindow: false
    )

    XCTAssertEqual(excluded, [13])
  }
}

private final class MockCaptureBackend: CaptureBackend {
  var onStarted: ((URL) -> Void)?
  var onFinished: ((URL?, Error?) -> Void)?
  var onPaused: (() -> Void)?
  var onResumed: (() -> Void)?
  var onMicrophoneLevel: ((MicrophoneLevelSample) -> Void)?

  var canPauseResume: Bool = true
  var supportsLiveOverlayExclusionDuringSeparateCameraCapture: Bool = false
  var isRecording: Bool = false
  var isPaused: Bool = false
  var currentOutputURL: URL?
  private(set) var overlayUpdates: [CGWindowID?] = []
  private(set) var stopCallCount: Int = 0

  func start(config: CaptureStartConfig) {}
  func stop() { stopCallCount += 1 }
  func pause() {}
  func resume() {}

  func updateOverlay(windowID: CGWindowID?) {
    overlayUpdates.append(windowID)
  }
}

@MainActor
final class ScreenRecorderFacadeSeparateCameraTests: XCTestCase {
  func testFinishMetadataPublishesFinalCameraBasename() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let publishedScreenURL = tempDir.appendingPathComponent("recording.mov")
    let inProgressScreenURL = tempDir.appendingPathComponent("recording.123.inprogress.mov")
    let metadataURL = AppPaths.metadataSidecarURL(for: inProgressScreenURL)

    let initialMetadata = RecordingMetadata.create(
      rawURL: publishedScreenURL,
      displayMode: .explicitID,
      displayID: 1,
      cropRect: nil,
      frameRate: 60,
      quality: .fhd,
      cursorEnabled: true,
      cursorLinked: true,
      windowID: nil,
      excludedRecorderApp: false,
      camera: RecordingMetadata.CameraCaptureInfo(
        mode: .separateCameraAsset,
        enabled: true,
        rawRelativePath: AppPaths.cameraRawURL(for: publishedScreenURL).lastPathComponent,
        metadataRelativePath: AppPaths.cameraMetadataSidecarURL(for: publishedScreenURL).lastPathComponent,
        deviceId: "camera-1",
        mirroredRaw: true,
        nominalFrameRate: 30,
        dimensions: .init(width: 1920, height: 1080),
        segments: []
      ),
      editorSeed: makeEditorSeed()
    )
    try initialMetadata.write(to: metadataURL)

    let cameraResult = CameraRecordingResult(
      rawURL: AppPaths.cameraRawURL(for: inProgressScreenURL),
      metadataURL: AppPaths.cameraMetadataSidecarURL(for: inProgressScreenURL),
      metadata: CameraRecordingMetadata(
        version: 1,
        recordingId: "camera-recording-id",
        rawRelativePath: AppPaths.cameraRawURL(for: inProgressScreenURL).lastPathComponent,
        metadataRelativePath: AppPaths.cameraMetadataSidecarURL(for: inProgressScreenURL)
          .lastPathComponent,
        deviceId: "camera-1",
        mirroredRaw: true,
        nominalFrameRate: 30,
        dimensions: .init(width: 1920, height: 1080),
        startedAt: RecordingMetadata.iso8601String(from: Date(timeIntervalSince1970: 0)),
        endedAt: RecordingMetadata.iso8601String(from: Date(timeIntervalSince1970: 5)),
        segments: []
      )
    )

    let facade = ScreenRecorderFacade()
    facade._testUpdateMetadataSidecarOnFinish(
      for: inProgressScreenURL,
      cameraResult: cameraResult,
      publishedScreenURL: publishedScreenURL
    )

    let updated = try RecordingMetadata.read(from: metadataURL)
    XCTAssertEqual(updated.camera?.rawRelativePath, "recording.camera.mov")
    XCTAssertEqual(updated.camera?.metadataRelativePath, "recording.camera.meta.json")
    XCTAssertFalse(updated.camera?.rawRelativePath?.contains(".inprogress.") ?? true)
  }

  func testSeparateCameraCaptureConfigRespectsRecorderExclusionPreference() {
    let prefs = PreferencesStore()
    let originalOverlayEnabled = prefs.overlayEnabled
    let originalOverlayLinked = prefs.overlayLinked
    let originalExcludeRecorderApp = prefs.excludeRecorderApp
    let originalCameraCaptureMode = prefs.cameraCaptureMode
    defer {
      prefs.overlayEnabled = originalOverlayEnabled
      prefs.overlayLinked = originalOverlayLinked
      prefs.excludeRecorderApp = originalExcludeRecorderApp
      prefs.cameraCaptureMode = originalCameraCaptureMode
    }

    prefs.overlayEnabled = true
    prefs.overlayLinked = true
    prefs.cameraCaptureMode = .separateCameraAsset
    prefs.excludeRecorderApp = false

    let facade = ScreenRecorderFacade()
    let target = CaptureTarget(mode: .explicitID, displayID: 1)

    let defaultConfig = facade._testBuildCaptureStartConfig(
      target: target,
      effectiveOverlayID: 42
    )
    XCTAssertFalse(defaultConfig.excludeRecorderApp)
    XCTAssertEqual(defaultConfig.cameraOverlayWindowID, 42)
    XCTAssertTrue(defaultConfig.excludeCameraOverlayWindow)

    prefs.excludeRecorderApp = true

    let excludedConfig = facade._testBuildCaptureStartConfig(
      target: target,
      effectiveOverlayID: 42
    )
    XCTAssertTrue(excludedConfig.excludeRecorderApp)
    XCTAssertEqual(excludedConfig.cameraOverlayWindowID, 42)
    XCTAssertTrue(excludedConfig.excludeCameraOverlayWindow)
  }

  func testSeparateCameraModeSuppressesOverlayWindowDuringCaptureOnAVFoundation() {
    let prefs = PreferencesStore()
    let originalOverlayEnabled = prefs.overlayEnabled
    let originalOverlayLinked = prefs.overlayLinked
    let originalCameraCaptureMode = prefs.cameraCaptureMode
    defer {
      prefs.overlayEnabled = originalOverlayEnabled
      prefs.overlayLinked = originalOverlayLinked
      prefs.cameraCaptureMode = originalCameraCaptureMode
    }

    prefs.overlayEnabled = true
    prefs.overlayLinked = true
    prefs.cameraCaptureMode = .separateCameraAsset

    let facade = ScreenRecorderFacade()
    let backend = MockCaptureBackend()
    backend.supportsLiveOverlayExclusionDuringSeparateCameraCapture = false
    facade._testSetCaptureBackend(backend)
    XCTAssertTrue(facade._testShouldSuppressOverlayWindowDuringCapture())
  }

  func testSeparateCameraModeKeepsOverlayVisibleOnScreenCaptureKit() {
    let prefs = PreferencesStore()
    let originalOverlayEnabled = prefs.overlayEnabled
    let originalOverlayLinked = prefs.overlayLinked
    let originalCameraCaptureMode = prefs.cameraCaptureMode
    defer {
      prefs.overlayEnabled = originalOverlayEnabled
      prefs.overlayLinked = originalOverlayLinked
      prefs.cameraCaptureMode = originalCameraCaptureMode
    }

    prefs.overlayEnabled = true
    prefs.overlayLinked = true
    prefs.cameraCaptureMode = .separateCameraAsset

    let facade = ScreenRecorderFacade()
    let backend = MockCaptureBackend()
    backend.supportsLiveOverlayExclusionDuringSeparateCameraCapture = true
    facade._testSetCaptureBackend(backend)
    XCTAssertFalse(facade._testShouldSuppressOverlayWindowDuringCapture())
  }

  func testSeparateCameraOverlaySyncUsesNilOnAVFoundation() {
    let prefs = PreferencesStore()
    let originalOverlayEnabled = prefs.overlayEnabled
    let originalOverlayLinked = prefs.overlayLinked
    let originalCameraCaptureMode = prefs.cameraCaptureMode
    defer {
      prefs.overlayEnabled = originalOverlayEnabled
      prefs.overlayLinked = originalOverlayLinked
      prefs.cameraCaptureMode = originalCameraCaptureMode
    }

    prefs.overlayEnabled = true
    prefs.overlayLinked = true
    prefs.cameraCaptureMode = .separateCameraAsset

    let facade = ScreenRecorderFacade()
    let backend = MockCaptureBackend()
    backend.supportsLiveOverlayExclusionDuringSeparateCameraCapture = false
    facade._testSetCaptureBackend(backend)
    facade._testSetRecorderState(.recording)

    XCTAssertNil(facade._testOverlayWindowIDForCapture(liveOverlayWindowID: 77))
  }

  func testSeparateCameraOverlaySyncUsesLiveOverlayWindowOnScreenCaptureKit() {
    let prefs = PreferencesStore()
    let originalOverlayEnabled = prefs.overlayEnabled
    let originalOverlayLinked = prefs.overlayLinked
    let originalCameraCaptureMode = prefs.cameraCaptureMode
    defer {
      prefs.overlayEnabled = originalOverlayEnabled
      prefs.overlayLinked = originalOverlayLinked
      prefs.cameraCaptureMode = originalCameraCaptureMode
    }

    prefs.overlayEnabled = true
    prefs.overlayLinked = true
    prefs.cameraCaptureMode = .separateCameraAsset

    let facade = ScreenRecorderFacade()
    let backend = MockCaptureBackend()
    backend.supportsLiveOverlayExclusionDuringSeparateCameraCapture = true
    facade._testSetCaptureBackend(backend)
    facade._testSetRecorderState(.recording)

    XCTAssertEqual(facade._testOverlayWindowIDForCapture(liveOverlayWindowID: 77), 77)
  }

  func testCameraRecorderBeginResultDispatchesBeginCaptureToMain() {
    let facade = ScreenRecorderFacade()
    let beginCaptureExpectation = expectation(description: "beginCapture invoked on main")
    let noFailureExpectation = expectation(description: "no failure callback")
    noFailureExpectation.isInverted = true

    DispatchQueue.global(qos: .userInitiated).async {
      Task { @MainActor in
        facade._testHandleCameraRecorderBeginResult(
          .success(()),
          beginCapture: {
            XCTAssertTrue(Thread.isMainThread)
            beginCaptureExpectation.fulfill()
          },
          onFailure: { _ in
            noFailureExpectation.fulfill()
          }
        )
      }
    }

    wait(for: [beginCaptureExpectation, noFailureExpectation], timeout: 1.0)
  }

  func testOverlayUITransitionDispatchesToMain() {
    let facade = ScreenRecorderFacade()
    let expectation = expectation(description: "overlay transition runs on main")

    DispatchQueue.global(qos: .userInitiated).async {
      Task { @MainActor in
        facade._testRunOverlayUITransitionOnMain { isMainThread in
          XCTAssertTrue(isMainThread)
          expectation.fulfill()
        }
      }
    }

    wait(for: [expectation], timeout: 1.0)
  }

  func testResolvePreviewMediaSourcesUsesPublishedCameraAsset() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let screenURL = tempDir.appendingPathComponent("recording.mov")
    let cameraURL = AppPaths.cameraRawURL(for: screenURL)
    try Data("screen".utf8).write(to: screenURL)
    try Data("camera".utf8).write(to: cameraURL)

    let metadata = RecordingMetadata.create(
      rawURL: screenURL,
      displayMode: .explicitID,
      displayID: 1,
      cropRect: nil,
      frameRate: 60,
      quality: .fhd,
      cursorEnabled: true,
      cursorLinked: true,
      windowID: nil,
      excludedRecorderApp: false,
      camera: RecordingMetadata.CameraCaptureInfo(
        mode: .separateCameraAsset,
        enabled: true,
        rawRelativePath: cameraURL.lastPathComponent,
        metadataRelativePath: AppPaths.cameraMetadataSidecarURL(for: screenURL).lastPathComponent,
        deviceId: "camera-1",
        mirroredRaw: true,
        nominalFrameRate: 30,
        dimensions: .init(width: 1920, height: 1080),
        segments: []
      ),
      editorSeed: makeEditorSeed()
    )
    try metadata.write(to: AppPaths.metadataSidecarURL(for: screenURL))

    let facade = ScreenRecorderFacade()
    let mediaSources = facade.resolvePreviewMediaSources(source: screenURL.path)

    XCTAssertEqual(mediaSources.cameraPath, cameraURL.path)
  }

  func testResolvePreviewMediaSourcesFallsBackWhenMetadataPointsToMissingInProgressCamera() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let screenURL = tempDir.appendingPathComponent("recording.mov")
    let publishedCameraURL = AppPaths.cameraRawURL(for: screenURL)
    try Data("screen".utf8).write(to: screenURL)
    try Data("camera".utf8).write(to: publishedCameraURL)

    let metadata = RecordingMetadata.create(
      rawURL: screenURL,
      displayMode: .explicitID,
      displayID: 1,
      cropRect: nil,
      frameRate: 60,
      quality: .fhd,
      cursorEnabled: true,
      cursorLinked: true,
      windowID: nil,
      excludedRecorderApp: false,
      camera: RecordingMetadata.CameraCaptureInfo(
        mode: .separateCameraAsset,
        enabled: true,
        rawRelativePath: "recording.123.inprogress.camera.mov",
        metadataRelativePath: "recording.123.inprogress.camera.meta.json",
        deviceId: "camera-1",
        mirroredRaw: true,
        nominalFrameRate: 30,
        dimensions: .init(width: 1920, height: 1080),
        segments: []
      ),
      editorSeed: makeEditorSeed()
    )
    try metadata.write(to: AppPaths.metadataSidecarURL(for: screenURL))

    let facade = ScreenRecorderFacade()
    let mediaSources = facade.resolvePreviewMediaSources(source: screenURL.path)

    XCTAssertNil(mediaSources.cameraPath)
  }

  func testResolvePreviewSceneIncludesTwoSourceMediaAndCameraParams() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let screenURL = tempDir.appendingPathComponent("recording.mov")
    let cameraURL = AppPaths.cameraRawURL(for: screenURL)
    try Data("screen".utf8).write(to: screenURL)
    try Data("camera".utf8).write(to: cameraURL)

    let metadata = RecordingMetadata.create(
      rawURL: screenURL,
      displayMode: .explicitID,
      displayID: 1,
      cropRect: nil,
      frameRate: 60,
      quality: .fhd,
      cursorEnabled: true,
      cursorLinked: true,
      windowID: nil,
      excludedRecorderApp: false,
      camera: RecordingMetadata.CameraCaptureInfo(
        mode: .separateCameraAsset,
        enabled: true,
        rawRelativePath: cameraURL.lastPathComponent,
        metadataRelativePath: AppPaths.cameraMetadataSidecarURL(for: screenURL).lastPathComponent,
        deviceId: "camera-1",
        mirroredRaw: true,
        nominalFrameRate: 30,
        dimensions: .init(width: 1920, height: 1080),
        segments: []
      ),
      editorSeed: makeEditorSeed()
    )
    try metadata.write(to: AppPaths.metadataSidecarURL(for: screenURL))

    let params = CompositionParams(
      targetSize: CGSize(width: 1280, height: 720),
      padding: 0,
      cornerRadius: 0,
      backgroundColor: nil,
      backgroundImagePath: nil,
      cursorSize: 1.0,
      showCursor: true,
      zoomEnabled: true,
      zoomFactor: 1.5,
      followStrength: 0.15,
      fpsHint: 60,
      fitMode: "fit",
      audioGainDb: 0.0,
      audioVolumePercent: 100.0
    )
    let facade = ScreenRecorderFacade()
    let scene = facade.resolvePreviewScene(source: screenURL.path, screenParams: params)

    XCTAssertEqual(scene.mediaSources.screenPath, screenURL.path)
    XCTAssertEqual(scene.mediaSources.cameraPath, cameraURL.path)
    XCTAssertEqual(scene.cameraParams?.layoutPreset, .overlayBottomRight)
  }

  func testRecordingSceneInfoExposesFeatureLevelCameraExportCapabilities() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let screenURL = tempDir.appendingPathComponent("recording.mov")
    let cameraURL = AppPaths.cameraRawURL(for: screenURL)
    try Data("screen".utf8).write(to: screenURL)
    try Data("camera".utf8).write(to: cameraURL)

    let metadata = RecordingMetadata.create(
      rawURL: screenURL,
      displayMode: .explicitID,
      displayID: 1,
      cropRect: nil,
      frameRate: 60,
      quality: .fhd,
      cursorEnabled: true,
      cursorLinked: true,
      windowID: nil,
      excludedRecorderApp: false,
      camera: RecordingMetadata.CameraCaptureInfo(
        mode: .separateCameraAsset,
        enabled: true,
        rawRelativePath: cameraURL.lastPathComponent,
        metadataRelativePath: AppPaths.cameraMetadataSidecarURL(for: screenURL).lastPathComponent,
        deviceId: "camera-1",
        mirroredRaw: true,
        nominalFrameRate: 30,
        dimensions: .init(width: 1920, height: 1080),
        segments: []
      ),
      editorSeed: makeEditorSeed()
    )
    try metadata.write(to: AppPaths.metadataSidecarURL(for: screenURL))

    let facade = ScreenRecorderFacade()
    var scenePayload: Any?
    facade.getRecordingSceneInfo(source: screenURL.path) { value in
      scenePayload = value
    }

    let payload = try XCTUnwrap(scenePayload as? [String: Any])
    XCTAssertEqual(payload["cameraPath"] as? String, cameraURL.path)
    XCTAssertNil(payload["supportsAdvancedCameraExportStyling"])
    let capabilities = try XCTUnwrap(payload["cameraExportCapabilities"] as? [String: Bool])
    XCTAssertEqual(capabilities["shapeMask"], true)
    XCTAssertEqual(capabilities["cornerRadius"], true)
    XCTAssertEqual(capabilities["border"], true)
    XCTAssertEqual(capabilities["shadow"], true)
    XCTAssertEqual(capabilities["chromaKey"], true)
    let camera = try XCTUnwrap(payload["camera"] as? [String: Any])
    XCTAssertEqual(camera["zoomBehavior"] as? String, CameraZoomBehavior.fixed.rawValue)
    let zoomScaleMultiplier = try XCTUnwrap(camera["zoomScaleMultiplier"] as? Double)
    XCTAssertEqual(zoomScaleMultiplier, 0.35, accuracy: 0.0001)
    XCTAssertEqual(camera["introPreset"] as? String, CameraIntroPreset.none.rawValue)
    XCTAssertEqual(camera["outroPreset"] as? String, CameraOutroPreset.none.rawValue)
    XCTAssertEqual(
      camera["zoomEmphasisPreset"] as? String,
      CameraZoomEmphasisPreset.none.rawValue
    )
    XCTAssertEqual(
      camera["introDurationMs"] as? Int,
      CameraCompositionParams.defaultIntroDurationMs
    )
    XCTAssertEqual(
      camera["outroDurationMs"] as? Int,
      CameraCompositionParams.defaultOutroDurationMs
    )
    let zoomEmphasisStrength = try XCTUnwrap(camera["zoomEmphasisStrength"] as? Double)
    XCTAssertEqual(
      zoomEmphasisStrength,
      CameraCompositionParams.defaultZoomEmphasisStrength,
      accuracy: 0.0001
    )
  }

  func testResolveCameraCompositionParamsAcceptsScaleWithZoomMultiplier() throws {
    let facade = ScreenRecorderFacade()

    let params = facade.resolveCameraCompositionParams(
      source: "/tmp/recording.mov",
      args: [
        "cameraVisible": true,
        "cameraLayoutPreset": "overlayTopRight",
        "cameraZoomBehavior": "scaleWithScreenZoom",
        "cameraZoomScaleMultiplier": 0.6,
      ]
    )

    XCTAssertEqual(params?.zoomBehavior, .scaleWithScreenZoom)
    let zoomScaleMultiplier = try XCTUnwrap(params?.zoomScaleMultiplier)
    XCTAssertEqual(zoomScaleMultiplier, 0.6, accuracy: 0.0001)
  }

  func testResolveCameraCompositionParamsAcceptsAnimationOverrides() throws {
    let facade = ScreenRecorderFacade()

    let params = facade.resolveCameraCompositionParams(
      source: "/tmp/recording.mov",
      args: [
        "cameraVisible": true,
        "cameraLayoutPreset": "overlayTopRight",
        "cameraIntroPreset": "pop",
        "cameraOutroPreset": "slide",
        "cameraZoomEmphasisPreset": "pulse",
        "cameraIntroDurationMs": 300,
        "cameraOutroDurationMs": 260,
        "cameraZoomEmphasisStrength": 0.12,
      ]
    )

    XCTAssertEqual(params?.introPreset, .pop)
    XCTAssertEqual(params?.outroPreset, .slide)
    XCTAssertEqual(params?.zoomEmphasisPreset, .pulse)
    XCTAssertEqual(params?.introDurationMs, 300)
    XCTAssertEqual(params?.outroDurationMs, 260)
    let zoomEmphasisStrength = try XCTUnwrap(params?.zoomEmphasisStrength)
    XCTAssertEqual(zoomEmphasisStrength, 0.12, accuracy: 0.0001)
  }

  func testSeparateCameraExportSanitizesOnlyUnsupportedChromaKeyStyling() {
    let params = CameraCompositionParams(
      visible: true,
      layoutPreset: .overlayBottomRight,
      normalizedCanvasCenter: CGPoint(x: 0.5, y: 0.5),
      sizeFactor: 0.2,
      shape: .circle,
      cornerRadius: 0.35,
      opacity: 0.9,
      mirror: true,
      contentMode: .fill,
      zoomBehavior: .fixed,
      borderWidth: 6,
      borderColorArgb: 0xFFFFFFFF,
      shadowPreset: 2,
      chromaKeyEnabled: true,
      chromaKeyStrength: 0.8,
      chromaKeyColorArgb: 0xFF00FF00
    )

    let facade = ScreenRecorderFacade()
    let sanitized = facade._testSanitizedCameraParamsForExport(
      params,
      cameraPath: "/tmp/recording.camera.mov"
    )

    XCTAssertEqual(sanitized?.shape, params.shape)
    XCTAssertEqual(sanitized?.cornerRadius, params.cornerRadius)
    XCTAssertEqual(sanitized?.borderWidth, params.borderWidth)
    XCTAssertEqual(sanitized?.borderColorArgb, params.borderColorArgb)
    XCTAssertEqual(sanitized?.shadowPreset, params.shadowPreset)
    XCTAssertEqual(sanitized?.chromaKeyEnabled, true)
    XCTAssertEqual(sanitized?.chromaKeyColorArgb, params.chromaKeyColorArgb)
    XCTAssertEqual(sanitized?.chromaKeyStrength, params.chromaKeyStrength)
    XCTAssertEqual(sanitized?.opacity, params.opacity)
    XCTAssertEqual(sanitized?.mirror, params.mirror)
  }

  func testSeparateCameraRecorderFailureStopsCaptureAndStoresFailure() {
    let prefs = PreferencesStore()
    let originalOverlayEnabled = prefs.overlayEnabled
    let originalOverlayLinked = prefs.overlayLinked
    let originalCameraCaptureMode = prefs.cameraCaptureMode
    defer {
      prefs.overlayEnabled = originalOverlayEnabled
      prefs.overlayLinked = originalOverlayLinked
      prefs.cameraCaptureMode = originalCameraCaptureMode
    }

    prefs.overlayEnabled = true
    prefs.overlayLinked = true
    prefs.cameraCaptureMode = .separateCameraAsset

    let facade = ScreenRecorderFacade()
    let backend = MockCaptureBackend()
    backend.supportsLiveOverlayExclusionDuringSeparateCameraCapture = true
    facade._testSetCaptureBackend(backend)
    facade._testSetRecorderState(.recording)

    facade._testHandleSeparateCameraRecorderFailure(
      FlutterError(code: NativeErrorCode.recordingError, message: "camera failed", details: nil)
    )

    XCTAssertEqual(backend.stopCallCount, 1)
    XCTAssertEqual(facade._testPendingSeparateCameraFailureCode(), NativeErrorCode.recordingError)
    XCTAssertEqual(
      (facade._testTerminalRecordingError(screenError: nil) as? FlutterError)?.message,
      "camera failed"
    )
  }

  private func makeTemporaryDirectory() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: nil
    )
    return url
  }

  private func makeEditorSeed() -> RecordingMetadata.EditorSeed {
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
      cameraZoomBehavior: .fixed,
      cameraZoomScaleMultiplier: 0.35,
      cameraChromaKeyEnabled: false,
      cameraChromaKeyStrength: 0.4,
      cameraChromaKeyColorArgb: nil
    )
  }
}
