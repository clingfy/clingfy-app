import CoreGraphics
import Foundation

/// Slice 4 / PR 15: owns the small overlay-update state previously held inline
/// on `ScreenRecorderFacade` — the dedup memory for capture-backend overlay
/// updates and the last overlay-window ID we pushed into the backend — plus
/// the pure "which window ID should the capture backend know about?" decision.
///
/// The controller deliberately does NOT own `camera`, `prefs`, `state`,
/// `capture`, or the `updateOverlayVisibility(...)` UI flow; the facade keeps
/// every side effect (`camera.show`, `capture.updateOverlay`, the
/// recording-state guard in `syncOverlayWindowIntoCaptureIfNeeded`). This is
/// the first real stored-state migration in the strangler refactor: state
/// moves, side-effects don't.
///
/// Engine-domain; see `windows-port-inventory.md` §7.
@MainActor
final class OverlayVisibilityController {

  private var deduper = OverlayUpdateDeduper()

  /// Last overlay window ID the facade told the capture backend about (via
  /// `setLastOverlayWindowID`). Mirrors the old facade-owned
  /// `lastOverlayWindowID` field; consumers do not rely on its identity, only
  /// its value.
  private(set) var lastOverlayWindowID: CGWindowID?

  /// Record the window ID that the facade most recently associated with the
  /// active camera overlay. Behaviorally identical to the old direct field
  /// assignment.
  func setLastOverlayWindowID(_ id: CGWindowID?) {
    lastOverlayWindowID = id
  }

  /// Drop the dedup memory so the next overlay update is always sent. Mirrors
  /// the old `resetOverlayUpdateDeduper()` helper.
  func resetDeduper() {
    deduper.reset()
  }

  /// Returns `true` iff the facade should actually push this window ID to the
  /// capture backend (the dedup miss path). Wraps the pure-value-type
  /// `OverlayUpdateDeduper.shouldSend(_:)`.
  func shouldSendOverlayUpdate(_ windowID: CGWindowID?) -> Bool {
    deduper.shouldSend(windowID)
  }

  /// Pure decision extracted verbatim from the old facade
  /// `overlayWindowIDForCapture(liveOverlayWindowID:)`:
  ///
  /// - In normal mode (no separate-camera asset), always forward the live
  ///   overlay window ID — including `nil` — to the capture backend so the
  ///   exclusion list matches the user's overlay state exactly.
  /// - In separate-camera mode, forward the overlay window ID only when the
  ///   backend supports live overlay exclusion mid-capture; otherwise return
  ///   `nil`, matching the old facade's defensive policy on backends that
  ///   would otherwise double-record the overlay window.
  func overlayWindowIDForCapture(
    liveOverlayWindowID: CGWindowID?,
    shouldRecordSeparateCameraAsset: Bool,
    supportsLiveOverlayExclusionDuringSeparateCameraCapture: Bool
  ) -> CGWindowID? {
    guard shouldRecordSeparateCameraAsset else {
      return liveOverlayWindowID
    }

    return supportsLiveOverlayExclusionDuringSeparateCameraCapture
      ? liveOverlayWindowID
      : nil
  }
}
