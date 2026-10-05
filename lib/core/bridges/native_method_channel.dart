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

  /// Returns `{route: 'speakers' | 'headphones' | 'unknown'}` for the current
  /// default audio-output device.
  ///
  /// Speaker playback is the precondition for the speaker -> mic bleed that
  /// makes a recording come back with a doubled, delayed soundtrack, so the
  /// recording UI warns before a take when system audio is on and output is
  /// audible in the room. macOS only; other platforms reply with a
  /// `MissingPluginException`, which the bridge maps to `unknown`.
  static const String getAudioOutputRoute = 'getAudioOutputRoute';

  /// What the on-device speech model costs on disk, and whether it can be
  /// deleted right now. Deliberately not part of `getStorageSnapshot`: that
  /// payload is a fixed shape on a timer, this is asked for by one page.
  static const String getCaptionModelInfo = 'getCaptionModelInfo';

  /// Unloads and removes the speech model. Returns `{freedBytes}`; fails with
  /// `MODEL_IN_USE` while a transcription is running.
  static const String deleteCaptionModel = 'deleteCaptionModel';

  /// The pixel size the exported frames will be. Args `{projectPath,
  /// layoutPreset, resolutionPreset, format, gifSize}`, reply `{width, height}`.
  ///
  /// Asked rather than computed because the `auto` resolution preset resolves
  /// against the recording's own oriented video track, which only native has
  /// read. Caption bitmaps are rasterised at this size.
  ///
  /// `format` and `gifSize` are part of the question because a GIF does NOT
  /// render at the resolution preset: the exporter caps its intermediate to the
  /// GIF long-edge preset, so a caption rasterised for the uncapped canvas is
  /// composited roughly 1.8x too large in the file. Older native builds ignore
  /// both keys and answer the uncapped size — which is also what they render.
  ///
  /// macOS only today; Windows replies with a `MissingPluginException`, which
  /// the bridge maps to null so the caller skips burn-in rather than guessing.
  static const String resolveExportSize = 'resolveExportSize';

  /// Flashes a large ordinal (and the monitor's name) on physical displays and
  /// auto-dismisses.
  ///
  /// Args `{durationMs, only, onlyDisplayId, labels}`, where `labels` maps a
  /// stringified display id to the label this side is rendering for it.
  ///
  /// `only == false` flashes every display — the Identify sweep. `only == true`
  /// with an id flashes that one display; with a null id it flashes whatever
  /// the platform would actually capture right now, which is the Clingfy
  /// window's display on macOS and the primary monitor on Windows.
  ///
  /// Replies with the display snapshot that was painted, in the same
  /// list-of-maps shape as `getDisplays`, so the picker can adopt exactly what
  /// is on the glass. macOS + Windows. Older native builds reply with a
  /// `MissingPluginException`, which the bridge maps to
  /// `IdentifyDisplaysResult.unsupported` so the UI hides the control.
  static const String identifyDisplays = 'identifyDisplays';
  // The rest of the Flutter -> native surface. These carry no doc comment
  // each because the name IS the contract and the Dart method that wraps
  // them documents the arguments; the seven above are annotated because
  // their payload or platform support is not obvious from the name.

  // --- Recording lifecycle ---
  static const String pauseRecording = 'pauseRecording';
  static const String resumeRecording = 'resumeRecording';
  static const String startRecording = 'startRecording';
  static const String stopRecording = 'stopRecording';
  static const String togglePauseRecording = 'togglePauseRecording';

  // --- Recording settings ---
  static const String getExcludeMicFromSystemAudio =
      'getExcludeMicFromSystemAudio';
  static const String getExcludeRecorderApp = 'getExcludeRecorderApp';
  static const String setCaptureFrameRate = 'setCaptureFrameRate';
  static const String setDisplayTargetMode = 'setDisplayTargetMode';
  static const String setExcludeMicFromSystemAudio =
      'setExcludeMicFromSystemAudio';
  static const String setExcludeRecorderApp = 'setExcludeRecorderApp';
  static const String setFileNameTemplate = 'setFileNameTemplate';
  static const String setMicEchoCancellationEnabled =
      'setMicEchoCancellationEnabled';
  static const String setRecordingIndicatorPinned =
      'setRecordingIndicatorPinned';
  static const String setRecordingQuality = 'setRecordingQuality';

  // --- Capture targets and devices ---
  static const String setAppWindowTarget = 'setAppWindowTarget';
  static const String setAppWindowWatchActive = 'setAppWindowWatchActive';
  static const String setAudioSource = 'setAudioSource';
  static const String setDisplay = 'setDisplay';
  static const String setVideoSource = 'setVideoSource';

  // --- Area selection ---
  static const String clearAreaRecordingSelection =
      'clearAreaRecordingSelection';
  static const String pickAreaRecordingRegion = 'pickAreaRecordingRegion';
  static const String revealAreaRecordingRegion = 'revealAreaRecordingRegion';

  // --- Pre-recording bar ---
  static const String setPreRecordingBarEnabled = 'setPreRecordingBarEnabled';
  static const String setPreRecordingBarState = 'setPreRecordingBarState';
  static const String showPreRecordingBar = 'showPreRecordingBar';
  static const String togglePreRecordingBar = 'togglePreRecordingBar';

  // --- Camera overlay ---
  static const String setCameraOverlayBorder = 'setCameraOverlayBorder';
  static const String setCameraOverlayBorderColor =
      'setCameraOverlayBorderColor';
  static const String setCameraOverlayBorderWidth =
      'setCameraOverlayBorderWidth';
  static const String setCameraOverlayCustomPosition =
      'setCameraOverlayCustomPosition';
  static const String setCameraOverlayHighlight = 'setCameraOverlayHighlight';
  static const String setCameraOverlayHighlightStrength =
      'setCameraOverlayHighlightStrength';
  static const String setCameraOverlayOpacity = 'setCameraOverlayOpacity';
  static const String setCameraOverlayPosition = 'setCameraOverlayPosition';
  static const String setCameraOverlayRoundness = 'setCameraOverlayRoundness';
  static const String setCameraOverlayShadow = 'setCameraOverlayShadow';
  static const String setCameraOverlayShape = 'setCameraOverlayShape';
  static const String setCameraOverlaySize = 'setCameraOverlaySize';
  static const String setCameraPreviewMode = 'setCameraPreviewMode';
  static const String setChromaKeyColor = 'setChromaKeyColor';
  static const String setChromaKeyEnabled = 'setChromaKeyEnabled';
  static const String setChromaKeyStrength = 'setChromaKeyStrength';
  static const String setOverlayEnabled = 'setOverlayEnabled';
  static const String setOverlayLinkedToRecording =
      'setOverlayLinkedToRecording';
  static const String setOverlayMirror = 'setOverlayMirror';

  // --- Cursor ---
  static const String setCursorHighlightEnabled = 'setCursorHighlightEnabled';
  static const String setCursorHighlightLinkedToRecording =
      'setCursorHighlightLinkedToRecording';

  // --- Preview playback ---
  static const String previewClose = 'previewClose';
  static const String previewPause = 'previewPause';
  static const String previewPeekTo = 'previewPeekTo';
  static const String previewPlay = 'previewPlay';
  static const String previewSeekTo = 'previewSeekTo';

  // --- Preview composition ---
  static const String canvasPresetThumbnail = 'canvasPresetThumbnail';
  static const String previewSetCameraPlacement = 'previewSetCameraPlacement';
  static const String previewSetCanvas = 'previewSetCanvas';
  static const String previewSetCaptions = 'previewSetCaptions';
  static const String previewSetClips = 'previewSetClips';
  static const String previewSetColorGrade = 'previewSetColorGrade';
  static const String previewSetVoiceCleanup = 'previewSetVoiceCleanup';
  static const String previewSetZoomSegments = 'previewSetZoomSegments';
  static const String updateAudioPreview = 'updateAudioPreview';

  // --- Zoom ---
  static const String getManualZoomSegments = 'getManualZoomSegments';
  static const String getZoomSegments = 'getZoomSegments';
  static const String saveManualZoomSegments = 'saveManualZoomSegments';

  // --- Export ---
  static const String cancelExport = 'cancelExport';
  static const String exportVideo = 'exportVideo';
  static const String processVideo = 'processVideo';

  // --- Captions ---
  static const String cancelCaptions = 'cancelCaptions';

  // --- Permissions ---
  static const String getPermissionStatus = 'getPermissionStatus';
  static const String getWindowsPermissionDetails =
      'getWindowsPermissionDetails';
  static const String openAccessibilitySettings = 'openAccessibilitySettings';
  static const String openScreenRecordingSettings =
      'openScreenRecordingSettings';
  static const String openSystemSettings = 'openSystemSettings';
  static const String requestCameraPermission = 'requestCameraPermission';
  static const String requestMicrophonePermission =
      'requestMicrophonePermission';
  static const String requestScreenRecordingPermission =
      'requestScreenRecordingPermission';

  // --- Files and folders ---
  static const String chooseSaveFolder = 'chooseSaveFolder';
  static const String getSaveFolder = 'getSaveFolder';
  static const String getTodayLogFilePath = 'getTodayLogFilePath';
  static const String openSaveFolder = 'openSaveFolder';
  static const String pickImage = 'pickImage';
  static const String resetSaveFolder = 'resetSaveFolder';
  static const String revealFile = 'revealFile';
  static const String revealLogsFolder = 'revealLogsFolder';
  static const String revealRecordingsFolder = 'revealRecordingsFolder';
  static const String revealTempFolder = 'revealTempFolder';
  static const String revealTodayLogFile = 'revealTodayLogFile';

  // --- Logging ---
  static const String flushPendingNativeLogs = 'flushPendingNativeLogs';
  static const String setNativeLogLevel = 'setNativeLogLevel';

  // --- Localization ---
  static const String cacheLocalizedStrings = 'cacheLocalizedStrings';

  // --- Updates and app lifecycle ---
  static const String checkForUpdates = 'checkForUpdates';
  static const String relaunchApp = 'relaunchApp';
  // --- Capability probes ---
  static const String captionsCapability = 'captionsCapability';
  static const String getRecordingCapabilities = 'getRecordingCapabilities';
  static const String previewGetZoomCapabilities = 'previewGetZoomCapabilities';

  // --- Device and display enumeration ---
  static const String getAppWindows = 'getAppWindows';
  static const String getAudioSources = 'getAudioSources';
  static const String getDisplays = 'getDisplays';
  static const String getVideoSources = 'getVideoSources';

  // --- Preview queries ---
  static const String getRecordingSceneInfo = 'getRecordingSceneInfo';
  static const String previewGetCursorSamples = 'previewGetCursorSamples';
  static const String previewGetSourceDimensions = 'previewGetSourceDimensions';
  static const String previewOpen = 'previewOpen';

  // --- Captions ---
  static const String generateCaptions = 'generateCaptions';

  // --- Storage and diagnostics ---
  static const String clearCachedRecordings = 'clearCachedRecordings';
  static const String getCaptureDiagnostics = 'getCaptureDiagnostics';
  static const String getStorageSnapshot = 'getStorageSnapshot';
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

