import CoreGraphics
import Foundation

/// Resolves the `CaptureTarget` for a recording from the selected display
/// mode + selection inputs. Extracted verbatim out of
/// `ScreenRecorderFacade.resolveCaptureTarget()` (Slice 3 / PR 12 of the
/// strangler refactor).
///
/// Standalone and stateless — it owns no session state. The facade passes
/// `selectedDisplayID` / `selectedAppWindowID` / prefs-derived values in via
/// `Input`, and the display lookups via the `CaptureDisplayResolving` seam
/// (DisplayService conforms). Behavior is identical to the inline switch.
/// Engine-domain orchestration with a platform display leaf (see
/// windows-port-inventory §7).
enum CaptureTargetError: Error {
  case noWindowSelected, windowUnavailable, noAreaSelected
}

/// Minimal seam over DisplayService so the resolver is unit-testable without
/// real displays. DisplayService conforms unchanged.
protocol CaptureDisplayResolving {
  func displayIDForAppWindowOrMain() -> CGDirectDisplayID
  func displayIDUnderMouse() -> CGDirectDisplayID?
  func captureTarget(forWindowID id: CGWindowID) -> (displayID: CGDirectDisplayID, rect: CGRect)?
}

struct CaptureTargetResolver {
  struct Input {
    let displayMode: DisplayTargetMode
    let selectedDisplayID: CGDirectDisplayID?
    let selectedAppWindowID: CGWindowID?
    let areaRect: CGRect?
    let areaDisplayId: Int?
  }

  func resolve(
    _ input: Input,
    displayService: CaptureDisplayResolving
  ) throws -> CaptureTarget {
    switch input.displayMode {
    case .explicitID:
      return CaptureTarget(
        mode: DisplayTargetMode.explicitID,
        displayID: input.selectedDisplayID ?? displayService.displayIDForAppWindowOrMain(),
        cropRect: nil,  // for cursor normalization
        windowID: nil  // for SCK true window capture
      )
    case .appWindow:
      return CaptureTarget(
        mode: DisplayTargetMode.appWindow,
        displayID: displayService.displayIDForAppWindowOrMain(),
        cropRect: nil,  // for cursor normalization
        windowID: nil  // for SCK true window capture
      )
    case .mouseAtStart, .followMouse:
      return CaptureTarget(
        mode: DisplayTargetMode.mouseAtStart,
        displayID: displayService.displayIDUnderMouse()
          ?? displayService.displayIDForAppWindowOrMain(),
        cropRect: nil,  // for cursor normalization
        windowID: nil  // for SCK true window capture
      )
    case .singleAppWindow:
      guard let windowID = input.selectedAppWindowID else {
        throw CaptureTargetError.noWindowSelected
      }
      guard let config = displayService.captureTarget(forWindowID: windowID) else {
        throw CaptureTargetError.windowUnavailable
      }
      return CaptureTarget(
        mode: DisplayTargetMode.singleAppWindow,
        displayID: config.displayID,
        cropRect: config.rect,  // for cursor normalization
        windowID: windowID  // for SCK true window capture
      )
    case .areaRecording:
      guard let rect = input.areaRect, let displayID = input.areaDisplayId else {
        throw CaptureTargetError.noAreaSelected
      }
      return CaptureTarget(
        mode: DisplayTargetMode.areaRecording,
        displayID: CGDirectDisplayID(displayID),
        cropRect: rect,  // for cursor normalization
        windowID: nil  // for SCK true window capture
      )
    }
  }
}
