import AVFoundation
import Cocoa
import FlutterMacOS
import XCTest

@testable import Clingfy

private func makeRecordingProjectRoot(at parent: URL, includeCamera: Bool) throws -> URL {
  let projectRoot = parent.appendingPathComponent(
    RecordingProjectPaths.projectDirectoryName(for: "recording"),
    isDirectory: true
  )
  let fileManager = FileManager.default
  try fileManager.createDirectory(
    at: RecordingProjectPaths.captureDirectoryURL(for: projectRoot),
    withIntermediateDirectories: true
  )
  try fileManager.createDirectory(
    at: RecordingProjectPaths.postDirectoryURL(for: projectRoot),
    withIntermediateDirectories: true
  )
  try fileManager.createDirectory(
    at: RecordingProjectPaths.derivedDirectoryURL(for: projectRoot),
    withIntermediateDirectories: true
  )
  if includeCamera {
    try fileManager.createDirectory(
      at: RecordingProjectPaths.cameraSegmentsDirectoryURL(for: projectRoot),
      withIntermediateDirectories: true
    )
  }

  let manifest = RecordingProjectManifest.create(
    projectId: "recording",
    displayName: "Recording",
    includeCamera: includeCamera
  )
  try manifest.write(to: RecordingProjectPaths.manifestURL(for: projectRoot))
  return projectRoot
}

final class RecordingProjectPathsTests: XCTestCase {
  func testProjectArtifactsUseExpectedDirectoryLayout() {
    let projectRoot = URL(
      fileURLWithPath: "/tmp/rec_2026-04-05_000000_abcd1234.\(RecordingProjectPaths.projectExtension)",
      isDirectory: true
    )

    XCTAssertEqual(
      RecordingProjectPaths.screenVideoURL(for: projectRoot).path,
      "/tmp/rec_2026-04-05_000000_abcd1234.\(RecordingProjectPaths.projectExtension)/capture/screen.mov"
    )
    XCTAssertEqual(RecordingProjectPaths.screenMetadataURL(for: projectRoot).lastPathComponent, "screen.meta.json")
    XCTAssertEqual(RecordingProjectPaths.cursorDataURL(for: projectRoot).lastPathComponent, "cursor.json")
    XCTAssertEqual(RecordingProjectPaths.zoomManualURL(for: projectRoot).lastPathComponent, "zoom.manual.json")
    XCTAssertEqual(RecordingProjectPaths.cameraRawURL(for: projectRoot).lastPathComponent, "raw.mov")
    XCTAssertEqual(RecordingProjectPaths.cameraMetadataURL(for: projectRoot).lastPathComponent, "meta.json")
    XCTAssertEqual(RecordingProjectPaths.cameraSegmentsDirectoryURL(for: projectRoot).lastPathComponent, "segments")

    let artifactNames = RecordingProjectPaths.allProjectArtifactURLs(for: projectRoot).map(\.lastPathComponent)
    XCTAssertEqual(
      artifactNames,
      [
        "rec_2026-04-05_000000_abcd1234.\(RecordingProjectPaths.projectExtension)",
        "project.json",
        "capture",
        "screen.mov",
        "screen.meta.json",
        "cursor.json",
        "zoom.manual.json",
        "camera",
        "raw.mov",
        "meta.json",
        "segments",
        "post",
        "state.json",
        "thumbnail.jpg",
        "derived",
        "waveform.json",
      ]
    )
  }
}

