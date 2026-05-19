import AVFoundation
import FlutterMacOS
import Foundation

/// Preview media-source / scene / camera-composition resolution, extracted out
/// of the ScreenRecorderFacade body (Slice 2 / PR 9 of the strangler refactor).
///
/// Implemented as an `extension ScreenRecorderFacade` (the
/// ScreenRecorderFacade+Permissions pattern) — no new stored state. The
/// externally-called methods (resolvePreviewMediaSources, resolvePreviewScene,
/// resolveCameraCompositionParams, getRecordingSceneInfo) keep internal access
/// so the dispatcher / MainFlutterWindow / processVideo call sites are
/// unchanged; the private helpers move with them (all their callers are in
/// this unit). `processVideo` itself is NOT moved (stays in the facade). Pure
/// relocation, behavior identical. Engine-domain (future video-editing engine
/// core — see windows-port-inventory §7).
extension ScreenRecorderFacade {
  private func loadRecordingMetadata(projectRef: RecordingProjectRef) -> RecordingMetadata? {
    guard let metadataURL = projectRef.mediaSources().metadataURL else {
      return nil
    }

    do {
      return try RecordingMetadata.read(from: metadataURL)
    } catch {
      NativeLogger.w(
        "Scene",
        "Failed to load recording metadata",
        context: ["path": metadataURL.path, "error": error.localizedDescription]
      )
      return nil
    }
  }

  private func loadCameraRecordingMetadata(projectRef: RecordingProjectRef) -> CameraRecordingMetadata? {
    guard let metadataURL = projectRef.mediaSources().cameraMetadataURL else {
      return nil
    }

    do {
      let data = try Data(contentsOf: metadataURL)
      return try JSONDecoder().decode(CameraRecordingMetadata.self, from: data)
    } catch {
      NativeLogger.w(
        "Scene",
        "Failed to load camera recording metadata",
        context: ["path": metadataURL.path, "error": error.localizedDescription]
      )
      return nil
    }
  }

  private func resolvedCameraAssetURL(
    projectRef: RecordingProjectRef,
    explicitCameraPath: String?
  ) -> URL? {
    if let explicitCameraPath, !explicitCameraPath.isEmpty {
      let explicitURL = URL(fileURLWithPath: explicitCameraPath)
      guard FileManager.default.fileExists(atPath: explicitURL.path) else {
        NativeLogger.w(
          "Scene",
          "Explicit camera asset is missing; falling back to metadata resolution",
          context: ["path": explicitURL.path]
        )
        return nil
      }
      return explicitURL
    }

    return projectRef.mediaSources().cameraVideoURL
  }

  private func cameraCompositionParams(from editorSeed: RecordingMetadata.EditorSeed) -> CameraCompositionParams {
    CameraCompositionParams(
      visible: editorSeed.cameraVisible,
      layoutPreset: editorSeed.cameraLayoutPreset,
      normalizedCanvasCenter: editorSeed.cameraNormalizedCenter.map {
        CGPoint(x: $0.x, y: $0.y)
      },
      sizeFactor: editorSeed.cameraSizeFactor,
      shape: editorSeed.cameraShape,
      cornerRadius: editorSeed.cameraCornerRadius,
      opacity: editorSeed.cameraOpacity,
      mirror: editorSeed.cameraMirror,
      contentMode: editorSeed.cameraContentMode,
      zoomBehavior: editorSeed.cameraZoomBehavior,
      zoomScaleMultiplier: editorSeed.cameraZoomScaleMultiplier,
      introPreset: editorSeed.cameraIntroPreset,
      outroPreset: editorSeed.cameraOutroPreset,
      zoomEmphasisPreset: editorSeed.cameraZoomEmphasisPreset,
      introDurationMs: editorSeed.cameraIntroDurationMs,
      outroDurationMs: editorSeed.cameraOutroDurationMs,
      zoomEmphasisStrength: editorSeed.cameraZoomEmphasisStrength,
      borderWidth: editorSeed.cameraBorderWidth,
      borderColorArgb: editorSeed.cameraBorderColorArgb,
      shadowPreset: editorSeed.cameraShadow,
      chromaKeyEnabled: editorSeed.cameraChromaKeyEnabled,
      chromaKeyStrength: editorSeed.cameraChromaKeyStrength,
      chromaKeyColorArgb: editorSeed.cameraChromaKeyColorArgb
    )
  }

