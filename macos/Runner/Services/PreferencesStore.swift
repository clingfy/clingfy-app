import Foundation

enum CameraOverlayShapeID: Int {
  case circle = 0
  case roundedRect = 1
  case square = 2
  case hexagon = 3
  case star = 4
  case squircle = 5

  static let defaultValue: CameraOverlayShapeID = .squircle

  static func fromLegacyOrdinal(_ rawValue: Int?) -> CameraOverlayShapeID? {
    switch rawValue {
    case 0:
      return .circle
    case 1:
      return .roundedRect
    case 2:
      return .square
    case 3:
      return .hexagon
    case 4:
      return .star
    default:
      return nil
    }
  }
}

final class PreferencesStore {
  private static let legacyOverlayShapeKey = "overlayShape"
  private let ud = UserDefaults.standard

  init() {
    ud.register(defaults: [
      PrefKey.quality: RecordingQuality.fhd.rawValue,
      PrefKey.overlayEnabled: false,
      PrefKey.overlayLinked: true,
      PrefKey.overlaySize: 220.0,
      PrefKey.cursorEnabled: false,
      PrefKey.cursorLinked: true,
      PrefKey.displayMode: DisplayTargetMode.explicitID.rawValue,
      PrefKey.fileTemplate: "{appname}-{date}-{time}",
      PrefKey.indicatorPinned: false,
      PrefKey.keepOriginals: true,
      PrefKey.excludeRecorderApp: false,  // Default: exclude recorder app from capture
      PrefKey.excludeMicFromSystemAudio: true,  // Default: prevent mic feedback in system audio
      PrefKey.cameraCaptureMode: CameraCaptureMode.separateCameraAsset.rawValue,

      PrefKey.overlayShapeId: CameraOverlayShapeID.defaultValue.rawValue,
      "overlayShadow": 0,
      "overlayBorder": 0,
      "overlayPosition": 3,
      "overlayRoundness": 0.0,
      "overlayOpacity": 1.0,
      "overlayMirror": true,
      "overlayHighlight": false,
    ])
  }

  var recordingQuality: RecordingQuality {
    get { RecordingQuality(rawValue: ud.string(forKey: PrefKey.quality) ?? "fhd") ?? .fhd }
    set { ud.set(newValue.rawValue, forKey: PrefKey.quality) }
  }

  var audioDeviceId: String? {
    get { ud.string(forKey: PrefKey.audioDeviceId) }
    set { ud.set(newValue, forKey: PrefKey.audioDeviceId) }
  }

  var videoDeviceId: String? {
    get { ud.string(forKey: PrefKey.videoDeviceId) }
    set { ud.set(newValue, forKey: PrefKey.videoDeviceId) }
  }

  var overlayEnabled: Bool {
    get { ud.bool(forKey: PrefKey.overlayEnabled) }
    set { ud.set(newValue, forKey: PrefKey.overlayEnabled) }
  }

  var overlayLinked: Bool {
    get { ud.bool(forKey: PrefKey.overlayLinked) }
    set { ud.set(newValue, forKey: PrefKey.overlayLinked) }
  }

  var overlaySize: Double {
    get { max(120.0, ud.double(forKey: PrefKey.overlaySize)) }
    set { ud.set(newValue, forKey: PrefKey.overlaySize) }
  }

  var cursorEnabled: Bool {
    get { ud.bool(forKey: PrefKey.cursorEnabled) }
    set { ud.set(newValue, forKey: PrefKey.cursorEnabled) }
  }

  var cursorLinked: Bool {
    get { ud.bool(forKey: PrefKey.cursorLinked) }
    set { ud.set(newValue, forKey: PrefKey.cursorLinked) }
  }

  var displayMode: DisplayTargetMode {
    get { DisplayTargetMode(rawValue: ud.integer(forKey: PrefKey.displayMode)) ?? .explicitID }
    set { ud.set(newValue.rawValue, forKey: PrefKey.displayMode) }
  }

  var selectedDisplayId: Int? {
    get {
      let v = ud.integer(forKey: PrefKey.displayId)
      return v == 0 ? nil : v
    }
    set {
      if let v = newValue {
        ud.set(v, forKey: PrefKey.displayId)
      } else {
        ud.removeObject(forKey: PrefKey.displayId)
      }
    }
  }

  var selectedAppWindowId: Int? {
    get {
      let v = ud.integer(forKey: PrefKey.appWindowId)
      return v == 0 ? nil : v
    }
    set {
      if let v = newValue {
        ud.set(v, forKey: PrefKey.appWindowId)
      } else {
        ud.removeObject(forKey: PrefKey.appWindowId)
      }
    }
  }

  var fileTemplate: String {
    get { (ud.string(forKey: PrefKey.fileTemplate) ?? "{appname}-{date}-{time}") }
    set { ud.set(newValue, forKey: PrefKey.fileTemplate) }
  }

  var indicatorPinned: Bool {
    get { ud.bool(forKey: PrefKey.indicatorPinned) }
    set { ud.set(newValue, forKey: PrefKey.indicatorPinned) }
  }

