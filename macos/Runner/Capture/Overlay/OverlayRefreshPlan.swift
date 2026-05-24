import CoreGraphics

/// Decides how the camera overlay window should be refreshed for a target display/size.
/// Pure decision logic (engine-domain; see windows-port-inventory §7).
enum OverlayRefreshAction: Equatable {
  case show
  case resize
  case reuseVisibleWindow
}

struct OverlayRefreshPlan {
  let action: OverlayRefreshAction

  static func make(
    isShowing: Bool,
    currentTargetDisplayID: CGDirectDisplayID?,
    desiredTargetDisplayID: CGDirectDisplayID?,
    currentPreferredSize: Double,
    desiredSize: Double
  ) -> OverlayRefreshPlan {
    let normalizedDesiredSize = max(120.0, desiredSize)

    guard isShowing else {
      return OverlayRefreshPlan(action: .show)
    }

    guard currentTargetDisplayID == desiredTargetDisplayID else {
      return OverlayRefreshPlan(action: .show)
    }

    if abs(currentPreferredSize - normalizedDesiredSize) > 0.001 {
      return OverlayRefreshPlan(action: .resize)
    }

    return OverlayRefreshPlan(action: .reuseVisibleWindow)
  }
}
