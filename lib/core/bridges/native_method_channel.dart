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
