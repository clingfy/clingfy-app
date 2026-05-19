import Foundation

/// Describes whether/how the active capture backend supports pause/resume.
/// The `macOS 15` branch is the only platform bit (engine-domain core;
/// Windows substitutes an MF sink-writer capability probe — see windows-port-inventory §7).
struct RecordingPauseResumeCapabilities {
  enum Backend: String {
    case avFoundation = "avfoundation"
    case screenCaptureKit = "screencapturekit"
    case unsupported = "unsupported"
  }

  enum Strategy: String {
    case avFileOutput = "av_file_output"
    case recordingOutputSegmentation = "recording_output_segmentation"
    case unsupported = "unsupported"
  }

  let canPauseResume: Bool
  let backend: Backend
  let strategy: Strategy

  func asMap() -> [String: Any] {
    [
      "canPauseResume": canPauseResume,
      "backend": backend.rawValue,
      "strategy": strategy.rawValue,
    ]
  }

  static func current() -> RecordingPauseResumeCapabilities {
    if #available(macOS 15.0, *) {
      return RecordingPauseResumeCapabilities(
        canPauseResume: true,
        backend: .screenCaptureKit,
        strategy: .recordingOutputSegmentation
      )
    }

    return RecordingPauseResumeCapabilities(
      canPauseResume: true,
      backend: .avFoundation,
      strategy: .avFileOutput
    )
  }
}
