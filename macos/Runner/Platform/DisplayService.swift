import AppKit
import ApplicationServices

/// Pure display ordering + labelling. No `NSScreen` or CoreGraphics call lives
/// in here, so it is unit-testable without hardware.
///
/// Mirrored in `windows/runner/Bridge/Devices/display_label.{h,cpp}` — the two
/// must produce identical strings for identical input, and each side's test
/// suite asserts the same literal outputs so a drift turns one of them red.
enum DisplayLabeler {
  struct Descriptor {
    let id: CGDirectDisplayID
    /// Already normalised: nil, never "".
    let osName: String?
    let x: Double
    /// AppKit's bottom-left-origin y, as it goes on the wire. NOT the sort key.
    let y: Double
    let width: Double
    let height: Double
    let scale: Double
    let isPrimary: Bool
    let isAppWindowHost: Bool

    /// Top-down vertical sort key, ascending = higher on the desk.
    ///
    /// AppKit is y-up and Win32 `rcMonitor.top` is y-down, so sorting both on
    /// their native y would number a vertically stacked pair in OPPOSITE
    /// directions on the two platforms. Normalising to top-down here is what
    /// makes the Windows mirror a real mirror.
    var sortY: Double { -(y + height) }
  }

  /// Names an inbox driver hands back that identify nothing. Compared trimmed
  /// and lowercased.
  static let genericNames: Set<String> = [
    "", "display", "unknown", "unknown display",
    "generic pnp monitor", "generic non-pnp monitor", "default monitor",
  ]

  /// nil when the OS name is missing, blank, or a known placeholder.
  /// Internal whitespace runs collapse to a single space.
  static func normalizedOSName(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let collapsed = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
      .joined(separator: " ")
    if collapsed.isEmpty { return nil }
    if genericNames.contains(collapsed.lowercased()) { return nil }
    return collapsed
  }

  /// Total order: x ascending (left to right), then top-down, then id.
  ///
  /// The sort key is desktop geometry rather than the OS enumeration order, so
  /// two enumerations of an unchanged display configuration produce identical
  /// ordinals no matter how `NSScreen.screens` shuffled its array. Ties are
  /// impossible because ids are unique.
  ///
  /// The vertical key is `sortY`, not `y` — see the comment on it. The C++
  /// mirror sorts `rcMonitor.top` ascending, which is already top-down.
  static func ordered(_ descriptors: [Descriptor]) -> [Descriptor] {
    descriptors.sorted { lhs, rhs in
      if lhs.x != rhs.x { return lhs.x < rhs.x }
      if lhs.sortY != rhs.sortY { return lhs.sortY < rhs.sortY }
      return lhs.id < rhs.id
    }
  }

  /// `"<ordinal>. <osName ?? screenWord>"`
  static func composedName(osName: String?, ordinal: Int, screenWord: String) -> String {
    let base: String
    if let osName, !osName.isEmpty {
      base = osName
    } else {
      base = screenWord.isEmpty ? "Screen" : screenWord
    }
    return "\(ordinal). \(base)"
  }

  /// THE single entry point. One call produces the ordinal, the composed name
  /// and the payload, so they cannot drift — they are one expression.
  static func payloads(from descriptors: [Descriptor], screenWord: String) -> [[String: Any]] {
    ordered(descriptors).enumerated().map { (index, entry) in
      let ordinal = index + 1
      var payload: [String: Any] = [
        "id": UInt32(entry.id),
        "name": composedName(
          osName: entry.osName, ordinal: ordinal, screenWord: screenWord),
        "x": entry.x,
        "y": entry.y,
        "width": entry.width,
        "height": entry.height,
        "scale": entry.scale,
        "ordinal": ordinal,
        "isPrimary": entry.isPrimary,
        "isAppWindowHost": entry.isAppWindowHost,
      ]
      // Absent, not empty — Dart reads it as null and substitutes its own
      // localized fallback word.
      if let osName = entry.osName { payload["osName"] = osName }
      return payload
    }
  }
}

final class DisplayService {
  /// The single enumeration behind both `getDisplays` and `identifyDisplays`.
  func descriptors() -> [DisplayLabeler.Descriptor] {
    let mainID = CGMainDisplayID()
    let hostID = appWindowDisplayID()
    return NSScreen.screens.compactMap { screen in
      guard
        let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
      else { return nil }
      let did = CGDirectDisplayID(num.uint32Value)
      let frame = screen.frame
      return DisplayLabeler.Descriptor(
        id: did,
        // Available since 10.15; the deployment target is 13.0.
        osName: DisplayLabeler.normalizedOSName(screen.localizedName),
        x: Double(frame.origin.x),
        y: Double(frame.origin.y),
        width: Double(frame.size.width),
        height: Double(frame.size.height),
        scale: Double(screen.backingScaleFactor),
        isPrimary: did == mainID,
        isAppWindowHost: hostID != nil && did == hostID!)
    }
  }

