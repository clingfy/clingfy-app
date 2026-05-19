import Foundation

/// Typed boundary DTO for the `exportVideo` method-channel arguments.
///
/// `fromFlutter` reproduces *exactly* the inline parsing currently in
/// `MainFlutterWindow`'s `exportVideo` case (same keys, same defaults, same
/// nil-handling, including the zoom-effect derivation contract). Returns nil
/// when `projectPath` is absent — mirroring the caller's `guard let
/// projectPath` that yields a `badArgs` error. Introduced additively in
/// Commit 2; not yet rewired, so behavior is unchanged. `cameraParams` and
/// `zoomSegments` stay resolved by their existing helpers (they are derived,
/// not raw `args[...]` reads) and are intentionally out of this DTO.
struct ExportVideoRequest: Equatable {
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
  let filename: String?
  let directoryOverride: String?
  let format: String
  let codec: String
  let bitrate: String
  let audioGainDb: Double
  let audioVolumePercent: Double
  let autoNormalizeOnExport: Bool
  let targetLoudnessDbfs: Double
  let cameraPath: String?

  /// The effective zoom factor after applying the legacy/explicit enable contract.
  var zoomFactor: Double { zoomEffectEnabled ? rawZoomFactor : 1.0 }

  static func fromFlutter(_ args: [String: Any]?) -> ExportVideoRequest? {
    guard let args, let projectPath = args["projectPath"] as? String else { return nil }
    let rawZoomFactor = (args["zoomFactor"] as? Double) ?? 1.5
    return ExportVideoRequest(
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
      filename: args["filename"] as? String,
      directoryOverride: args["directoryOverride"] as? String,
      format: (args["format"] as? String) ?? "mov",
      codec: (args["codec"] as? String) ?? "hevc",
      bitrate: (args["bitrate"] as? String) ?? "auto",
      audioGainDb: (args["audioGainDb"] as? Double) ?? 0.0,
      audioVolumePercent: (args["audioVolumePercent"] as? Double) ?? 100.0,
      autoNormalizeOnExport: (args["autoNormalizeOnExport"] as? Bool) ?? false,
      targetLoudnessDbfs: (args["targetLoudnessDbfs"] as? Double) ?? -16.0,
      cameraPath: args["cameraPath"] as? String
    )
  }
}
