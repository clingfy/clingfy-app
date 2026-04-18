import AppKit
import ApplicationServices

final class DisplayService {
  func allDisplays() -> [[String: Any]] {
    let screenLabel = NativeStringsStore.shared.string(for: NativeUIStringKey.displayServiceScreen)
    return NSScreen.screens.enumerated().compactMap { (idx, s) in
      guard let num = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
      else { return nil }
      let did = num.uint32Value
      let frame = s.frame
      return [
        "id": UInt32(did),
        "name": "\(screenLabel) \(idx + 1)",
        "x": frame.origin.x, "y": frame.origin.y,
        "width": frame.size.width, "height": frame.size.height,
        "scale": s.backingScaleFactor,
      ]
    }
  }

  func displayIDForAppWindowOrMain() -> CGDirectDisplayID {
    if let win = NSApp.keyWindow ?? NSApp.mainWindow,
      let screen = win.screen,
      let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    {
      return CGDirectDisplayID(num.uint32Value)
    }
    return CGMainDisplayID()
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
