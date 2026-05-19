import FlutterMacOS
import Foundation

/// A unit that can claim and handle a subset of `com.clingfy/screen_recorder`
/// method-channel calls. Returns `true` iff it handled the call (and is then
/// responsible for invoking `result`); `false` to let the next router or the
/// residual switch handle it. Engine-domain dispatch shape — Windows mirrors it
/// (see windows-port-inventory §7).
protocol ScreenRecorderMethodRouting: AnyObject {
  func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) -> Bool
}

/// The existing PermissionsMethodRouter already exposes the exact
/// `handle(_:_:) -> Bool` signature; opt it into the protocol without touching
/// its file (Commit 3 of the strangler refactor).
extension PermissionsMethodRouter: ScreenRecorderMethodRouting {}

/// Owns the ordered router list and tries each in turn. Composed into
/// MainFlutterWindow ahead of the legacy switch: any method a router claims is
/// removed from the switch; everything else falls through unchanged.
final class ScreenRecorderMethodDispatcher {
  private let routers: [ScreenRecorderMethodRouting]

  init(facade: ScreenRecorderFacade) {
    self.routers = [
      PermissionsMethodRouter(facade: facade)
      // Subsequent strangler slices append RecordingControlRouter,
      // SourceSelectionRouter, … here, deleting their switch cases.
    ]
  }

  /// Returns true if a router handled the call (and invoked `result`).
  func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) -> Bool {
    for router in routers where router.handle(call, result) {
      return true
    }
    return false
  }
}
