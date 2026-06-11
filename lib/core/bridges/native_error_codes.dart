/// Error codes shared between Flutter and native (macOS/Windows).
///
/// These codes are returned by the native side via PlatformException.code
/// and mapped to localized strings in Flutter.
///
/// IMPORTANT: Keep this in sync with `NativeErrorCode.swift` on macOS and
/// `windows/runner/Bridge/native_error_codes.h` on Windows.
abstract class NativeErrorCode {
  NativeErrorCode._();

  /// Returned by the native Windows engine when a method is recognized but
  /// hasn't been ported yet. The Phase 0 catch-all returns this for every
  /// call so the UI can show a friendly "not available on Windows yet"
  /// message instead of a raw MissingPluginException.
  static const String windowsNotImplemented = 'WINDOWS_NOT_IMPLEMENTED';

  // Recording lifecycle errors
  static const String alreadyRecording = 'ALREADY_RECORDING';
  static const String notRecording = 'NOT_RECORDING';
  static const String invalidRecordingState = 'INVALID_RECORDING_STATE';
  static const String pauseResumeUnsupported = 'PAUSE_RESUME_UNSUPPORTED';

  // Target selection errors
  static const String noWindowSelected = 'NO_WINDOW_SELECTED';
  static const String windowNotAvailable = 'WINDOW_NOT_AVAILABLE';
  static const String noAreaSelected = 'NO_AREA_SELECTED';
  static const String targetError = 'TARGET_ERROR';

  // Device errors
  static const String unknownAudioDevice = 'UNKNOWN_AUDIO_DEVICE';

  // Configuration errors
  static const String badQuality = 'BAD_QUALITY';
  static const String badArgs = 'BAD_ARGS';
  static const String badMode = 'BAD_MODE';
  static const String invalidArgument = 'INVALID_ARGUMENT';

  // Permission errors
  static const String screenRecordingPermission = 'SCREEN_RECORDING_PERMISSION';
  static const String microphonePermissionRequired =
      'MICROPHONE_PERMISSION_REQUIRED';
  static const String accessibilityPermissionRequired =
      'ACCESSIBILITY_PERMISSION_REQUIRED';
  static const String cameraPermissionDenied = 'CAMERA_PERMISSION_DENIED';

  // Recording/export errors
  static const String recordingError = 'RECORDING_ERROR';
  static const String recordingDiskFull = 'RECORDING_DISK_FULL';
  static const String outputUrlError = 'OUTPUT_URL_ERROR';
  static const String exportError = 'EXPORT_ERROR';
  static const String exportCancelled = 'EXPORT_CANCELLED';
  static const String exportInputMissing = 'EXPORT_INPUT_MISSING';
  static const String exportDiskFull = 'EXPORT_DISK_FULL';
  static const String advancedCameraExportFailed =
      'ADVANCED_CAMERA_EXPORT_FAILED';

  // Preview errors. `PREVIEW_INPUT_MISSING`/`SCENE_INPUT_MISSING` mean the
  // project bundle (or a required file inside it) could not be read;
  // `PREVIEW_OPEN_ERROR` means the bundle was fine but the preview engine
  // itself failed to open. PREVIEW_OPEN_ERROR is also synthesized by Dart
  // when a non-PlatformException escapes the previewOpen call.
  static const String previewInputMissing = 'PREVIEW_INPUT_MISSING';
  static const String sceneInputMissing = 'SCENE_INPUT_MISSING';
  static const String previewOpenError = 'PREVIEW_OPEN_ERROR';

  /// The preview opened fine but rendering died mid-flight (device loss /
  /// D2DERR_RECREATE_TARGET class) — Windows emits it once per session
  /// after a run of consecutive frame failures.
  static const String previewRenderError = 'PREVIEW_RENDER_ERROR';

  // A native handler threw an unexpected exception; the Windows MethodRouter
  // dispatch barrier converts it into this error instead of crashing.
  static const String internalError = 'INTERNAL_ERROR';

  // File errors
  static const String videoFileMissing = 'VIDEO_FILE_MISSING';
  static const String cursorFileMissing = 'CURSOR_FILE_MISSING';
  static const String assetInvalid = 'ASSET_INVALID';
  static const String fileNotFound = 'FILE_NOT_FOUND';

  // Camera errors
  static const String noCamera = 'NO_CAMERA';
  static const String cameraInputError = 'CAMERA_INPUT_ERROR';
}

/// Error codes that DART synthesizes locally — native never emits these.
///
/// They exist so locally-detected failures (timeouts waiting on workflow
/// events that never arrived, malformed native payloads) flow through the
/// exact same `errorCode` → `HomeErrorMapper` pipeline as native
/// PlatformException codes. Do NOT add them to the native headers or to
/// `NativeErrorCode` above; the three-way contract sync test only checks
/// native-declared codes.
abstract class DartSynthesizedErrorCode {
  DartSynthesizedErrorCode._();

  /// Phase 10.4 watchdog: `startRecording` was issued but neither
  /// `recordingStarted` nor `recordingFailed` ever arrived.
  static const String recordingStartTimeout = 'RECORDING_START_TIMEOUT';

  /// Phase 10.4 watchdog: `stopRecording` completed but the
  /// `recordingFinalized` event never arrived.
  static const String recordingFinalizeTimeout = 'RECORDING_FINALIZE_TIMEOUT';

  /// Phase 10.4 watchdog: preview open/loading never reached
  /// `previewReady`/`previewFailed`.
  static const String previewTimeout = 'PREVIEW_TIMEOUT';

  /// A `recordingFinalized` event arrived without a usable `projectPath`.
  static const String recordingFinalizeError = 'RECORDING_FINALIZE_ERROR';

  /// A `previewFailed` event arrived without any `code`/`reason` payload.
  static const String previewError = 'PREVIEW_ERROR';
}
