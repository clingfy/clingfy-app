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

enum CameraCaptureMode: String, Codable {
  case bakedOverlay = "bakedOverlay"
  case separateCameraAsset = "separateCameraAsset"
}

enum CameraLayoutPreset: String, Codable, CaseIterable {
  case overlayTopLeft = "overlayTopLeft"
  case overlayTopRight = "overlayTopRight"
  case overlayBottomLeft = "overlayBottomLeft"
  case overlayBottomRight = "overlayBottomRight"
  case sideBySideLeft = "sideBySideLeft"
  case sideBySideRight = "sideBySideRight"
  case stackedTop = "stackedTop"
  case stackedBottom = "stackedBottom"
  case backgroundBehind = "backgroundBehind"
  case hidden = "hidden"

  static func fromOverlayPosition(_ value: Int) -> CameraLayoutPreset {
    switch value {
    case 0:
      return .overlayTopLeft
    case 1:
      return .overlayTopRight
    case 2:
      return .overlayBottomLeft
    default:
      return .overlayBottomRight
    }
  }
}

enum CameraZoomBehavior: String, Codable {
  case fixed = "fixed"
  case scaleWithScreenZoom = "scaleWithScreenZoom"

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(String.self)
    self = CameraZoomBehavior.from(rawValue: rawValue)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  static func from(rawValue: String?) -> CameraZoomBehavior {
    switch rawValue {
    case CameraZoomBehavior.scaleWithScreenZoom.rawValue:
      return .scaleWithScreenZoom
    default:
      return .fixed
    }
  }
}

enum CameraIntroPreset: String, Codable {
  case none = "none"
  case fade = "fade"
  case pop = "pop"
  case slide = "slide"

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(String.self)
    self = CameraIntroPreset.from(rawValue: rawValue)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  static func from(rawValue: String?) -> CameraIntroPreset {
    switch rawValue {
    case CameraIntroPreset.fade.rawValue:
      return .fade
    case CameraIntroPreset.pop.rawValue:
      return .pop
    case CameraIntroPreset.slide.rawValue:
      return .slide
    default:
      return .none
    }
  }
}

enum CameraOutroPreset: String, Codable {
  case none = "none"
  case fade = "fade"
  case shrink = "shrink"
  case slide = "slide"

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(String.self)
    self = CameraOutroPreset.from(rawValue: rawValue)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  static func from(rawValue: String?) -> CameraOutroPreset {
    switch rawValue {
    case CameraOutroPreset.fade.rawValue:
      return .fade
    case CameraOutroPreset.shrink.rawValue:
      return .shrink
    case CameraOutroPreset.slide.rawValue:
      return .slide
    default:
      return .none
    }
  }
}

enum CameraZoomEmphasisPreset: String, Codable {
  case none = "none"
  case pulse = "pulse"

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(String.self)
    self = CameraZoomEmphasisPreset.from(rawValue: rawValue)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  static func from(rawValue: String?) -> CameraZoomEmphasisPreset {
    switch rawValue {
    case CameraZoomEmphasisPreset.pulse.rawValue:
      return .pulse
    default:
      return .none
    }
  }
}

enum CameraShape: String, Codable {
  case circle = "circle"
  case roundedRect = "roundedRect"
  case square = "square"
  case squircle = "squircle"

  static func fromOverlayShape(_ shape: CameraOverlayShapeID) -> CameraShape {
    switch shape {
    case .circle:
      return .circle
    case .roundedRect:
      return .roundedRect
    case .square:
      return .square
    case .squircle:
      return .squircle
    case .hexagon, .star:
      return .roundedRect
    }
  }
}

enum CameraContentMode: String, Codable {
  case fit = "fit"
  case fill = "fill"
}