  func allDisplays() -> [[String: Any]] {
    DisplayLabeler.payloads(
      from: descriptors(),
      screenWord: NativeStringsStore.shared.string(for: NativeUIStringKey.displayServiceScreen))
  }

  /// The display hosting Clingfy's key/main window, or nil when no Clingfy
  /// window is key.
  ///
  /// Deliberately does NOT fall back to `CGMainDisplayID()`: the "This window"
  /// marker must be ABSENT rather than wrong when the app is in the background.
  /// `displayIDForAppWindowOrMain()` keeps its old total behaviour for callers
  /// that need a display no matter what.
  func appWindowDisplayID() -> CGDirectDisplayID? {
    guard let win = NSApp.keyWindow ?? NSApp.mainWindow,
      let screen = win.screen,
      let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    else { return nil }
    return CGDirectDisplayID(num.uint32Value)
  }

  func displayIDForAppWindowOrMain() -> CGDirectDisplayID {
    appWindowDisplayID() ?? CGMainDisplayID()
  }

  func displayIDUnderMouse() -> CGDirectDisplayID? {
    let loc = NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { NSMouseInRect(loc, $0.frame, false) }) else {
      return nil
    }
    if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
      return CGDirectDisplayID(num.uint32Value)
    }
    return nil
  }

  func appWindows() -> [[String: Any]] {
    guard
      let info =
        CGWindowListCopyWindowInfo(
          [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return [] }
    return info.compactMap { entry in
      guard
        let layerNum = entry[kCGWindowLayer as String] as? NSNumber,
        layerNum.intValue == 0,
        let idNum = entry[kCGWindowNumber as String] as? NSNumber,
        let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
        let rect = CGRect(dictionaryRepresentation: boundsDict),
        rect.width > 1, rect.height > 1
      else { return nil }
      let normalized = normalize(rect: rect)
      var payload: [String: Any] = [
        "windowId": idNum.uint32Value,
        "appName":
          entry[kCGWindowOwnerName as String] as? String
          ?? NativeStringsStore.shared.string(for: NativeUIStringKey.displayServiceApp),
        "title": entry[kCGWindowName as String] as? String ?? "",
        "bounds": [
          "x": normalized.origin.x,
          "y": normalized.origin.y,
          "width": normalized.size.width,
          "height": normalized.size.height,
        ],
      ]
      if let pid = entry[kCGWindowOwnerPID as String] as? NSNumber {
        payload["pid"] = pid.intValue
      }
      if let disp = displayID(forRect: normalized) {
        payload["displayId"] = UInt32(disp)
      }
      return payload
    }
  }

  func captureTarget(forWindowID id: CGWindowID) -> (displayID: CGDirectDisplayID, rect: CGRect)? {
    // Rebuild the same list we used in `appWindows()`
    guard
      let info = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
      ) as? [[String: Any]]
    else {
      NativeLogger.w("Display", "captureTarget: CGWindowListCopyWindowInfo returned nil")
      return nil
    }

    // Find the entry with this windowId
    guard
      let entry = info.first(where: {
        guard let num = $0[kCGWindowNumber as String] as? NSNumber else { return false }
        return num.uint32Value == id
      })
    else {
      NativeLogger.w(
        "Display", "captureTarget: window \(id) not found in current list (count=\(info.count))")
      return nil
    }

    guard
      let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
      let rawRect = CGRect(dictionaryRepresentation: boundsDict)
    else {
      NativeLogger.w("Display", "captureTarget: no bounds for window \(id)")
      return nil
    }

    let rect = normalize(rect: rawRect)
    guard rect.width > 1, rect.height > 1 else {
      NativeLogger.w("Display", "captureTarget: tiny rect for window \(id): \(rect)")
      return nil
    }

    // Use our existing helper to map rect → displayID
    let displayID = displayID(forRect: rect) ?? CGMainDisplayID()
    return (displayID, rect)
  }

  private func displayID(forRect rect: CGRect) -> CGDirectDisplayID? {
    var count: UInt32 = 0
    CGGetDisplaysWithRect(rect, 0, nil, &count)
    guard count > 0 else { return nil }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetDisplaysWithRect(rect, count, &ids, &count)
    return ids.first
  }

  private func normalize(rect: CGRect) -> CGRect {
    let x = floor(rect.origin.x)
    let y = floor(rect.origin.y)
    let w = max(1, floor(rect.size.width))
    let h = max(1, floor(rect.size.height))
    return CGRect(x: x, y: y, width: w, height: h)
  }
}

// Conformance-only: DisplayService already exposes the exact signatures the
// CaptureTargetResolver seam needs (Slice 3 / PR 12).
extension DisplayService: CaptureDisplayResolving {}