  private func cameraCompositionParamsMap(_ params: CameraCompositionParams) -> [String: Any] {
    var map: [String: Any] = [
      "visible": params.visible,
      "layoutPreset": params.layoutPreset.rawValue,
      "sizeFactor": params.sizeFactor,
      "shape": params.shape.rawValue,
      "cornerRadius": params.cornerRadius,
      "opacity": params.opacity,
      "mirror": params.mirror,
      "contentMode": params.contentMode.rawValue,
      "zoomBehavior": params.zoomBehavior.rawValue,
      "zoomScaleMultiplier": params.zoomScaleMultiplier,
      "introPreset": params.introPreset.rawValue,
      "outroPreset": params.outroPreset.rawValue,
      "zoomEmphasisPreset": params.zoomEmphasisPreset.rawValue,
      "introDurationMs": params.introDurationMs,
      "outroDurationMs": params.outroDurationMs,
      "zoomEmphasisStrength": params.zoomEmphasisStrength,
      "borderWidth": params.borderWidth,
      "shadowPreset": params.shadowPreset,
      "chromaKeyEnabled": params.chromaKeyEnabled,
      "chromaKeyStrength": params.chromaKeyStrength,
    ]

    if let normalizedCanvasCenter = params.normalizedCanvasCenter {
      map["normalizedCanvasCenter"] = [
        "x": normalizedCanvasCenter.x,
        "y": normalizedCanvasCenter.y,
      ]
    }
    if let borderColorArgb = params.borderColorArgb {
      map["borderColorArgb"] = borderColorArgb
    }
    if let chromaKeyColorArgb = params.chromaKeyColorArgb {
      map["chromaKeyColorArgb"] = chromaKeyColorArgb
    }

    return map
  }

  private func anyCameraParamOverride(in args: [String: Any]) -> Bool {
    args.keys.contains { $0.hasPrefix("camera") }
  }

  private func doubleValue(_ value: Any?) -> Double? {
    if let number = value as? Double { return number }
    if let number = value as? NSNumber { return number.doubleValue }
    if let string = value as? String { return Double(string) }
    return nil
  }

  private func boolValue(_ value: Any?) -> Bool? {
    if let bool = value as? Bool { return bool }
    if let number = value as? NSNumber { return number.boolValue }
    if let string = value as? String {
      switch string.lowercased() {
      case "true", "1", "yes": return true
      case "false", "0", "no": return false
      default: return nil
      }
    }
    return nil
  }

