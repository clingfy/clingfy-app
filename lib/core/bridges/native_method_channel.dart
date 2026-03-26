/// Method channel and event channel names shared between Flutter and native.
///
/// IMPORTANT: Keep this in sync with Swift constants.
abstract class NativeChannel {
  NativeChannel._();

  /// Main method channel for screen recorder commands.
  static const String screenRecorder = 'com.clingfy/screen_recorder';

  /// Event channel for device change notifications.
  static const String screenRecorderEvents =
      'com.clingfy/screen_recorder/events';

  /// Event channel for player events.
  static const String playerEvents = 'com.clingfy/player/events';

  /// Event channel for recording and preview workflow lifecycle events.
  static const String workflowEvents = 'com.clingfy/workflow/events';

  /// Event channel for Sparkle updates.
  static const String updaterEvents = 'com.clingfy/updater/events';
}

/// Method names for native → Flutter calls.
///
/// IMPORTANT: Keep this in sync with Swift.
abstract class NativeToFlutterMethod {
  NativeToFlutterMethod._();

  static const String log = 'log';
  static const String indicatorStopTapped = 'indicatorStopTapped';
  static const String indicatorResumeTapped = 'indicatorResumeTapped';
  static const String menuBarToggleRequest = 'menuBarToggleRequest';
  static const String updateExportProgress = 'updateExportProgress';
  static const String preRecordingBarAction = 'preRecordingBarAction';
  static const String nativeSelectionChanged = 'nativeSelectionChanged';
  static const String cameraOverlayMoved = 'cameraOverlayMoved';
  static const String areaSelectionCleared = 'areaSelectionCleared';

  /// Called by native to request localized strings from Flutter.
  static const String getLocalizedStrings = 'getLocalizedStrings';
}

/// Device event types from native EventChannel.
///
/// IMPORTANT: Keep this in sync with Swift.
abstract class DeviceEventType {
  DeviceEventType._();

  static const String audioSourcesChanged = 'audioSourcesChanged';
  static const String videoSourcesChanged = 'videoSourcesChanged';
  static const String microphoneLevel = 'microphoneLevel';
}
