import Foundation

/// Typed boundary DTO for the `processVideo` (preview scene update)
/// method-channel arguments.
///
/// `fromFlutter` reproduces *exactly* the inline parsing currently in
/// `MainFlutterWindow`'s `processVideo` case (same keys, same defaults,
/// including the zoom-effect derivation contract and the
/// `cameraPreviewChangeKind` enum fallback). Returns nil when `projectPath`
/// is absent — mirroring the caller's `guard let projectPath` that yields a
/// `badArgs` error. Introduced additively in Commit 2; not yet rewired, so
/// behavior is unchanged. `cameraParams` and `zoomSegments` stay resolved by
/// their existing helpers and are intentionally out of this DTO.
struct PreviewSceneRequest: Equatable {
  let projectPath: String
  let layout: String
  let resolution: String
  let fit: String
  let padding: Double
  let cornerRadius: Double
  let backgroundColor: Int?
  let backgroundImagePath: String?
  let cursorSize: Double
  let rawZoomFactor: Double
  let zoomEffectEnabled: Bool
  let showCursor: Bool
  let cameraPreviewChangeKind: CameraPreviewChangeKind
  let format: String
  let codec: String
  let bitrate: String
  let audioGainDb: Double
  let audioVolumePercent: Double
  let sessionId: String?
  let cameraPath: String?

  /// The effective zoom factor after applying the legacy/explicit enable contract.
  var zoomFactor: Double { zoomEffectEnabled ? rawZoomFactor : 1.0 }

  static func fromFlutter(_ args: [String: Any]?) -> PreviewSceneRequest? {
    guard let args, let projectPath = args["projectPath"] as? String else { return nil }
    let rawZoomFactor = (args["zoomFactor"] as? Double) ?? 1.5
    let kind =
      CameraPreviewChangeKind(
        rawValue: (args["cameraPreviewChangeKind"] as? String)
          ?? CameraPreviewChangeKind.none.rawValue
      ) ?? .none
    return PreviewSceneRequest(
      projectPath: projectPath,
      layout: (args["layoutPreset"] as? String) ?? "auto",
      resolution: (args["resolutionPreset"] as? String) ?? "auto",
      fit: (args["fitMode"] as? String) ?? "fit",
      padding: (args["padding"] as? Double) ?? 0.0,
      cornerRadius: (args["cornerRadius"] as? Double) ?? 0.0,
      backgroundColor: args["backgroundColor"] as? Int,
      backgroundImagePath: args["backgroundImagePath"] as? String,
      cursorSize: (args["cursorSize"] as? Double) ?? 1.0,
      rawZoomFactor: rawZoomFactor,
      zoomEffectEnabled: (args["zoomEffectEnabled"] as? Bool) ?? (rawZoomFactor > 1.0),
      showCursor: (args["showCursor"] as? Bool) ?? true,
      cameraPreviewChangeKind: kind,
      format: (args["format"] as? String) ?? "mov",
      codec: (args["codec"] as? String) ?? "hevc",
      bitrate: (args["bitrate"] as? String) ?? "auto",
      audioGainDb: (args["audioGainDb"] as? Double) ?? 0.0,
      audioVolumePercent: (args["audioVolumePercent"] as? Double) ?? 100.0,
      sessionId: args["sessionId"] as? String,
      cameraPath: args["cameraPath"] as? String
    )
  }
}
