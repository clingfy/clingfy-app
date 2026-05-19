import CoreGraphics

/// Suppresses redundant overlay-window-ID updates pushed into the capture backend.
/// Pure value type (engine-domain; see windows-port-inventory §7).
struct OverlayUpdateDeduper {
  private var hasLastSentValue = false
  private(set) var lastSentWindowID: CGWindowID?

  mutating func shouldSend(_ windowID: CGWindowID?) -> Bool {
    if hasLastSentValue && lastSentWindowID == windowID {
      return false
    }

    hasLastSentValue = true
    lastSentWindowID = windowID
    return true
  }

  mutating func reset() {
    hasLastSentValue = false
    lastSentWindowID = nil
  }
}
