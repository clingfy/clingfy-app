import CoreGraphics
import Foundation

struct RecordingMetadata: Codable {
  struct CropRectInfo: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(rect: CGRect) {
      self.x = rect.origin.x
      self.y = rect.origin.y
      self.width = rect.size.width
      self.height = rect.size.height
    }

    var cgRect: CGRect {
      CGRect(x: x, y: y, width: width, height: height)
    }
  }

  struct Dimensions: Codable, Equatable {
    let width: Int
    let height: Int
  }

  struct NormalizedPoint: Codable, Equatable {
    let x: Double
    let y: Double
  }

  struct ScreenCaptureInfo: Codable, Equatable {
    let rawRelativePath: String
    let displayMode: Int
    let displayId: UInt32
    let windowId: UInt32?
    let cropRect: CropRectInfo?
    let frameRate: Int
    let quality: String
    let cursorEnabled: Bool
    let cursorLinked: Bool
    let excludedRecorderApp: Bool
  }

  struct CameraCaptureInfo: Codable, Equatable {
    let mode: CameraCaptureMode
    let enabled: Bool
    let rawRelativePath: String?
    let metadataRelativePath: String?
    let deviceId: String?
    let mirroredRaw: Bool
    let nominalFrameRate: Double?
    let dimensions: Dimensions?
    let segments: [CameraRecordingMetadata.Segment]
  }

  struct EditorSeed: Codable, Equatable {
    var cameraVisible: Bool
    var cameraLayoutPreset: CameraLayoutPreset
    var cameraNormalizedCenter: NormalizedPoint?
    var cameraSizeFactor: Double
    var cameraShape: CameraShape
    var cameraCornerRadius: Double
    var cameraBorderWidth: Double
    var cameraBorderColorArgb: Int?
    var cameraShadow: Int
    var cameraOpacity: Double
    var cameraMirror: Bool
    var cameraContentMode: CameraContentMode
    var cameraZoomBehavior: CameraZoomBehavior
    var cameraChromaKeyEnabled: Bool
    var cameraChromaKeyStrength: Double
    var cameraChromaKeyColorArgb: Int?
  }

  let version: Int
  let recordingId: String
  let appVersion: String
  let bundleId: String
  let startedAt: String
  var endedAt: String?
  let screen: ScreenCaptureInfo
  var camera: CameraCaptureInfo?
  var editorSeed: EditorSeed

  static func create(
    rawURL: URL,
    displayMode: DisplayTargetMode,
    displayID: CGDirectDisplayID,
    cropRect: CGRect?,
    frameRate: Int,
    quality: RecordingQuality,
    cursorEnabled: Bool,
    cursorLinked: Bool,
    windowID: CGWindowID?,
    excludedRecorderApp: Bool,
    camera: CameraCaptureInfo?,
    editorSeed: EditorSeed
  ) -> RecordingMetadata {
    RecordingMetadata(
      version: 2,
      recordingId: UUID().uuidString,
      appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
      bundleId: Bundle.main.bundleIdentifier ?? "com.clingfy.app",
      startedAt: recordingISO8601String(from: Date()),
      endedAt: nil,
      screen: ScreenCaptureInfo(
        rawRelativePath: rawURL.lastPathComponent,
        displayMode: displayMode.rawValue,
        displayId: displayID,
        windowId: windowID.map { UInt32($0) },
        cropRect: cropRect.map { CropRectInfo(rect: $0) },
        frameRate: frameRate,
        quality: quality.rawValue,
        cursorEnabled: cursorEnabled,
        cursorLinked: cursorLinked,
        excludedRecorderApp: excludedRecorderApp
      ),
      camera: camera,
      editorSeed: editorSeed
    )
  }

  func write(to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(self)
    try data.write(to: url)
  }

  static func read(from url: URL) throws -> RecordingMetadata {
    let data = try Data(contentsOf: url)
    let object = try JSONSerialization.jsonObject(with: data)
    guard let dictionary = object as? [String: Any] else {
      throw flutterError(NativeErrorCode.recordingError, "Recording metadata is not a dictionary")
    }

    if dictionary["version"] != nil || dictionary["screen"] != nil {
      return try JSONDecoder().decode(RecordingMetadata.self, from: data)
    }

    let legacy = try JSONDecoder().decode(LegacyRecordingMetadataV1.self, from: data)
    return RecordingMetadata(legacy: legacy, metadataURL: url)
  }

  func withEndTimestamp(_ date: Date = Date()) -> RecordingMetadata {
    var copy = self
    copy.endedAt = recordingISO8601String(from: date)
    return copy
  }

  static func iso8601String(from date: Date) -> String {
    recordingISO8601String(from: date)
  }
}

private extension RecordingMetadata {
  init(legacy: LegacyRecordingMetadataV1, metadataURL: URL) {
    let rawRelativePath = Self.rawRelativePath(fromLegacyMetadataURL: metadataURL)
    self.init(
      version: 2,
      recordingId: UUID().uuidString,
      appVersion: legacy.appVersion,
      bundleId: legacy.bundleId,
      startedAt: legacy.startedAt,
      endedAt: legacy.endedAt,
      screen: ScreenCaptureInfo(
        rawRelativePath: rawRelativePath,
        displayMode: legacy.displayMode,
        displayId: legacy.displayID,
        windowId: legacy.windowID,
        cropRect: legacy.cropRect,
        frameRate: legacy.frameRate,
        quality: legacy.quality,
        cursorEnabled: legacy.cursorEnabled,
        cursorLinked: legacy.cursorLinked,
        excludedRecorderApp: legacy.excludedRecorderApp
      ),
      camera: nil,
      editorSeed: EditorSeed(
        cameraVisible: legacy.overlayEnabled,
        cameraLayoutPreset: .overlayBottomRight,
        cameraNormalizedCenter: nil,
        cameraSizeFactor: 0.18,
        cameraShape: .circle,
        cameraCornerRadius: 0.0,
        cameraBorderWidth: 4.0,
        cameraBorderColorArgb: nil,
        cameraShadow: 0,
        cameraOpacity: 1.0,
        cameraMirror: true,
        cameraContentMode: .fill,
        cameraZoomBehavior: .fixed,
        cameraChromaKeyEnabled: false,
        cameraChromaKeyStrength: 0.4,
        cameraChromaKeyColorArgb: nil
      )
    )
  }

  static func rawRelativePath(fromLegacyMetadataURL url: URL) -> String {
    let fileName = url.lastPathComponent
    if fileName.hasSuffix(".meta.json") {
      let trimmed = String(fileName.dropLast(".meta.json".count))
      return "\(trimmed).mov"
    }
    return url.deletingPathExtension().lastPathComponent
  }
}

private struct LegacyRecordingMetadataV1: Codable {
  let schemaVersion: Int
  let appVersion: String
  let bundleId: String
  let startedAt: String
  let endedAt: String?
  let displayMode: Int
  let displayID: UInt32
  let cropRect: RecordingMetadata.CropRectInfo?
  let frameRate: Int
  let quality: String
  let cursorEnabled: Bool
  let cursorLinked: Bool
  let overlayEnabled: Bool
  let windowID: UInt32?
  let excludedRecorderApp: Bool
}

private func iso8601String(from date: Date) -> String {
  recordingISO8601String(from: date)
}

private func recordingISO8601String(from date: Date) -> String {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter.string(from: date)
}
