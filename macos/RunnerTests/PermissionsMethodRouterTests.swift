import FlutterMacOS
import XCTest

@testable import Clingfy

/// Commit 3 guard: the new ScreenRecorderMethodDispatcher / PermissionsMethodRouter
/// layer must be fully transparent to every method it does NOT claim — it may
/// neither return `true` nor invoke `result` for non-permission traffic, so the
/// legacy switch keeps handling those exactly as before.
///
/// The 7 claimed methods (getPermissionStatus, request{ScreenRecording,
/// Microphone,Camera}Permission, openAccessibilitySettings,
/// openScreenRecordingSettings, relaunchApp) are intentionally NOT exercised
/// here: PermissionsMethodRouter delegates each to the identical facade method
/// the inline switch called, and invoking them triggers real OS permission
/// prompts / Settings windows. Their behavior-equivalence is by construction
/// (same facade call) — see Commit 3 notes in MainFlutterWindow.
@MainActor
final class PermissionsMethodRouterTests: XCTestCase {

  private let nonPermissionMethods = [
    "startRecording", "stopRecording", "pauseRecording", "resumeRecording",
    "exportVideo", "processVideo", "cancelExport", "getDisplays", "setDisplay",
    "getAudioSources", "setAudioSource", "showCameraOverlay", "previewOpen",
    "openSystemSettings", "checkForUpdates", "isAccessibilityTrusted",
    "cacheLocalizedStrings", "getZoomSegments", "thisMethodDoesNotExist",
  ]

  func testDispatcherDoesNotClaimNonPermissionMethods() {
    let dispatcher = ScreenRecorderMethodDispatcher(facade: ScreenRecorderFacade())

    for method in nonPermissionMethods {
      let call = FlutterMethodCall(methodName: method, arguments: nil)
      var resultInvoked = false
      let handled = dispatcher.handle(call) { _ in resultInvoked = true }

      XCTAssertFalse(handled, "dispatcher must not claim \(method)")
      XCTAssertFalse(
        resultInvoked, "dispatcher must not invoke result for unclaimed \(method)")
    }
  }
}