  private func explicitCameraCompositionParams(
    from args: [String: Any],
    fallback: CameraCompositionParams?
  ) -> CameraCompositionParams? {
    guard anyCameraParamOverride(in: args) else { return fallback }

    var params = fallback ?? .hidden

    if let visible = boolValue(args["cameraVisible"]) {
      params.visible = visible
    }
    if let rawPreset = args["cameraLayoutPreset"] as? String,
      let preset = CameraLayoutPreset(rawValue: rawPreset)
    {
      params.layoutPreset = preset
    }
    if let rawShape = args["cameraShape"] as? String,
      let shape = CameraShape(rawValue: rawShape)
    {
      params.shape = shape
    }
    if let rawContentMode = args["cameraContentMode"] as? String,
      let contentMode = CameraContentMode(rawValue: rawContentMode)
    {
      params.contentMode = contentMode
    }
    if let rawZoomBehavior = args["cameraZoomBehavior"] as? String {
      params.zoomBehavior = CameraZoomBehavior.from(rawValue: rawZoomBehavior)
    }
    if let zoomScaleMultiplier = doubleValue(args["cameraZoomScaleMultiplier"]) {
      params.zoomScaleMultiplier = min(max(zoomScaleMultiplier, 0.0), 1.0)
    }
    if let rawIntroPreset = args["cameraIntroPreset"] as? String {
      params.introPreset = CameraIntroPreset.from(rawValue: rawIntroPreset)
    }
    if let rawOutroPreset = args["cameraOutroPreset"] as? String {
      params.outroPreset = CameraOutroPreset.from(rawValue: rawOutroPreset)
    }
    if let rawZoomEmphasisPreset = args["cameraZoomEmphasisPreset"] as? String {
      params.zoomEmphasisPreset = CameraZoomEmphasisPreset.from(rawValue: rawZoomEmphasisPreset)
    }
    if let introDurationMs = args["cameraIntroDurationMs"] as? Int {
      params.introDurationMs = min(max(introDurationMs, 80), 600)
    } else if let introDurationMs = doubleValue(args["cameraIntroDurationMs"]) {
      params.introDurationMs = min(max(Int(introDurationMs.rounded()), 80), 600)
    }
    if let outroDurationMs = args["cameraOutroDurationMs"] as? Int {
      params.outroDurationMs = min(max(outroDurationMs, 80), 600)
    } else if let outroDurationMs = doubleValue(args["cameraOutroDurationMs"]) {
      params.outroDurationMs = min(max(Int(outroDurationMs.rounded()), 80), 600)
    }
    if let zoomEmphasisStrength = doubleValue(args["cameraZoomEmphasisStrength"]) {
      params.zoomEmphasisStrength = min(max(zoomEmphasisStrength, 0.0), 0.2)
    }
    if let sizeFactor = doubleValue(args["cameraSizeFactor"]) {
      params.sizeFactor = sizeFactor
    }
    if let cornerRadius = doubleValue(args["cameraCornerRadius"]) {
      params.cornerRadius = cornerRadius
    }
    if let opacity = doubleValue(args["cameraOpacity"]) {
      params.opacity = opacity
    }
    if let mirror = boolValue(args["cameraMirror"]) {
      params.mirror = mirror
    }
    if let borderWidth = doubleValue(args["cameraBorderWidth"]) {
      params.borderWidth = borderWidth
    }
    if let borderColorArgb = args["cameraBorderColorArgb"] as? Int {
      params.borderColorArgb = borderColorArgb
    }
    if let shadowPreset = args["cameraShadowPreset"] as? Int {
      params.shadowPreset = shadowPreset
    }
    if let chromaKeyEnabled = boolValue(args["cameraChromaKeyEnabled"]) {
      params.chromaKeyEnabled = chromaKeyEnabled
    }
    if let chromaKeyStrength = doubleValue(args["cameraChromaKeyStrength"]) {
      params.chromaKeyStrength = chromaKeyStrength
    }
    if let chromaKeyColorArgb = args["cameraChromaKeyColorArgb"] as? Int {
      params.chromaKeyColorArgb = chromaKeyColorArgb
    }
    if let center = args["cameraNormalizedCenter"] as? [String: Any],
      let x = doubleValue(center["x"]),
      let y = doubleValue(center["y"])
    {
      params.normalizedCanvasCenter = CGPoint(x: x, y: y)
    } else if args.keys.contains("cameraNormalizedCenter") {
      params.normalizedCanvasCenter = nil
    }

    return params
  }

  func resolvePreviewMediaSources(
    projectPath: String,
    explicitCameraPath: String? = nil
  ) -> PreviewMediaSources? {
    guard let projectRef = loadRecordingProject(projectPath: projectPath) else {
      return nil
    }
    let mediaSources = projectRef.mediaSources()
    let resolvedCameraURL = resolvedCameraAssetURL(
      projectRef: projectRef,
      explicitCameraPath: explicitCameraPath
    )
    let recordingMetadata = loadRecordingMetadata(projectRef: projectRef)
    let cameraMetadata = loadCameraRecordingMetadata(projectRef: projectRef)
    let cameraSyncTimeline = CameraSyncTimelineResolver.resolve(
      recordingMetadata: recordingMetadata,
      cameraMetadata: cameraMetadata,
      screenAsset: AVAsset(url: URL(fileURLWithPath: mediaSources.screenPath)),
      cameraAsset: resolvedCameraURL.map(AVAsset.init(url:)),
      logContext: [
        "context": "preview",
        "projectPath": projectPath,
      ]
    )

    NativeLogger.d(
      "Scene",
      "Resolved preview media sources",
      context: [
        "projectPath": projectPath,
        "screenPath": mediaSources.screenPath,
        "cameraPath": resolvedCameraURL?.path ?? "nil",
        "metadataPath": mediaSources.metadataPath ?? "nil",
        "cursorPath": mediaSources.cursorPath ?? "nil",
        "zoomManualPath": mediaSources.zoomManualPath ?? "nil",
        "cameraSyncSegments": cameraSyncTimeline?.segments.count ?? 0,
      ]
    )

    return PreviewMediaSources(
      projectPath: projectPath,
      screenPath: mediaSources.screenPath,
      cameraPath: resolvedCameraURL?.path,
      metadataPath: mediaSources.metadataPath,
      cursorPath: mediaSources.cursorPath,
      zoomManualPath: mediaSources.zoomManualPath,
      cameraSyncTimeline: cameraSyncTimeline
    )
  }

