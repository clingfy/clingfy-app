import AVFoundation
import CoreGraphics
import FlutterMacOS
import Foundation

/// Slice 8 / PR 28: the Preview engine — runs the four preview-surface
/// methods that previously lived on `ScreenRecorderFacade` (processVideo,
/// previewSetCameraPlacement, previewSetAudioGainDb, previewSetAudioMix).
/// The engine owns no state; orchestration is parametrised on typed
/// inputs + dependencies + a small set of file-scope globals that already
/// live in `Preview/InlinePreviewViewFactory.swift`
/// (`inlinePreviewViewInstance`, `pendingPreviewOpenRequest`,
/// `updateActiveInlinePreviewScene`, `routePreviewSceneRequest`, etc.).
///
/// `getRecordingSceneInfo` is NOT moved here — it's already an extension
/// method on `ScreenRecorderFacade` defined in `PreviewSceneResolver.swift`
/// (Slice 1 / PR 9), so it's already out of the facade body file. A future
/// PR can relocate it once the resolver stops being a facade extension.
///
/// What this engine does:
///   - processVideo → resolve media sources → derive target size →
///     build CompositionParams → log → build PreviewScene → dispatch to
///     main and call the global update + route helpers.
///   - previewSetCameraPlacement → store override + forward to the live
///     view or guard against stale session ids.
///   - previewSetAudioGainDb → tiny wrapper around setAudioMix at
///     volumePercent = 100.
///   - previewSetAudioMix → clamp + store override + forward to the live
///     view or guard against stale session ids.
///
/// Engine-domain; see `windows-port-inventory.md` §7.
@MainActor
final class PreviewEngine {

  // MARK: - processVideo

  /// Inputs used by the scene-update flow. `format` / `codec` / `bitrate`
  /// are intentionally absent — they were dead parameters on the original
  /// facade `processVideo(...)` (received but never read). The facade
  /// keeps the public method's full signature for MainFlutterWindow
  /// compatibility and discards them when delegating here.
  struct ProcessVideoInput {
    let projectPath: String
    let layout: String
    let resolution: String
    let fit: String
    let padding: Double
    let cornerRadius: Double
    let backgroundColor: Int?
    let backgroundImagePath: String?
    let cursorSize: Double
    let zoomFactor: Double
    let showCursor: Bool
    let audioGainDb: Double
    let audioVolumePercent: Double
    let zoomSegments: [ZoomTimelineSegment]?
    let cameraPreviewChangeKind: CameraPreviewChangeKind
    let sessionId: String?
    let cameraPath: String?
    let cameraParams: CameraCompositionParams?
  }

  /// Facade-owned helpers the engine needs as closures. Both are currently
  /// `extension ScreenRecorderFacade` methods (PreviewSceneResolver +
  /// ExportPrep) — closures avoid forcing those extensions to move now.
  /// `defaultZoomFollowStrength` is a facade constant captured by value.
  struct ProcessVideoDependencies {
    let resolvePreviewMediaSources: (_ projectPath: String, _ explicitCameraPath: String?) -> PreviewMediaSources?
    let resolveTargetSize: (CGSize, String, String) -> CGSize
    let defaultZoomFollowStrength: CGFloat
  }

