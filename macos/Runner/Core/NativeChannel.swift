import Foundation

/// Method channel and event channel names shared between Flutter and native.
///
/// IMPORTANT: Keep this in sync with `native_method_channel.dart` on the Flutter side.
enum NativeChannel {
  /// Main method channel for screen recorder commands.
  static let screenRecorder = "com.clingfy/screen_recorder"

  /// Event channel for device change notifications.
  static let screenRecorderEvents = "com.clingfy/screen_recorder/events"

  /// Event channel for player events.
  static let playerEvents = "com.clingfy/player/events"

  /// Event channel for recording and preview workflow lifecycle events.
  static let workflowEvents = "com.clingfy/workflow/events"
}

/// Method names for native → Flutter calls.
///
/// IMPORTANT: Keep this in sync with `native_method_channel.dart` on the Flutter side.
enum NativeToFlutterMethod {
  static let log = "log"
  static let indicatorPauseTapped = "indicatorPauseTapped"
  static let indicatorStopTapped = "indicatorStopTapped"
  static let indicatorResumeTapped = "indicatorResumeTapped"
  static let menuBarToggleRequest = "menuBarToggleRequest"
  static let updateExportProgress = "updateExportProgress"
  static let preRecordingBarAction = "preRecordingBarAction"
  static let nativeSelectionChanged = "nativeSelectionChanged"
  static let cameraOverlayMoved = "cameraOverlayMoved"
  static let areaSelectionCleared = "areaSelectionCleared"

  /// Called by native to request localized strings from Flutter.
  static let getLocalizedStrings = "getLocalizedStrings"
}