  private func resolvePreviewSceneComponents(
    projectPath: String,
    explicitCameraPath: String? = nil,
    args: [String: Any]? = nil
  ) -> (mediaSources: PreviewMediaSources, cameraParams: CameraCompositionParams?)? {
    guard let mediaSources = resolvePreviewMediaSources(
      projectPath: projectPath,
      explicitCameraPath: explicitCameraPath
    ) else {
      return nil
    }
    let cameraParams = resolveCameraCompositionParams(
      projectPath: projectPath,
      args: args
    )
    return (mediaSources, cameraParams)
  }

  func resolvePreviewScene(
    projectPath: String,
    screenParams: CompositionParams,
    explicitCameraPath: String? = nil,
    args: [String: Any]? = nil
  ) -> PreviewScene? {
    guard let components = resolvePreviewSceneComponents(
      projectPath: projectPath,
      explicitCameraPath: explicitCameraPath,
      args: args
    ) else {
      return nil
    }

    return PreviewScene(
      mediaSources: components.mediaSources,
      screenParams: screenParams,
      cameraParams: components.cameraParams
    )
  }

  private struct CameraExportCapabilitySet {
    let shapeMask: Bool
    let cornerRadius: Bool
    let border: Bool
    let shadow: Bool
    let chromaKey: Bool

    var payload: [String: Bool] {
      [
        "shapeMask": shapeMask,
        "cornerRadius": cornerRadius,
        "border": border,
        "shadow": shadow,
        "chromaKey": chromaKey,
      ]
    }
  }

  private func cameraExportCapabilities(for mediaSources: PreviewMediaSources) -> CameraExportCapabilitySet {
    guard mediaSources.cameraPath?.isEmpty == false else {
      return CameraExportCapabilitySet(
        shapeMask: true,
        cornerRadius: true,
        border: true,
        shadow: true,
        chromaKey: true
      )
    }

    return CameraExportCapabilitySet(
      shapeMask: true,
      cornerRadius: true,
      border: true,
      shadow: true,
      chromaKey: true
    )
  }

  func resolveCameraCompositionParams(
    projectPath: String,
    args: [String: Any]? = nil
  ) -> CameraCompositionParams? {
    let metadata = loadRecordingProject(projectPath: projectPath).flatMap { projectRef in
      loadRecordingMetadata(projectRef: projectRef)
    }
    let seededParams = metadata.map { cameraCompositionParams(from: $0.editorSeed) }
    let resolved = explicitCameraCompositionParams(from: args ?? [:], fallback: seededParams)
    var context: [String: Any] = [
      "projectPath": projectPath,
      "hasSeed": seededParams != nil,
      "hasExplicitArgs": args.map(anyCameraParamOverride(in:)) ?? false,
      "cameraPreviewChangeKind":
        (args?["cameraPreviewChangeKind"] as? String) ?? CameraPreviewChangeKind.none.rawValue,
      "visible": resolved?.visible ?? false,
      "layoutPreset": resolved?.layoutPreset.rawValue ?? "nil",
    ]
    if let center = resolved?.normalizedCanvasCenter {
      context["normalizedCenterX"] = center.x
      context["normalizedCenterY"] = center.y
    }

    NativeLogger.d(
      "Scene",
      "Resolved camera composition params",
      context: context
    )

    return resolved
  }

  func getRecordingSceneInfo(projectPath: String, result: @escaping FlutterResult) {
    guard let components = resolvePreviewSceneComponents(projectPath: projectPath) else {
      result(
        FlutterError(
          code: "SCENE_INPUT_MISSING",
          message: "Recording project not found. It may have been moved or deleted.",
          details: projectPath
        )
      )
      return
    }
    let mediaSources = components.mediaSources
    let cameraParams = components.cameraParams
    let exportCapabilities = cameraExportCapabilities(for: mediaSources)

    var payload: [String: Any] = [
      "projectPath": mediaSources.projectPath,
      "screenPath": mediaSources.screenPath,
      "cameraExportCapabilities": exportCapabilities.payload,
    ]
    if let cameraPath = mediaSources.cameraPath {
      payload["cameraPath"] = cameraPath
    }
    if let metadataPath = mediaSources.metadataPath {
      payload["metadataPath"] = metadataPath
    }
    if let cameraParams {
      payload["camera"] = cameraCompositionParamsMap(cameraParams)
    }

    result(payload)
  }
}
