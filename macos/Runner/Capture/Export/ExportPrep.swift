import AVFoundation
import FlutterMacOS
import Foundation

/// Pure export/preview preparation helpers extracted out of the
/// ScreenRecorderFacade body (Slice 2 / PR 11 of the strangler refactor).
///
/// Only the genuinely stateless pieces are moved (an
/// `extension ScreenRecorderFacade` — no new stored state; methods stay on the
/// facade so processVideo / exportVideo / the _testResolveTargetSize seam call
/// sites are unchanged). `makeOutputURL` is intentionally NOT moved — it reads
/// facade `prefs`/`appName()` and belongs with a later prefs/output slice. The
/// export pipeline itself (LetterboxExporter) is untouched. Pure relocation,
/// behavior identical. Engine-domain (see windows-port-inventory §7).
extension ScreenRecorderFacade {
  func resolveTargetSize(
    sourceSize: CGSize,
    layout: String,
    resolution: String
  ) -> CGSize {
    // 1. Resolve Aspect Ratio from Layout Preset
    let safeSourceHeight = max(sourceSize.height, 1)
    let sourceAspect = sourceSize.width / safeSourceHeight
    let aspect: CGFloat
    switch layout {
    case "classic43": aspect = 4.0 / 3.0
    case "square11": aspect = 1.0
    case "youtube169": aspect = 16.0 / 9.0
    case "reel916": aspect = 9.0 / 16.0
    default: aspect = sourceAspect
    }

    // 2. Resolve Resolution (Short Side)
    let shortSide: CGFloat
    switch resolution {
    case "p1080": shortSide = 1080
    case "p1440": shortSide = 1440
    case "p2160": shortSide = 2160
    case "p4320": shortSide = 4320
    default:
      // Auto: Use source pixels but respect the aspect ratio we just chose.
      // Preserve the full source pixels on one axis and expand the other.
      guard layout != "auto", sourceSize.width > 0, sourceSize.height > 0 else {
        return sourceSize
      }
      if aspect >= sourceAspect {
        return CGSize(width: sourceSize.height * aspect, height: sourceSize.height)
      }
      return CGSize(width: sourceSize.width, height: sourceSize.width / aspect)
    }

    // 3. Compute final size based on shortSide and aspect
    // If aspect > 1 (horizontal), shortSide is height.
    // If aspect < 1 (vertical), shortSide is width.
    if aspect >= 1.0 {
      // Horizontal or Square
      return CGSize(width: shortSide * aspect, height: shortSide)
    } else {
      // Vertical
      return CGSize(width: shortSide, height: shortSide / aspect)
    }
  }

  func flutterExportFailure(from error: Error) -> FlutterError {
    let nsError = error as NSError
    if let nativeErrorCode = nsError.userInfo["nativeErrorCode"] as? String,
      nativeErrorCode == NativeErrorCode.advancedCameraExportFailed
    {
      var details: [String: Any] = [:]
      if let stage = nsError.userInfo["stage"] as? String {
        details["stage"] = stage
      }
      if let reason = nsError.userInfo["reason"] as? String {
        details["reason"] = reason
      }
      if let context = nsError.userInfo["context"] {
        details["context"] = context
      }
      return FlutterError(
        code: nativeErrorCode,
        message: nsError.localizedDescription,
        details: details.isEmpty ? nil : details
      )
    }

    return FlutterError(
      code: NativeErrorCode.exportError,
      message: error.localizedDescription,
      details: nil
    )
  }

  func exportFormatInfo(_ formatRaw: String) -> ExportFormatInfo {
    switch formatRaw.lowercased() {

    case "mp4":
      return .init(ext: "mp4", avFileType: .mp4)

    case "m4v":
      return .init(ext: "m4v", avFileType: .m4v)

    case "mov":
      return .init(ext: "mov", avFileType: .mov)

    case "gif":
      return .init(ext: "gif", avFileType: nil)  // handled by GIF pipeline, not AVAssetExportSession

    default:
      // Fallback safe default
      return .init(ext: "mov", avFileType: .mov)
    }
  }
}