/// `type` values carried by events on the [NativeChannel.playerEvents]
/// channel (preview transport + player state).
///
/// The long-standing types (playerTick / playerState / playerError /
/// playerWarning) are still inline literals in
/// `PlayerController._listenPlayer`; new types get constants here.
///
/// IMPORTANT: Keep this in sync with Swift and with the Windows
/// `player_event_publisher`.
abstract class PlayerEventType {
  PlayerEventType._();

  /// Windows-only: the native D3D device backing the active preview session
  /// is gone or suspect (Modern Standby / suspend resume). Dart silently
  /// closes and reopens the preview in place — same session id, no phase
  /// change — instead of surfacing an error. Payload:
  /// `{type, sessionId, reason}`.
  static const String previewInvalidated = 'previewInvalidated';
}

/// `reason` values carried by [PlayerEventType.previewInvalidated].
///
/// IMPORTANT: Keep this in sync with the emit sites in the Windows runner
/// (`preview_engine.cpp`). An unrecognised reason still rebuilds — the reason
/// only selects how loudly it is reported, so a new native reason degrades to
/// the fault wording rather than being ignored.
abstract class PreviewInvalidationReason {
  PreviewInvalidationReason._();

  /// The D3D device backing the session is gone or suspect (Modern Standby /
  /// suspend resume). A genuine fault: logged as a warning, and a failed
  /// rebuild is a blocking error.
  static const String systemResume = 'systemResume';

  /// The canvas layout changed the aspect the shared texture must have, and a
  /// registered texture cannot be resized in place. NOT a fault — this is the
  /// expected consequence of the user picking a different layout preset, so it
  /// logs at info and a failed rebuild reports the layout, not sleep.
  static const String canvasAspectChanged = 'canvasAspectChanged';
}

/// Device event types from native EventChannel.
///
/// IMPORTANT: Keep this in sync with Swift.
abstract class DeviceEventType {
  DeviceEventType._();

  static const String audioSourcesChanged = 'audioSourcesChanged';
  static const String videoSourcesChanged = 'videoSourcesChanged';
  static const String displaysChanged = 'displaysChanged';
  static const String appWindowsChanged = 'appWindowsChanged';
  static const String audioOutputRouteChanged = 'audioOutputRouteChanged';
  static const String microphoneLevel = 'microphoneLevel';
}
