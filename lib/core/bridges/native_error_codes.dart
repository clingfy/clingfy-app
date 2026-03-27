/// Error codes shared between Flutter and native (macOS/Windows).
///
/// These codes are returned by the native side via PlatformException.code
/// and mapped to localized strings in Flutter.
///
/// IMPORTANT: Keep this in sync with `NativeErrorCode.swift` on the native side.
abstract class NativeErrorCode {
  NativeErrorCode._();

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
  static const String outputUrlError = 'OUTPUT_URL_ERROR';
  static const String exportError = 'EXPORT_ERROR';
  static const String exportInputMissing = 'EXPORT_INPUT_MISSING';

  // File errors
  static const String videoFileMissing = 'VIDEO_FILE_MISSING';
  static const String cursorFileMissing = 'CURSOR_FILE_MISSING';
  static const String assetInvalid = 'ASSET_INVALID';
  static const String fileNotFound = 'FILE_NOT_FOUND';

  // Camera errors
  static const String noCamera = 'NO_CAMERA';
  static const String cameraInputError = 'CAMERA_INPUT_ERROR';
}