final class RecordingMetadataTests: XCTestCase {
  func testVersion2RoundTripPreservesCameraAndEditorSeed() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let projectRoot = tempDir.appendingPathComponent(
      RecordingProjectPaths.projectDirectoryName(for: "recording"),
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: RecordingProjectPaths.captureDirectoryURL(for: projectRoot),
      withIntermediateDirectories: true
    )
    let metadataURL = RecordingProjectPaths.screenMetadataURL(for: projectRoot)
    let cameraInfo = RecordingMetadata.CameraCaptureInfo(
      mode: .separateCameraAsset,
      enabled: true,
      rawRelativePath: RecordingProjectPaths.relativeCameraRawPath,
      metadataRelativePath: RecordingProjectPaths.relativeCameraMetadataPath,
      deviceId: "camera-1",
      mirroredRaw: true,
      nominalFrameRate: 30,
      dimensions: .init(width: 1920, height: 1080),
      segments: [
        .init(
          index: 0,
          relativePath: "camera/segments/segment_000.mov",
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
      screenRawRelativePath: RecordingProjectPaths.relativeScreenVideoPath,
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
    XCTAssertEqual(decoded.screen.rawRelativePath, "capture/screen.mov")
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

final class RecordingProjectPackageRegistrationTests: XCTestCase {
  func testInfoPlistDeclaresClingfyProjectPackageType() throws {
    let infoPlistURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/Info.plist")
    let plistData = try Data(contentsOf: infoPlistURL)
    let plist = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: plistData, format: nil)
        as? [String: Any]
    )

    let exportedTypes = try XCTUnwrap(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
    let projectType = try XCTUnwrap(
      exportedTypes.first { ($0["UTTypeIdentifier"] as? String) == "com.clingfy.project" }
    )
    let exportedExtensions = try XCTUnwrap(
      (projectType["UTTypeTagSpecification"] as? [String: Any])?["public.filename-extension"]
        as? [String]
    )

    XCTAssertEqual(projectType["UTTypeDescription"] as? String, "Clingfy Project")
    XCTAssertEqual(projectType["UTTypeIconFile"] as? String, "ClingfyProjectIcon")
    XCTAssertEqual(
      projectType["UTTypeConformsTo"] as? [String],
      ["com.apple.package"]
    )
    XCTAssertEqual(exportedExtensions, ["clingfyproj"])

    let documentTypes = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
    let documentType = try XCTUnwrap(
      documentTypes.first { ($0["CFBundleTypeName"] as? String) == "Clingfy Project" }
    )

    XCTAssertEqual(documentType["CFBundleTypeRole"] as? String, "Editor")
    XCTAssertEqual(documentType["LSHandlerRank"] as? String, "Owner")
    XCTAssertEqual(documentType["CFBundleTypeIconFile"] as? String, "ClingfyProjectIcon")
    XCTAssertEqual(
      documentType["LSItemContentTypes"] as? [String],
      ["com.clingfy.project"]
    )
  }

  func testProjectIconIsBundledInAppResources() {
    let bundle = Bundle(for: ScreenRecorderFacade.self)
    XCTAssertNotNil(bundle.url(forResource: "ClingfyProjectIcon", withExtension: "icns"))
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
    let placementSourceRect = try XCTUnwrap(prepared.placementSourceRect)
    let renderedSize = try orientedVideoSize(url: prepared.url)
    let baseResolution = CameraLayoutResolver.effectiveFrame(
      canvasSize: CGSize(width: 640, height: 360),
      params: params
    )
    XCTAssertGreaterThan(renderedSize.height, placementSourceRect.height)
    XCTAssertEqual(placementSourceRect.width, ceil(baseResolution.frame.width), accuracy: 1.0)
    XCTAssertEqual(placementSourceRect.height, ceil(baseResolution.frame.height), accuracy: 1.0)

    let ratio = try nonBlackRatio(
      for: sampleFrameImage(url: prepared.url),
      ignoreTransparentPixels: true
    )
    XCTAssertGreaterThan(ratio, 0.05)

    XCTAssertNil(
      exporter._testValidateStyledCameraIntermediate(
        rawCameraURL: cameraURL,
        styledCameraURL: prepared.url,
        placementSourceRect: placementSourceRect
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

    let projectRoot = try makeRecordingProjectRoot(at: tempDir, includeCamera: true)
    let project = try RecordingProjectRef.open(projectRoot: projectRoot)
    let screenURL = RecordingProjectPaths.screenVideoURL(for: projectRoot)
    let cameraURL = RecordingProjectPaths.cameraRawURL(for: projectRoot)
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
      project: project,
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

  func testTwoSourceExportAppliesScreenZoomRampWhileKeepingFixedCameraStatic() throws {
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
    XCTAssertEqual(instruction.layerInstructions.count, 2)

    let cameraInstruction = try XCTUnwrap(instruction.layerInstructions.first)
    let screenInstruction = try XCTUnwrap(instruction.layerInstructions.last)

    var cameraStart = CGAffineTransform.identity
    var cameraEnd = CGAffineTransform.identity
    var cameraTimeRange = CMTimeRange.zero
    let hasCameraRamp = cameraInstruction.getTransformRamp(
      for: CMTime(seconds: 0.52, preferredTimescale: 600),
      start: &cameraStart,
      end: &cameraEnd,
      timeRange: &cameraTimeRange
    )

    if hasCameraRamp {
      XCTAssertTrue(
        transformsApproximatelyEqual(cameraStart, cameraEnd),
        "fixed camera behavior should stay static even while the screen zooms"
      )
    }

    var screenStart = CGAffineTransform.identity
    var screenEnd = CGAffineTransform.identity
    var screenTimeRange = CMTimeRange.zero
    let hasScreenRamp = screenInstruction.getTransformRamp(
      for: CMTime(seconds: 0.52, preferredTimescale: 600),
      start: &screenStart,
      end: &screenEnd,
      timeRange: &screenTimeRange
    )

    XCTAssertTrue(hasScreenRamp)
    XCTAssertFalse(
      transformsApproximatelyEqual(screenStart, screenEnd),
      "screen transform should vary during active zoom in the two-source path"
    )
    XCTAssertGreaterThan(screenTimeRange.duration.seconds, 0.0)
  }

  func testSingleSourceExportConfiguresCompositeZoomWithoutCursorOverlay() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let screenURL = tempDir.appendingPathComponent("screen.mov")
    try makeSolidColorVideo(
      url: screenURL,
      size: CGSize(width: 320, height: 180),
      durationSeconds: 1.0,
      color: .systemBlue
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

    let builder = CompositionBuilder()
    let result = try XCTUnwrap(
      builder.buildExport(
        asset: AVAsset(url: screenURL),
        cameraAsset: nil,
        params: params,
        cameraParams: nil,
        cursorRecording: makeZoomCursorRecording(),
        cameraAssetIsPreStyled: false
      )
    )

    XCTAssertNotNil(
      result.videoComposition.animationTool,
      "single-source export should still configure the composite zoom animation tool even when the cursor overlay is hidden"
    )
  }

  func testTwoSourceExportKeepsCameraPinnedWhileCursorFollowsZoomedScreen() throws {
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
      cursorSize: 20.0,
      showCursor: true,
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
      layoutPreset: .overlayBottomLeft,
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

    let outputURL = tempDir.appendingPathComponent("two-source.mov")
    try exportComposition(result, to: outputURL, preset: AVAssetExportPresetHighestQuality)

    let image = try sampleFrameImage(url: outputURL, time: 0.55)
    let cameraResolution = CameraLayoutResolver.effectiveFrame(
      canvasSize: params.targetSize,
      params: cameraParams
    )
    let cameraCrop = try XCTUnwrap(
      try bestScoredCropImage(
        for: image,
        canvasSize: params.targetSize,
        cropRect: cameraResolution.frame,
        scorer: { try dominantRedRatio(for: $0, ignoreTransparentPixels: false) }
      )
    )
    let centerCrop = try XCTUnwrap(
      bestCropImage(
        for: image,
        canvasSize: params.targetSize,
        cropRect: CGRect(x: 220, y: 80, width: 200, height: 200)
      )
    )

    XCTAssertGreaterThan(
      try dominantRedRatio(for: cameraCrop, ignoreTransparentPixels: false),
      0.25,
      "camera crop should remain visibly red in its pinned overlay frame during opposite-side zoom"
    )
    XCTAssertGreaterThan(
      try dominantWhiteRatio(for: centerCrop, ignoreTransparentPixels: false),
      0.002,
      "cursor should stay visually tied to the zoomed screen path near the viewport center"
    )
  }

  func testNormalizedFittedTransformRemovesPreferredTransformOriginOffset() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let cameraURL = tempDir.appendingPathComponent("camera.mov")
    try makeSolidColorVideo(
      url: cameraURL,
      size: CGSize(width: 80, height: 80),
      durationSeconds: 1.0,
      color: .systemRed,
      preferredTransform: CGAffineTransform(translationX: 23, y: 17)
    )

    let asset = AVAsset(url: cameraURL)
    let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
    let destinationRect = CGRect(x: 40, y: 60, width: 100, height: 100)

    let builder = CompositionBuilder()
    let fittedRect = builder._testFittedRect(
      for: track,
      sourceSize: CGSize(width: 80, height: 80),
      destinationRect: destinationRect,
      fitMode: "fit",
      mirror: false
    )

    XCTAssertEqual(fittedRect.minX, destinationRect.minX, accuracy: 1.0)
    XCTAssertEqual(fittedRect.minY, destinationRect.minY, accuracy: 1.0)
    XCTAssertEqual(fittedRect.width, destinationRect.width, accuracy: 1.0)
    XCTAssertEqual(fittedRect.height, destinationRect.height, accuracy: 1.0)
  }

  func testSourceRectFittedTransformPlacesInnerStyledFrameIntoDestinationRect() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let cameraURL = tempDir.appendingPathComponent("camera.mov")
    try makeSolidColorVideo(
      url: cameraURL,
      size: CGSize(width: 160, height: 140),
      durationSeconds: 1.0,
      color: .systemRed
    )

    let asset = AVAsset(url: cameraURL)
    let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
    let sourceRect = CGRect(x: 24, y: 30, width: 80, height: 60)
    let destinationRect = CGRect(x: 48, y: 72, width: 120, height: 90)

    let builder = CompositionBuilder()
    let fittedRect = builder._testFittedRect(
      for: track,
      sourceSize: CGSize(width: 160, height: 140),
      sourceRect: sourceRect,
      destinationRect: destinationRect,
      fitMode: "fit",
      mirror: false
    )

    XCTAssertEqual(fittedRect.minX, destinationRect.minX, accuracy: 1.0)
    XCTAssertEqual(fittedRect.minY, destinationRect.minY, accuracy: 1.0)
    XCTAssertEqual(fittedRect.width, destinationRect.width, accuracy: 1.0)
    XCTAssertEqual(fittedRect.height, destinationRect.height, accuracy: 1.0)
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

    let projectRoot = try makeRecordingProjectRoot(at: tempDir, includeCamera: true)
    let project = try RecordingProjectRef.open(projectRoot: projectRoot)
    let screenURL = RecordingProjectPaths.screenVideoURL(for: projectRoot)
    let cameraURL = RecordingProjectPaths.cameraRawURL(for: projectRoot)
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
      project: project,
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
    let crop = try XCTUnwrap(
      try bestScoredCropImage(
        for: sampleFrameImage(url: finalURL),
        canvasSize: target,
        cropRect: resolution.frame,
        scorer: { try dominantRedRatio(for: $0, ignoreTransparentPixels: true) }
      )
    )

    XCTAssertLessThan(try dominantGreenRatio(for: crop, ignoreTransparentPixels: false), 0.12)
    XCTAssertGreaterThan(try dominantRedRatio(for: crop, ignoreTransparentPixels: true), 0.05)
  }

  func testChromaKeySeparateCameraExportCleansTemporaryPrepassArtifactsOnSuccess() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let projectRoot = try makeRecordingProjectRoot(at: tempDir, includeCamera: true)
    let project = try RecordingProjectRef.open(projectRoot: projectRoot)
    let screenURL = RecordingProjectPaths.screenVideoURL(for: projectRoot)
    let cameraURL = RecordingProjectPaths.cameraRawURL(for: projectRoot)
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
      project: project,
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

    let projectRoot = try makeRecordingProjectRoot(at: tempDir, includeCamera: false)
    let project = try RecordingProjectRef.open(projectRoot: projectRoot)
    let screenURL = RecordingProjectPaths.screenVideoURL(for: projectRoot)
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
      project: project,
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

  func testScreenOnlyExportUsesBackgroundColorForLetterboxArea() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let projectRoot = try makeRecordingProjectRoot(at: tempDir, includeCamera: false)
    let project = try RecordingProjectRef.open(projectRoot: projectRoot)
    let screenURL = RecordingProjectPaths.screenVideoURL(for: projectRoot)
    try makeSolidColorVideo(
      url: screenURL,
      size: CGSize(width: 180, height: 320),
      durationSeconds: 1.0,
      color: .blue
    )

    let target = CGSize(width: 640, height: 360)
    let exporter = LetterboxExporter()
    let exportExpectation = expectation(description: "screen-only export with background color")
    var exportResult: Result<URL, Error>?

    exporter.export(
      project: project,
      target: target,
      padding: 0.0,
      cornerRadius: 0.0,
      backgroundColor: 0xFFFF0000,
      backgroundImagePath: nil,
      cursorSize: 1.0,
      showCursor: false,
      zoomEnabled: false,
      zoomFactor: 1.5,
      followStrength: 0.15,
      fpsHint: 30,
      outputURL: tempDir.appendingPathComponent("screen-only-bg.mp4"),
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
    let image = try sampleFrameImage(url: finalURL)

    let cornerCrop = try XCTUnwrap(
      bestCropImage(
        for: image,
        canvasSize: target,
        cropRect: CGRect(x: 0, y: 0, width: 80, height: 80)
      )
    )
    XCTAssertGreaterThan(
      try dominantRedRatio(for: cornerCrop, ignoreTransparentPixels: false),
      0.80
    )

    let centerCrop = try XCTUnwrap(
      bestCropImage(
        for: image,
        canvasSize: target,
        cropRect: CGRect(x: 260, y: 110, width: 120, height: 140)
      )
    )
    XCTAssertGreaterThan(
      try dominantBlueRatio(for: centerCrop, ignoreTransparentPixels: false),
      0.80
    )
  }

  func testScreenOnlyExportUsesBackgroundImageForLetterboxArea() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let projectRoot = try makeRecordingProjectRoot(at: tempDir, includeCamera: false)
    let project = try RecordingProjectRef.open(projectRoot: projectRoot)
    let screenURL = RecordingProjectPaths.screenVideoURL(for: projectRoot)
    let backgroundURL = tempDir.appendingPathComponent("background.png")
    try makeSolidColorVideo(
      url: screenURL,
      size: CGSize(width: 180, height: 320),
      durationSeconds: 1.0,
      color: .blue
    )
    try makeSolidColorImage(
      url: backgroundURL,
      size: CGSize(width: 640, height: 360),
      color: .red
    )

    let target = CGSize(width: 640, height: 360)
    let exporter = LetterboxExporter()
    let exportExpectation = expectation(description: "screen-only export with background image")
    var exportResult: Result<URL, Error>?

    exporter.export(
      project: project,
      target: target,
      padding: 0.0,
      cornerRadius: 0.0,
      backgroundColor: nil,
      backgroundImagePath: backgroundURL.path,
      cursorSize: 1.0,
      showCursor: false,
      zoomEnabled: false,
      zoomFactor: 1.5,
      followStrength: 0.15,
      fpsHint: 30,
      outputURL: tempDir.appendingPathComponent("screen-only-bg-image.mp4"),
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
    let image = try sampleFrameImage(url: finalURL)

    let cornerCrop = try XCTUnwrap(
      bestCropImage(
        for: image,
        canvasSize: target,
        cropRect: CGRect(x: 0, y: 0, width: 80, height: 80)
      )
    )
    XCTAssertGreaterThan(
      try dominantRedRatio(for: cornerCrop, ignoreTransparentPixels: false),
      0.80
    )

    let centerCrop = try XCTUnwrap(
      bestCropImage(
        for: image,
        canvasSize: target,
        cropRect: CGRect(x: 260, y: 110, width: 120, height: 140)
      )
    )
    XCTAssertGreaterThan(
      try dominantBlueRatio(for: centerCrop, ignoreTransparentPixels: false),
      0.80
    )
  }

  func testSeparateCameraExportUsesBackgroundColorOutsideScreenContent() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let projectRoot = try makeRecordingProjectRoot(at: tempDir, includeCamera: true)
    let project = try RecordingProjectRef.open(projectRoot: projectRoot)
    let screenURL = RecordingProjectPaths.screenVideoURL(for: projectRoot)
    let cameraURL = RecordingProjectPaths.cameraRawURL(for: projectRoot)
    try makeSolidColorVideo(
      url: screenURL,
      size: CGSize(width: 180, height: 320),
      durationSeconds: 1.0,
      color: .blue
    )
    try makeSolidColorVideo(
      url: cameraURL,
      size: CGSize(width: 128, height: 128),
      durationSeconds: 1.0,
      color: .green
    )

    let cameraParams = CameraCompositionParams(
      visible: true,
      layoutPreset: .overlayBottomRight,
      normalizedCanvasCenter: nil,
      sizeFactor: 0.24,
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

    let target = CGSize(width: 640, height: 360)
    let exporter = LetterboxExporter()
    let exportExpectation = expectation(description: "separate-camera export with background color")
    var exportResult: Result<URL, Error>?

    exporter.export(
      project: project,
      target: target,
      padding: 0.0,
      cornerRadius: 0.0,
      backgroundColor: 0xFFFF0000,
      backgroundImagePath: nil,
      cursorSize: 1.0,
      showCursor: false,
      zoomEnabled: false,
      zoomFactor: 1.5,
      followStrength: 0.15,
      fpsHint: 30,
      outputURL: tempDir.appendingPathComponent("screen-camera-bg.mp4"),
      format: "mp4",
      codec: "h264",
      bitrate: "auto",
      fitMode: "fit",
      audioGainDb: 0.0,
      audioVolumePercent: 100.0,
      autoNormalizeOnExport: false,
      targetLoudnessDbfs: -16.0,
      cameraParams: cameraParams
    ) { result in
      exportResult = result
      exportExpectation.fulfill()
    }

    wait(for: [exportExpectation], timeout: 30.0)
    let finalURL = try XCTUnwrap(try exportResult?.get())
    let image = try sampleFrameImage(url: finalURL)

    let cornerCrop = try XCTUnwrap(
      bestCropImage(
        for: image,
        canvasSize: target,
        cropRect: CGRect(x: 0, y: 0, width: 80, height: 80)
      )
    )
    XCTAssertGreaterThan(
      try dominantRedRatio(for: cornerCrop, ignoreTransparentPixels: false),
      0.80
    )

    let centerCrop = try XCTUnwrap(
      bestCropImage(
        for: image,
        canvasSize: target,
        cropRect: CGRect(x: 260, y: 110, width: 120, height: 140)
      )
    )
    XCTAssertGreaterThan(
      try dominantBlueRatio(for: centerCrop, ignoreTransparentPixels: false),
      0.75
    )

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
      cameraParams: params,
      placementSourceRect: CGRect(x: 16, y: 16, width: 96, height: 96)
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
    color: NSColor,
    preferredTransform: CGAffineTransform = .identity
  ) throws {
    try makePatternVideo(
      url: url,
      size: size,
      durationSeconds: durationSeconds,
      backgroundColor: color,
      subjectRect: nil,
      subjectColor: nil,
      preferredTransform: preferredTransform
    )
  }

  private func makeSolidColorImage(
    url: URL,
    size: CGSize,
    color: NSColor
  ) throws {
    let width = max(Int(size.width.rounded(.up)), 1)
    let height = max(Int(size.height.rounded(.up)), 1)
    let imageRep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: width,
      pixelsHigh: height,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    )
    let rep = try XCTUnwrap(imageRep)
    NSGraphicsContext.saveGraphicsState()
    let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
    NSGraphicsContext.current = context
    color.setFill()
    NSBezierPath(rect: CGRect(x: 0, y: 0, width: width, height: height)).fill()
    NSGraphicsContext.restoreGraphicsState()

    let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    try data.write(to: url)
  }

  private func makeGreenScreenSubjectVideo(
    url: URL,
    size: CGSize,
    durationSeconds: Double
  ) throws {
    try makePatternVideo(
      url: url,
      size: size,
      durationSeconds: durationSeconds,
      backgroundColor: .systemGreen,
      subjectRect: CGRect(
        x: size.width * 0.28,
        y: size.height * 0.22,
        width: size.width * 0.44,
        height: size.height * 0.58
      ),
      subjectColor: .systemRed
    )
  }

  private func makePatternVideo(
    url: URL,
    size: CGSize,
    durationSeconds: Double,
    backgroundColor: NSColor,
    subjectRect: CGRect?,
    subjectColor: NSColor?,
    preferredTransform: CGAffineTransform = .identity
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
    input.transform = preferredTransform

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

      let pixelBuffer = try makePatternPixelBuffer(
        size: size,
        backgroundColor: backgroundColor,
        subjectRect: subjectRect,
        subjectColor: subjectColor
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

  private func sampleFrameImage(url: URL, time: Double = 0.5) throws -> CGImage {
    let asset = AVAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    return try generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil)
  }

  private func orientedVideoSize(url: URL) throws -> CGSize {
    let asset = AVAsset(url: url)
    let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
    let rect = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
    return CGSize(width: abs(rect.width), height: abs(rect.height))
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

  private func dominantBlueRatio(
    for image: CGImage,
    ignoreTransparentPixels: Bool
  ) throws -> Double {
    try colorRatio(
      for: image,
      ignoreTransparentPixels: ignoreTransparentPixels,
      predicate: { red, green, blue in
        Int(blue) > Int(red) + 20 && Int(blue) > Int(green) + 20
      }
    )
  }

  private func dominantWhiteRatio(
    for image: CGImage,
    ignoreTransparentPixels: Bool
  ) throws -> Double {
    try colorRatio(
      for: image,
      ignoreTransparentPixels: ignoreTransparentPixels,
      predicate: { red, green, blue in
        red > 220 && green > 220 && blue > 220
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
    try? bestScoredCropImage(
      for: image,
      canvasSize: canvasSize,
      cropRect: cropRect,
      scorer: { try nonBlackRatio(for: $0, ignoreTransparentPixels: false) }
    )
  }

  private func bestScoredCropImage(
    for image: CGImage,
    canvasSize: CGSize,
    cropRect: CGRect,
    scorer: (CGImage) throws -> Double
  ) throws -> CGImage? {
    let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let scaleX = CGFloat(image.width) / max(canvasSize.width, 1.0)
    let scaleY = CGFloat(image.height) / max(canvasSize.height, 1.0)

    let candidates = [false, true]
      .compactMap { flipY -> CGImage? in
        let sourceY = flipY ? (canvasSize.height - cropRect.maxY) : cropRect.minY
        let pixelRect = CGRect(
          x: cropRect.minX * scaleX,
          y: sourceY * scaleY,
          width: cropRect.width * scaleX,
          height: cropRect.height * scaleY
        ).integral.intersection(imageBounds)

        guard pixelRect.width >= 1.0, pixelRect.height >= 1.0 else { return nil }
        return image.cropping(to: pixelRect)
      }

    guard !candidates.isEmpty else { return nil }

    var bestCrop: CGImage?
    var bestScore = -Double.infinity
    for candidate in candidates {
      let score = try scorer(candidate)
      if score > bestScore {
        bestScore = score
        bestCrop = candidate
      }
    }

    return bestCrop
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

private final class MockAVFoundationCapturePipeline: AVFoundationCapturePipelining {
  var onStarted: ((URL) -> Void)?
  var onPaused: (() -> Void)?
  var onResumed: (() -> Void)?
  var onFinished: ((URL?, Error?) -> Void)?
  var onMicrophoneLevel: ((MicrophoneLevelSample) -> Void)?

  var isRecording: Bool = false
  var isRecordingPaused: Bool = false
  var currentOutputURL: URL?

  func start(
    displayID: CGDirectDisplayID,
    cropRect: CGRect?,
    quality: RecordingQuality,
    frameRate: Int,
    includeAudioDevice: AVCaptureDevice?,
    makeOutputURL: @escaping () throws -> URL
  ) {
    currentOutputURL = try? makeOutputURL()
    isRecording = true
  }

  func stop() {
    isRecording = false
    isRecordingPaused = false
  }

  func pause() {
    isRecordingPaused = true
  }

  func resume() {
    isRecordingPaused = false
  }

  func emitMicrophoneLevel(_ sample: MicrophoneLevelSample) {
    onMicrophoneLevel?(sample)
  }
}

private final class MockMicrophoneLevelMonitor: MicrophoneLevelMonitoring {
  private(set) var startDeviceIDs: [String?] = []
  private(set) var stopEmitZeroValues: [Bool] = []
  private var onLevel: ((MicrophoneLevelSample) -> Void)?

  func start(deviceID: String?, onLevel: @escaping (MicrophoneLevelSample) -> Void) {
    startDeviceIDs.append(deviceID)
    self.onLevel = onLevel
  }

  func stop(emitZero: Bool) {
    stopEmitZeroValues.append(emitZero)
  }

  func emit(_ sample: MicrophoneLevelSample) {
    onLevel?(sample)
  }
}

@MainActor
final class MicrophoneLevelTelemetryTests: XCTestCase {
  func testAVFoundationBackendForwardsPipelineMicrophoneLevels() throws {
    let pipeline = MockAVFoundationCapturePipeline()
    let backend = CaptureBackendAVFoundation(pipeline: pipeline)
    let expectation = expectation(description: "backend forwards microphone level")
    var received: MicrophoneLevelSample?

    backend.onMicrophoneLevel = { sample in
      received = sample
      expectation.fulfill()
    }

    pipeline.emitMicrophoneLevel(MicrophoneLevelSample(linear: 0.27, dbfs: -11.4))

    wait(for: [expectation], timeout: 1.0)
    let forwarded = try XCTUnwrap(received)
    XCTAssertEqual(forwarded.linear, 0.27, accuracy: 0.0001)
    XCTAssertEqual(forwarded.dbfs, -11.4, accuracy: 0.0001)
  }

  func testRecordingStartDoesNotForceZeroMicSample() {
    let micMonitor = MockMicrophoneLevelMonitor()
    let facade = ScreenRecorderFacade(micLevelMonitor: micMonitor)
    let backend = MockCaptureBackend()
    facade._testSetCaptureBackend(backend)
    facade._testSetAudioDeviceId("mic-1")
    facade._testRefreshMicrophoneLevelMonitoring(resetMeter: false)

    var received: [MicrophoneLevelSample] = []
    facade.onMicrophoneLevel = { sample in
      received.append(sample)
    }

    micMonitor.emit(MicrophoneLevelSample(linear: 0.19, dbfs: -26.0))
    let stopCountBeforeStart = micMonitor.stopEmitZeroValues.count
    backend.onStarted?(URL(fileURLWithPath: "/tmp/recording.mov"))

    let settleStartTransition = expectation(description: "recording start settle")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      settleStartTransition.fulfill()
    }
    wait(for: [settleStartTransition], timeout: 1.0)

    XCTAssertEqual(received.count, 1)
    XCTAssertEqual(received[0].linear, 0.19, accuracy: 0.0001)
    XCTAssertEqual(micMonitor.stopEmitZeroValues.count, stopCountBeforeStart)
  }

  func testBackendMicrophoneTelemetryStillReachesFacadeAfterRecordingStarts() throws {
    let facade = ScreenRecorderFacade()
    let backend = MockCaptureBackend()
    facade._testSetCaptureBackend(backend)

    let settleInitialAsync = expectation(description: "initial async settle")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      settleInitialAsync.fulfill()
    }
    wait(for: [settleInitialAsync], timeout: 1.0)

    let forwarded = expectation(description: "backend microphone sample forwarded")
    var received: MicrophoneLevelSample?
    facade.onMicrophoneLevel = { sample in
      received = sample
      forwarded.fulfill()
    }

    backend.onStarted?(URL(fileURLWithPath: "/tmp/recording.mov"))
    backend.onMicrophoneLevel?(MicrophoneLevelSample(linear: 0.41, dbfs: -17.8))

    wait(for: [forwarded], timeout: 1.0)
    let forwardedSample = try XCTUnwrap(received)
    XCTAssertEqual(forwardedSample.linear, 0.41, accuracy: 0.0001)
    XCTAssertEqual(forwardedSample.dbfs, -17.8, accuracy: 0.0001)
  }

  func testBackendSilenceTelemetryStillReachesFacadeDuringRecording() throws {
    let facade = ScreenRecorderFacade()
    let backend = MockCaptureBackend()
    facade._testSetCaptureBackend(backend)

    let settleInitialAsync = expectation(description: "initial async settle")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      settleInitialAsync.fulfill()
    }
    wait(for: [settleInitialAsync], timeout: 1.0)

    let forwarded = expectation(description: "backend silence sample forwarded")
    var received: MicrophoneLevelSample?
    facade.onMicrophoneLevel = { sample in
      received = sample
      forwarded.fulfill()
    }

    backend.onStarted?(URL(fileURLWithPath: "/tmp/recording.mov"))
    backend.onMicrophoneLevel?(MicrophoneLevelSample(linear: 0.0, dbfs: -160.0))

    wait(for: [forwarded], timeout: 1.0)
    let forwardedSample = try XCTUnwrap(received)
    XCTAssertEqual(forwardedSample.linear, 0.0, accuracy: 0.0001)
    XCTAssertEqual(forwardedSample.dbfs, -160.0, accuracy: 0.0001)
  }

  func testMicMonitorFallbackRemainsLiveUntilRecordingTelemetryTakesOver() {
    let micMonitor = MockMicrophoneLevelMonitor()
    let facade = ScreenRecorderFacade(micLevelMonitor: micMonitor)
    let backend = MockCaptureBackend()
    facade._testSetCaptureBackend(backend)
    facade._testSetAudioDeviceId("mic-1")
    facade._testRefreshMicrophoneLevelMonitoring(resetMeter: false)

    var received: [Double] = []
    facade.onMicrophoneLevel = { sample in
      received.append(sample.linear)
    }

    backend.onStarted?(URL(fileURLWithPath: "/tmp/recording.mov"))
    micMonitor.emit(MicrophoneLevelSample(linear: 0.22, dbfs: -24.0))
    backend.onMicrophoneLevel?(MicrophoneLevelSample(linear: 0.48, dbfs: -12.0))
    micMonitor.emit(MicrophoneLevelSample(linear: 0.31, dbfs: -18.0))

    XCTAssertGreaterThanOrEqual(micMonitor.startDeviceIDs.count, 2)
    XCTAssertEqual(micMonitor.startDeviceIDs.last!, "mic-1")
    XCTAssertTrue(micMonitor.stopEmitZeroValues.contains(false))
    XCTAssertEqual(received.count, 2)
    XCTAssertEqual(received[0], 0.22, accuracy: 0.0001)
    XCTAssertEqual(received[1], 0.48, accuracy: 0.0001)
  }
}

@MainActor
final class ScreenRecorderFacadeSeparateCameraTests: XCTestCase {
  func testFinishMetadataPublishesFinalCameraBasename() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let projectRoot = try makeRecordingProjectRoot(at: tempDir, includeCamera: true)
    let publishedScreenURL = RecordingProjectPaths.screenVideoURL(for: projectRoot)
    let metadataURL = RecordingProjectPaths.screenMetadataURL(for: projectRoot)

    let initialMetadata = RecordingMetadata.create(
      screenRawRelativePath: RecordingProjectPaths.relativeScreenVideoPath,
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
        rawRelativePath: RecordingProjectPaths.relativeCameraRawPath,
        metadataRelativePath: RecordingProjectPaths.relativeCameraMetadataPath,
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
      rawURL: RecordingProjectPaths.cameraRawURL(for: projectRoot),
      metadataURL: RecordingProjectPaths.cameraMetadataURL(for: projectRoot),
      metadata: CameraRecordingMetadata(
        version: 1,
        recordingId: "camera-recording-id",
        rawRelativePath: RecordingProjectPaths.relativeCameraRawPath,
        metadataRelativePath: RecordingProjectPaths.relativeCameraMetadataPath,
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
      projectRoot: projectRoot,
      cameraResult: cameraResult,
      publishedScreenURL: publishedScreenURL
    )

    let updated = try RecordingMetadata.read(from: metadataURL)
    XCTAssertEqual(updated.camera?.rawRelativePath, "camera/raw.mov")
    XCTAssertEqual(updated.camera?.metadataRelativePath, "camera/meta.json")
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

    let projectRoot = try makeRecordingProjectRoot(at: tempDir, includeCamera: true)
    let screenURL = RecordingProjectPaths.screenVideoURL(for: projectRoot)
    let cameraURL = RecordingProjectPaths.cameraRawURL(for: projectRoot)
    try Data("screen".utf8).write(to: screenURL)
    try Data("camera".utf8).write(to: cameraURL)

    let metadata = RecordingMetadata.create(
      screenRawRelativePath: RecordingProjectPaths.relativeScreenVideoPath,
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
        rawRelativePath: RecordingProjectPaths.relativeCameraRawPath,
        metadataRelativePath: RecordingProjectPaths.relativeCameraMetadataPath,
        deviceId: "camera-1",
        mirroredRaw: true,
        nominalFrameRate: 30,
        dimensions: .init(width: 1920, height: 1080),
        segments: []
      ),
      editorSeed: makeEditorSeed()
    )
    try metadata.write(to: RecordingProjectPaths.screenMetadataURL(for: projectRoot))

    let facade = ScreenRecorderFacade()
    let mediaSources = try XCTUnwrap(
      facade.resolvePreviewMediaSources(projectPath: projectRoot.path)
    )

    XCTAssertEqual(mediaSources.cameraPath, cameraURL.path)
  }

  func testResolvePreviewMediaSourcesFallsBackWhenMetadataPointsToMissingInProgressCamera() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let projectRoot = try makeRecordingProjectRoot(at: tempDir, includeCamera: true)
    let screenURL = RecordingProjectPaths.screenVideoURL(for: projectRoot)
    try Data("screen".utf8).write(to: screenURL)

    let metadata = RecordingMetadata.create(
      screenRawRelativePath: RecordingProjectPaths.relativeScreenVideoPath,
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
        rawRelativePath: "camera/missing.mov",
        metadataRelativePath: "camera/missing.meta.json",
        deviceId: "camera-1",
        mirroredRaw: true,
        nominalFrameRate: 30,
        dimensions: .init(width: 1920, height: 1080),
        segments: []
      ),
      editorSeed: makeEditorSeed()
    )
    try metadata.write(to: RecordingProjectPaths.screenMetadataURL(for: projectRoot))

    let facade = ScreenRecorderFacade()
    let mediaSources = try XCTUnwrap(
      facade.resolvePreviewMediaSources(projectPath: projectRoot.path)
    )

    XCTAssertNil(mediaSources.cameraPath)
  }

  func testResolvePreviewSceneIncludesTwoSourceMediaAndCameraParams() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let projectRoot = try makeRecordingProjectRoot(at: tempDir, includeCamera: true)
    let screenURL = RecordingProjectPaths.screenVideoURL(for: projectRoot)
    let cameraURL = RecordingProjectPaths.cameraRawURL(for: projectRoot)
    try Data("screen".utf8).write(to: screenURL)
    try Data("camera".utf8).write(to: cameraURL)

    let metadata = RecordingMetadata.create(
      screenRawRelativePath: RecordingProjectPaths.relativeScreenVideoPath,
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
        rawRelativePath: RecordingProjectPaths.relativeCameraRawPath,
        metadataRelativePath: RecordingProjectPaths.relativeCameraMetadataPath,
        deviceId: "camera-1",
        mirroredRaw: true,
        nominalFrameRate: 30,
        dimensions: .init(width: 1920, height: 1080),
        segments: []
      ),
      editorSeed: makeEditorSeed()
    )
    try metadata.write(to: RecordingProjectPaths.screenMetadataURL(for: projectRoot))

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
    try metadata.write(to: RecordingProjectPaths.screenMetadataURL(for: projectRoot))
    let scene = try XCTUnwrap(
      facade.resolvePreviewScene(projectPath: projectRoot.path, screenParams: params)
    )

    XCTAssertEqual(scene.mediaSources.screenPath, screenURL.path)
    XCTAssertEqual(scene.mediaSources.cameraPath, cameraURL.path)
    XCTAssertEqual(scene.cameraParams?.layoutPreset, .overlayBottomRight)
  }

  func testResolvePreviewMediaSourcesReturnsNilForInvalidProjectPath() {
    let facade = ScreenRecorderFacade()
    let mediaSources = facade.resolvePreviewMediaSources(projectPath: "/tmp/not-a-project.mov")
    XCTAssertNil(mediaSources)
  }

  func testGetRecordingSceneInfoFailsForInvalidProjectPath() throws {
    let facade = ScreenRecorderFacade()
    var returnedValue: Any?

    facade.getRecordingSceneInfo(projectPath: "/tmp/not-a-project.mov") { value in
      returnedValue = value
    }

    let error = try XCTUnwrap(returnedValue as? FlutterError)
    XCTAssertEqual(error.code, "SCENE_INPUT_MISSING")
  }

  func testRecordingSceneInfoExposesFeatureLevelCameraExportCapabilities() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let projectRoot = try makeRecordingProjectRoot(at: tempDir, includeCamera: true)
    let screenURL = RecordingProjectPaths.screenVideoURL(for: projectRoot)
    let cameraURL = RecordingProjectPaths.cameraRawURL(for: projectRoot)
    try Data("screen".utf8).write(to: screenURL)
    try Data("camera".utf8).write(to: cameraURL)

    let metadata = RecordingMetadata.create(
      screenRawRelativePath: RecordingProjectPaths.relativeScreenVideoPath,
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
        rawRelativePath: RecordingProjectPaths.relativeCameraRawPath,
        metadataRelativePath: RecordingProjectPaths.relativeCameraMetadataPath,
        deviceId: "camera-1",
        mirroredRaw: true,
        nominalFrameRate: 30,
        dimensions: .init(width: 1920, height: 1080),
        segments: []
      ),
      editorSeed: makeEditorSeed()
    )
    try metadata.write(to: RecordingProjectPaths.screenMetadataURL(for: projectRoot))