  func processVideo(
    input: ProcessVideoInput,
    dependencies: ProcessVideoDependencies,
    result: @escaping FlutterResult
  ) {
    guard
      let mediaSources = dependencies.resolvePreviewMediaSources(
        input.projectPath, input.cameraPath)
    else {
      result(
        FlutterError(
          code: "PROCESS_INPUT_MISSING",
          message: "Recording project not found. It may have been moved or deleted.",
          details: input.projectPath))
      return
    }
    let inputURL = URL(fileURLWithPath: mediaSources.screenPath)
    let asset = AVAsset(url: inputURL)

    func orientedSize(_ track: AVAssetTrack) -> CGSize {
      let rect = CGRect(origin: .zero, size: track.naturalSize)
        .applying(track.preferredTransform)
      return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    let srcSize: CGSize = {
      if let track = asset.tracks(withMediaType: .video).first {
        return orientedSize(track)
      }
      return CGSize(width: 1920, height: 1080)
    }()

    let targetSize = dependencies.resolveTargetSize(srcSize, input.layout, input.resolution)

    let clampedGainDb = max(0, min(24, input.audioGainDb))
    let clampedVolumePercent = max(0, min(100, input.audioVolumePercent))

    var params = CompositionParams(
      targetSize: targetSize,
      padding: input.padding,
      cornerRadius: input.cornerRadius,
      backgroundColor: input.backgroundColor,
      backgroundImagePath: input.backgroundImagePath,
      cursorSize: input.cursorSize,
      showCursor: input.showCursor,
      zoomEnabled: true,
      zoomFactor: CGFloat(input.zoomFactor),
      followStrength: dependencies.defaultZoomFollowStrength,
      fpsHint: 60,
      fitMode: input.fit,
      audioGainDb: clampedGainDb,
      audioVolumePercent: clampedVolumePercent
    )
    params.zoomSegments = input.zoomSegments

    NativeLogger.i(
      "Facade", "processVideo called (New Architecture)",
      context: [
        "projectPath": input.projectPath,
        "source": inputURL.path,
        "layout": input.layout,
        "resolution": input.resolution,
        "fit": input.fit,
        "targetSize": "\(targetSize.width)x\(targetSize.height)",
        "zoomSegments": input.zoomSegments.map { "\($0.count)" } ?? "nil",
        "cameraPreviewChangeKind": input.cameraPreviewChangeKind.rawValue,
        "cameraNormalizedCenterX": input.cameraParams?.normalizedCanvasCenter?.x ?? "nil",
        "cameraNormalizedCenterY": input.cameraParams?.normalizedCanvasCenter?.y ?? "nil",
      ])

    let previewScene = PreviewScene(
      mediaSources: mediaSources,
      screenParams: params,
      cameraParams: input.cameraParams,
      cameraPreviewChangeKind: input.cameraPreviewChangeKind
    )

    DispatchQueue.main.async {
      updateActiveInlinePreviewScene(
        sessionId: input.sessionId,
        scene: previewScene
      )
      let viewSessionId = inlinePreviewViewInstance?.currentSessionId
      let route = routePreviewSceneRequest(
        sessionId: input.sessionId,
        scene: previewScene
      )
      NativeLogger.d(
        "Preview", "Routed preview scene update",
        context: [
          "sessionId": input.sessionId ?? "nil",
          "viewSessionId": viewSessionId ?? "nil",
          "hasInlinePreviewView": inlinePreviewViewInstance != nil,
          "hasActivePreviewState": activeInlinePreviewState != nil,
          "route": route.rawValue,
        ])
    }
    result(input.projectPath)
  }

  // MARK: - previewSetCameraPlacement

  func setCameraPlacement(
    sessionId: String?,
    cameraPreviewChangeKind: CameraPreviewChangeKind,
    cameraParams: CameraCompositionParams?,
    result: @escaping FlutterResult
  ) {
    updateActiveInlinePreviewCameraPlacementOverride(
      sessionId: sessionId,
      cameraParams: cameraParams,
      changeKind: cameraPreviewChangeKind
    )
    if let view = inlinePreviewViewInstance {
      if let sessionId, view.currentSessionId != sessionId {
        result(nil)
        return
      }
      view.updateCameraPlacementPreview(
        cameraParams: cameraParams,
        changeKind: cameraPreviewChangeKind
      )
    } else if let sessionId,
      let request = pendingPreviewOpenRequest,
      request.sessionId != sessionId
    {
      result(nil)
      return
    }
    result(nil)
  }

  // MARK: - previewSetAudioGainDb / previewSetAudioMix

  func setAudioGainDb(audioGainDb: Double, result: @escaping FlutterResult) {
    setAudioMix(
      sessionId: nil,
      audioGainDb: audioGainDb,
      audioVolumePercent: 100.0,
      result: result
    )
  }

  func setAudioMix(
    sessionId: String?,
    audioGainDb: Double,
    audioVolumePercent: Double,
    result: @escaping FlutterResult
  ) {
    let clampedGainDb = max(0, min(24, audioGainDb))
    let clampedVolumePercent = max(0, min(100, audioVolumePercent))
    updateActiveInlinePreviewAudioMixOverride(
      sessionId: sessionId,
      gainDb: clampedGainDb,
      volumePercent: clampedVolumePercent
    )
    if let view = inlinePreviewViewInstance {
      if let sessionId, view.currentSessionId != sessionId {
        result(nil)
        return
      }
      view.updateAudioMixOnly(gainDb: clampedGainDb, volumePercent: clampedVolumePercent)
    } else if let sessionId,
      let request = pendingPreviewOpenRequest,
      request.sessionId != sessionId
    {
      result(nil)
      return
    }
    result(nil)
  }
}
