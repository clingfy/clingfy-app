import CoreGraphics
import Foundation

public enum DisplayTargetMode: Int {
  case explicitID = 0
  case appWindow = 1
  case singleAppWindow = 2
  case areaRecording = 3
  ////
  case mouseAtStart = 4
  case followMouse = 5
}
enum RecorderState {
  case idle
  case starting
  case recording
  case paused
  case stopping
}

enum RecordingQuality: String {
  case sd, hd720, fhd, uhd2k, uhd4k, uhd8k, vertical4k, native
  var targetSize: CGSize {
    switch self {
    case .sd: return .init(width: 854, height: 480)
    case .hd720: return .init(width: 1280, height: 720)
    case .fhd: return .init(width: 1920, height: 1080)
    case .uhd2k: return .init(width: 2560, height: 1440)
    case .uhd4k: return .init(width: 3840, height: 2160)
    case .uhd8k: return .init(width: 7680, height: 4320)
    case .vertical4k: return .init(width: 2160, height: 3840)
    case .native: return .zero
    }
  }
}