    let facade = ScreenRecorderFacade()
    var scenePayload: Any?
    facade.getRecordingSceneInfo(projectPath: projectRoot.path) { value in
      scenePayload = value
    }

    let payload = try XCTUnwrap(scenePayload as? [String: Any])
    XCTAssertEqual(payload["projectPath"] as? String, projectRoot.path)
    XCTAssertEqual(payload["screenPath"] as? String, screenURL.path)
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
      projectPath: "/tmp/recording.clingfyproj",
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
      projectPath: "/tmp/recording.clingfyproj",
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

  func testResolveTargetSizeHonorsLayoutAspectForAutoResolution() {
    let facade = ScreenRecorderFacade()
    let sourceSize = CGSize(width: 3024, height: 1964)

    let classic = facade._testResolveTargetSize(
      sourceSize: sourceSize,
      layout: "classic43",
      resolution: "auto"
    )
    XCTAssertEqual(classic.width, 3024, accuracy: 0.0001)
    XCTAssertEqual(classic.height, 2268, accuracy: 0.0001)

    let square = facade._testResolveTargetSize(
      sourceSize: sourceSize,
      layout: "square11",
      resolution: "auto"
    )
    XCTAssertEqual(square.width, 3024, accuracy: 0.0001)
    XCTAssertEqual(square.height, 3024, accuracy: 0.0001)

    let vertical = facade._testResolveTargetSize(
      sourceSize: sourceSize,
      layout: "reel916",
      resolution: "auto"
    )
    XCTAssertEqual(vertical.width, 3024, accuracy: 0.0001)
    XCTAssertEqual(vertical.height, 5376, accuracy: 0.0001)

    let wide = facade._testResolveTargetSize(
      sourceSize: sourceSize,
      layout: "youtube169",
      resolution: "auto"
    )
    XCTAssertEqual(wide.width, 1964 * (16.0 / 9.0), accuracy: 0.0001)
    XCTAssertEqual(wide.height, 1964, accuracy: 0.0001)

    let original = facade._testResolveTargetSize(
      sourceSize: sourceSize,
      layout: "auto",
      resolution: "auto"
    )
    XCTAssertEqual(original.width, sourceSize.width, accuracy: 0.0001)
    XCTAssertEqual(original.height, sourceSize.height, accuracy: 0.0001)
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

  private func makeRecordingProjectRoot(at parent: URL, includeCamera: Bool) throws -> URL {
    let projectRoot = parent.appendingPathComponent(
      RecordingProjectPaths.projectDirectoryName(for: "recording"),
      isDirectory: true
    )
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: RecordingProjectPaths.captureDirectoryURL(for: projectRoot),
      withIntermediateDirectories: true
    )
    try fileManager.createDirectory(
      at: RecordingProjectPaths.postDirectoryURL(for: projectRoot),
      withIntermediateDirectories: true
    )
    try fileManager.createDirectory(
      at: RecordingProjectPaths.derivedDirectoryURL(for: projectRoot),
      withIntermediateDirectories: true
    )
    if includeCamera {
      try fileManager.createDirectory(
        at: RecordingProjectPaths.cameraSegmentsDirectoryURL(for: projectRoot),
        withIntermediateDirectories: true
      )
    }

    let manifest = RecordingProjectManifest.create(
      projectId: "recording",
      displayName: "Recording",
      includeCamera: includeCamera
    )
    try manifest.write(to: RecordingProjectPaths.manifestURL(for: projectRoot))
    return projectRoot
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
