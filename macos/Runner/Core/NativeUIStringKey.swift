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

  // Pre-recording bar
  static let preRecordingBarDisplay = "preRecordingBar.display"
  static let preRecordingBarWindow = "preRecordingBar.window"
  static let preRecordingBarArea = "preRecordingBar.area"
  static let preRecordingBarCamera = "preRecordingBar.camera"
  static let preRecordingBarMic = "preRecordingBar.mic"
  static let preRecordingBarSystem = "preRecordingBar.system"
  static let preRecordingBarUpdate = "preRecordingBar.update"
  static let preRecordingBarPause = "preRecordingBar.pause"
  static let preRecordingBarResume = "preRecordingBar.resume"
  static let preRecordingBarNone = "preRecordingBar.none"
  static let preRecordingBarRefresh = "preRecordingBar.refresh"
  static let preRecordingBarSelectDisplay = "preRecordingBar.selectDisplay"
  static let preRecordingBarSelectWindow = "preRecordingBar.selectWindow"
  static let preRecordingBarSelectMicrophone = "preRecordingBar.selectMicrophone"
  static let preRecordingBarSelectCamera = "preRecordingBar.selectCamera"
  static let preRecordingBarUnknownDisplay = "preRecordingBar.unknownDisplay"
  static let preRecordingBarUnknownWindow = "preRecordingBar.unknownWindow"
  static let preRecordingBarUnknownMic = "preRecordingBar.unknownMic"
  static let preRecordingBarUnknownCamera = "preRecordingBar.unknownCamera"
  static let preRecordingBarNoCamera = "preRecordingBar.noCamera"
  static let preRecordingBarDoNotRecordAudio = "preRecordingBar.doNotRecordAudio"

  // Display service
  static let displayServiceScreen = "displayService.screen"
  static let displayServiceApp = "displayService.app"

  // Recording indicator
  static let recordingIndicatorStopping = "recordingIndicator.stopping"
  static let recordingIndicatorPauseRecording = "recordingIndicator.pauseRecording"
  static let recordingIndicatorResumeRecording = "recordingIndicator.resumeRecording"
  static let recordingIndicatorInProgressLabel = "recordingIndicator.inProgressLabel"
  static let recordingIndicatorPausedLabel = "recordingIndicator.pausedLabel"
  static let recordingIndicatorStoppingRecording = "recordingIndicator.stoppingRecording"
  static let recordingIndicatorHelpPause = "recordingIndicator.helpPause"
  static let recordingIndicatorHelpResume = "recordingIndicator.helpResume"
  static let recordingIndicatorHelpStopping = "recordingIndicator.helpStopping"
}
