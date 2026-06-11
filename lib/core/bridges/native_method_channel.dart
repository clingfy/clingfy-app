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

/// Method names for Flutter → native calls.
///
/// Most invocations still use inline string literals at the `invokeMethod`
/// call sites; new Phase 10.4+ methods get constants here.
///
/// IMPORTANT: Keep this in sync with Swift and with the Windows
/// MethodRouter (`windows/runner/Bridge`).
abstract class NativeMethod {
  NativeMethod._();

  /// Phase 10.4 (Windows): runs the native crash-recovery sweep and returns
  /// `{interruptedProjects: [{projectPath, sessionId}], cleanedTempFileCount,
  /// cleanedTempBytes}`. Not implemented on macOS.
  static const String getStartupRecoveryReport = 'getStartupRecoveryReport';

  /// Phase 10.4 (Windows, dev-only): deliberately crashes the native process
  /// to exercise the crash pipeline. Native replies with an error unless the
  /// CLINGFY_CRASH_TEST=1 environment variable is set.
  static const String debugForceNativeCrash = 'debugForceNativeCrash';
}

/// Method names for native → Flutter calls.
///
/// IMPORTANT: Keep this in sync with Swift.
abstract class NativeToFlutterMethod {
  NativeToFlutterMethod._();

  static const String log = 'log';
  static const String indicatorPauseTapped = 'indicatorPauseTapped';
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

/// `type` values carried by events on the [NativeChannel.workflowEvents]
/// channel (recording + preview lifecycle).
///
/// IMPORTANT: Keep this in sync with Swift and with the Windows
/// `workflow_event_publisher`.
abstract class WorkflowEventType {
  WorkflowEventType._();

  static const String recordingStarted = 'recordingStarted';
  static const String recordingPaused = 'recordingPaused';
  static const String recordingResumed = 'recordingResumed';
  static const String recordingFinalized = 'recordingFinalized';

  /// Legacy alias for [recordingFinalized] still emitted by some macOS
  /// paths — handled identically on the Dart side.
  static const String recordingFinished = 'recordingFinished';
  static const String recordingFailed = 'recordingFailed';
  static const String recordingWarning = 'recordingWarning';
  static const String previewPreparing = 'previewPreparing';
  static const String previewReady = 'previewReady';
  static const String previewFailed = 'previewFailed';
  static const String previewClosed = 'previewClosed';

  /// Finder/Explorer "open project with Clingfy" request; consumed by
  /// [NativeBridge] itself, ignored by RecordingController.
  static const String openProjectRequest = 'openProjectRequest';
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
