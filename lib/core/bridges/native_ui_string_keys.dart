/// Keys for native UI strings that are fetched from Flutter localization.
///
/// These are used by native macOS code (menu bar, etc.) to request
/// localized strings from Flutter.
///
/// IMPORTANT: Keep this in sync with `NativeUIStringKey.swift` on the native side.
abstract class NativeUIStringKey {
  NativeUIStringKey._();

  // Menu bar items
  static const String menuStartRecording = 'menu.startRecording';
  static const String menuStopRecording = 'menu.stopRecording';
  static const String menuOpenApp = 'menu.openApp';
  static const String menuQuit = 'menu.quit';

  // Accessibility descriptions
  static const String accessibilityStartRecording =
      'accessibility.startRecording';
  static const String accessibilityStopRecording =
      'accessibility.stopRecording';
  static const String recordingSelectedMicFallbackWarning =
      'recording.selectedMicFallbackWarning';
  static const String recordingSelectedMicFallbackFailure =
      'recording.selectedMicFallbackFailure';

  // Pre-recording bar
  static const String preRecordingBarDisplay = 'preRecordingBar.display';
  static const String preRecordingBarWindow = 'preRecordingBar.window';
  static const String preRecordingBarArea = 'preRecordingBar.area';
  static const String preRecordingBarCamera = 'preRecordingBar.camera';
  static const String preRecordingBarMic = 'preRecordingBar.mic';
  static const String preRecordingBarSystem = 'preRecordingBar.system';
  static const String preRecordingBarUpdate = 'preRecordingBar.update';
  static const String preRecordingBarPause = 'preRecordingBar.pause';
  static const String preRecordingBarResume = 'preRecordingBar.resume';
  static const String preRecordingBarNone = 'preRecordingBar.none';
  static const String preRecordingBarRefresh = 'preRecordingBar.refresh';
  static const String preRecordingBarSelectDisplay =
      'preRecordingBar.selectDisplay';
  static const String preRecordingBarSelectWindow =
      'preRecordingBar.selectWindow';
  static const String preRecordingBarSelectMicrophone =
      'preRecordingBar.selectMicrophone';
  static const String preRecordingBarSelectCamera =
      'preRecordingBar.selectCamera';
  static const String preRecordingBarUnknownDisplay =
      'preRecordingBar.unknownDisplay';
  static const String preRecordingBarUnknownWindow =
      'preRecordingBar.unknownWindow';
  static const String preRecordingBarUnknownMic = 'preRecordingBar.unknownMic';
  static const String preRecordingBarUnknownCamera =
      'preRecordingBar.unknownCamera';
  static const String preRecordingBarNoCamera = 'preRecordingBar.noCamera';
  static const String preRecordingBarDoNotRecordAudio =
      'preRecordingBar.doNotRecordAudio';

  // Display service
  static const String displayServiceScreen = 'displayService.screen';
  static const String displayServiceApp = 'displayService.app';

  // Recording indicator
  static const String recordingIndicatorStopping =
      'recordingIndicator.stopping';
  static const String recordingIndicatorPauseRecording =
      'recordingIndicator.pauseRecording';
  static const String recordingIndicatorResumeRecording =
      'recordingIndicator.resumeRecording';
  static const String recordingIndicatorInProgressLabel =
      'recordingIndicator.inProgressLabel';
  static const String recordingIndicatorPausedLabel =
      'recordingIndicator.pausedLabel';
  static const String recordingIndicatorStoppingRecording =
      'recordingIndicator.stoppingRecording';
  static const String recordingIndicatorHelpPause =
      'recordingIndicator.helpPause';
  static const String recordingIndicatorHelpResume =
      'recordingIndicator.helpResume';
  static const String recordingIndicatorHelpStopping =
      'recordingIndicator.helpStopping';

  /// All keys that native code may request.
  static const List<String> allKeys = [
    menuStartRecording,
    menuStopRecording,
    menuOpenApp,
    menuQuit,
    accessibilityStartRecording,
    accessibilityStopRecording,
    recordingSelectedMicFallbackWarning,
    recordingSelectedMicFallbackFailure,
    preRecordingBarDisplay,
    preRecordingBarWindow,
    preRecordingBarArea,
    preRecordingBarCamera,
    preRecordingBarMic,
    preRecordingBarSystem,
    preRecordingBarUpdate,
    preRecordingBarPause,
    preRecordingBarResume,
    preRecordingBarNone,
    preRecordingBarRefresh,
    preRecordingBarSelectDisplay,
    preRecordingBarSelectWindow,
    preRecordingBarSelectMicrophone,
    preRecordingBarSelectCamera,
    preRecordingBarUnknownDisplay,
    preRecordingBarUnknownWindow,
    preRecordingBarUnknownMic,
    preRecordingBarUnknownCamera,
    preRecordingBarNoCamera,
    preRecordingBarDoNotRecordAudio,
    displayServiceScreen,
    displayServiceApp,
    recordingIndicatorStopping,
    recordingIndicatorPauseRecording,
    recordingIndicatorResumeRecording,
    recordingIndicatorInProgressLabel,
    recordingIndicatorPausedLabel,
    recordingIndicatorStoppingRecording,
    recordingIndicatorHelpPause,
    recordingIndicatorHelpResume,
    recordingIndicatorHelpStopping,
  ];
}