  var overlayShape: CameraOverlayShapeID {
    get {
      if hasPersistedValue(forKey: PrefKey.overlayShapeId),
        let rawValue = integerValue(forKey: PrefKey.overlayShapeId)
      {
        if let shape = CameraOverlayShapeID(rawValue: rawValue) {
          return shape
        }
        ud.set(CameraOverlayShapeID.defaultValue.rawValue, forKey: PrefKey.overlayShapeId)
        return .defaultValue
      }

      if hasPersistedValue(forKey: Self.legacyOverlayShapeKey),
        let legacyRawValue = integerValue(forKey: Self.legacyOverlayShapeKey),
        let migratedShape = CameraOverlayShapeID.fromLegacyOrdinal(legacyRawValue)
      {
        ud.set(migratedShape.rawValue, forKey: PrefKey.overlayShapeId)
        return migratedShape
      }

      return .defaultValue
    }
    set { ud.set(newValue.rawValue, forKey: PrefKey.overlayShapeId) }
  }

  var overlayShadow: Int {
    get { ud.integer(forKey: "overlayShadow") }
    set { ud.set(newValue, forKey: "overlayShadow") }
  }

  var overlayBorder: Int {
    get { ud.integer(forKey: "overlayBorder") }
    set { ud.set(newValue, forKey: "overlayBorder") }
  }

  var overlayPosition: Int {
    get { ud.integer(forKey: "overlayPosition") }
    set { ud.set(newValue, forKey: "overlayPosition") }
  }

  var overlayRoundness: Double {
    get { ud.double(forKey: "overlayRoundness") }
    set { ud.set(newValue, forKey: "overlayRoundness") }
  }

  var overlayOpacity: Double {
    get {
      let v = ud.double(forKey: "overlayOpacity")
      return v == 0 ? 1.0 : v
    }
    set { ud.set(newValue, forKey: "overlayOpacity") }
  }

  var overlayMirror: Bool {
    get { ud.bool(forKey: "overlayMirror") }
    set { ud.set(newValue, forKey: "overlayMirror") }
  }

  var overlayHighlight: Bool {
    get { ud.bool(forKey: "overlayHighlight") }
    set { ud.set(newValue, forKey: "overlayHighlight") }
  }

  var areaDisplayId: Int? {
    get {
      let v = ud.integer(forKey: PrefKey.areaDisplayId)
      return v == 0 ? nil : v
    }
    set {
      if let v = newValue {
        ud.set(v, forKey: PrefKey.areaDisplayId)
      } else {
        ud.removeObject(forKey: PrefKey.areaDisplayId)
      }
    }
  }

  var areaRect: CGRect? {
    get {
      guard let dict = ud.dictionary(forKey: PrefKey.areaRect) as? [String: Double] else {
        return nil
      }
      return CGRect(
        x: dict["x"] ?? 0,
        y: dict["y"] ?? 0,
        width: dict["width"] ?? 0,
        height: dict["height"] ?? 0
      )
    }
    set {
      if let r = newValue {
        ud.set(
          ["x": r.origin.x, "y": r.origin.y, "width": r.size.width, "height": r.size.height],
          forKey: PrefKey.areaRect)
      } else {
        ud.removeObject(forKey: PrefKey.areaRect)
      }
    }
  }

  /// Whether to keep original raw recordings after export.
  /// When false (default), raw recordings and sidecars are deleted after successful export.
  var keepOriginals: Bool {
    get { ud.bool(forKey: PrefKey.keepOriginals) }
    set { ud.set(newValue, forKey: PrefKey.keepOriginals) }
  }

  /// Whether to exclude the recorder app from screen capture.
  /// When true (default), the recorder window is hidden from recordings.
  /// When false, the recorder window appears in recordings (useful for tutorials).
  var excludeRecorderApp: Bool {
    get { ud.bool(forKey: PrefKey.excludeRecorderApp) }
    set { ud.set(newValue, forKey: PrefKey.excludeRecorderApp) }
  }

  /// Whether to exclude the current process's audio output from system audio capture.
  /// When true (default), prevents the mic from being double-captured in the system audio track.
  var excludeMicFromSystemAudio: Bool {
    get { ud.bool(forKey: PrefKey.excludeMicFromSystemAudio) }
    set { ud.set(newValue, forKey: PrefKey.excludeMicFromSystemAudio) }
  }

  var cameraCaptureMode: CameraCaptureMode {
    get {
      CameraCaptureMode(rawValue: ud.string(forKey: PrefKey.cameraCaptureMode) ?? "")
        ?? .separateCameraAsset
    }
    set { ud.set(newValue.rawValue, forKey: PrefKey.cameraCaptureMode) }
  }

  private func integerValue(forKey key: String) -> Int? {
    guard let value = ud.object(forKey: key) as? NSNumber else {
      return nil
    }
    return value.intValue
  }

  private func hasPersistedValue(forKey key: String) -> Bool {
    for domainName in userDefaultsDomainNames() {
      if ud.persistentDomain(forName: domainName)?[key] != nil {
        return true
      }
    }
    return false
  }

  private func userDefaultsDomainNames() -> [String] {
    var domainNames: [String] = []
    if let mainBundleID = Bundle.main.bundleIdentifier, !mainBundleID.isEmpty {
      domainNames.append(mainBundleID)
    }
    if let storeBundleID = Bundle(for: PreferencesStore.self).bundleIdentifier,
      !storeBundleID.isEmpty,
      !domainNames.contains(storeBundleID)
    {
      domainNames.append(storeBundleID)
    }
    return domainNames
  }
}
