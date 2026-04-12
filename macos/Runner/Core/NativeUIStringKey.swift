import Foundation

/// Keys for native UI strings that are fetched from Flutter localization.
///
/// These are used by native macOS code (menu bar, etc.) to request
/// localized strings from Flutter.
///
/// IMPORTANT: Keep this in sync with `native_ui_string_keys.dart` on the Flutter side.
enum NativeUIStringKey {
  // Menu bar items
  static let menuStartRecording = "menu.startRecording"
  static let menuStopRecording = "menu.stopRecording"
  static let menuOpenApp = "menu.openApp"
  static let menuQuit = "menu.quit"

  // Accessibility descriptions
  static let accessibilityStartRecording = "accessibility.startRecording"
  static let accessibilityStopRecording = "accessibility.stopRecording"

  // Recording warnings/errors
  static let recordingSelectedMicFallbackWarning = "recording.selectedMicFallbackWarning"
  static let recordingSelectedMicFallbackFailure = "recording.selectedMicFallbackFailure"
}
