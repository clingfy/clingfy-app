#ifndef RUNNER_BRIDGE_NATIVE_ERROR_CODES_H_
#define RUNNER_BRIDGE_NATIVE_ERROR_CODES_H_

// Error codes returned by the native Windows engine through method-channel
// results.
//
// IMPORTANT: Keep these in sync with `NativeErrorCode` on the Dart side
// (lib/core/bridges/native_error_codes.dart) and the Swift equivalent
// (macos/Runner/Core/NativeErrorCode.swift). Adding a new code requires
// updating all three.
namespace clingfy::bridge::error {

// Generic "this method isn't implemented on Windows yet". Used by the Phase 0
// scaffold so the UI can show a friendly message instead of leaking a raw
// MissingPluginException through every recorder action.
inline constexpr const char* kWindowsNotImplemented =
    "WINDOWS_NOT_IMPLEMENTED";

// Recording lifecycle errors.
inline constexpr const char* kAlreadyRecording = "ALREADY_RECORDING";
inline constexpr const char* kNotRecording = "NOT_RECORDING";
inline constexpr const char* kInvalidRecordingState =
    "INVALID_RECORDING_STATE";
inline constexpr const char* kPauseResumeUnsupported =
    "PAUSE_RESUME_UNSUPPORTED";

// Target selection errors.
inline constexpr const char* kNoWindowSelected = "NO_WINDOW_SELECTED";
inline constexpr const char* kWindowNotAvailable = "WINDOW_NOT_AVAILABLE";
inline constexpr const char* kNoAreaSelected = "NO_AREA_SELECTED";
inline constexpr const char* kTargetError = "TARGET_ERROR";

// Device errors.
inline constexpr const char* kUnknownAudioDevice = "UNKNOWN_AUDIO_DEVICE";

// Configuration errors.
inline constexpr const char* kBadQuality = "BAD_QUALITY";
inline constexpr const char* kBadArgs = "BAD_ARGS";
inline constexpr const char* kBadMode = "BAD_MODE";
inline constexpr const char* kInvalidArgument = "INVALID_ARGUMENT";

// Permission errors.
inline constexpr const char* kScreenRecordingPermission =
    "SCREEN_RECORDING_PERMISSION";
inline constexpr const char* kMicrophonePermissionRequired =
    "MICROPHONE_PERMISSION_REQUIRED";
inline constexpr const char* kAccessibilityPermissionRequired =
    "ACCESSIBILITY_PERMISSION_REQUIRED";
inline constexpr const char* kCameraPermissionDenied =
    "CAMERA_PERMISSION_DENIED";

// Recording / export errors.
inline constexpr const char* kRecordingError = "RECORDING_ERROR";
inline constexpr const char* kOutputUrlError = "OUTPUT_URL_ERROR";
inline constexpr const char* kExportError = "EXPORT_ERROR";
inline constexpr const char* kExportInputMissing = "EXPORT_INPUT_MISSING";
inline constexpr const char* kExportDiskFull = "EXPORT_DISK_FULL";
inline constexpr const char* kAdvancedCameraExportFailed =
    "ADVANCED_CAMERA_EXPORT_FAILED";

// File errors.
inline constexpr const char* kVideoFileMissing = "VIDEO_FILE_MISSING";
inline constexpr const char* kCursorFileMissing = "CURSOR_FILE_MISSING";
inline constexpr const char* kAssetInvalid = "ASSET_INVALID";
inline constexpr const char* kFileNotFound = "FILE_NOT_FOUND";

// Camera errors.
inline constexpr const char* kNoCamera = "NO_CAMERA";
inline constexpr const char* kCameraInputError = "CAMERA_INPUT_ERROR";

}  // namespace clingfy::bridge::error

#endif  // RUNNER_BRIDGE_NATIVE_ERROR_CODES_H_
