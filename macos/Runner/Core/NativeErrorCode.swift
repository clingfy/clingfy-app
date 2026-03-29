import Foundation

/// Error codes shared between Flutter and native (macOS/Windows).
///
/// These codes are returned to Flutter via FlutterError.code
/// and mapped to localized strings in Flutter.
///
/// IMPORTANT: Keep this in sync with `native_error_codes.dart` on the Flutter side.
enum NativeErrorCode {
  // Recording lifecycle errors
  static let alreadyRecording = "ALREADY_RECORDING"
  static let notRecording = "NOT_RECORDING"
  static let invalidRecordingState = "INVALID_RECORDING_STATE"
  static let pauseResumeUnsupported = "PAUSE_RESUME_UNSUPPORTED"

  // Target selection errors
  static let noWindowSelected = "NO_WINDOW_SELECTED"
  static let windowNotAvailable = "WINDOW_NOT_AVAILABLE"
  static let noAreaSelected = "NO_AREA_SELECTED"
  static let targetError = "TARGET_ERROR"

  // Device errors
  static let unknownAudioDevice = "UNKNOWN_AUDIO_DEVICE"

  // Configuration errors
  static let badQuality = "BAD_QUALITY"
  static let badArgs = "BAD_ARGS"
  static let badMode = "BAD_MODE"
  static let invalidArgument = "INVALID_ARGUMENT"

  // Permission errors
  static let screenRecordingPermission = "SCREEN_RECORDING_PERMISSION"
  static let microphonePermissionRequired = "MICROPHONE_PERMISSION_REQUIRED"
  static let accessibilityPermissionRequired = "ACCESSIBILITY_PERMISSION_REQUIRED"
  static let cameraPermissionDenied = "CAMERA_PERMISSION_DENIED"

  // Recording/export errors
  static let recordingError = "RECORDING_ERROR"
  static let outputUrlError = "OUTPUT_URL_ERROR"
  static let exportError = "EXPORT_ERROR"
  static let exportInputMissing = "EXPORT_INPUT_MISSING"
  static let advancedCameraExportFailed = "ADVANCED_CAMERA_EXPORT_FAILED"

  // File errors
  static let videoFileMissing = "VIDEO_FILE_MISSING"
  static let cursorFileMissing = "CURSOR_FILE_MISSING"
  static let assetInvalid = "ASSET_INVALID"
  static let fileNotFound = "FILE_NOT_FOUND"

  // Camera errors
  static let noCamera = "NO_CAMERA"
  static let cameraInputError = "CAMERA_INPUT_ERROR"
}
