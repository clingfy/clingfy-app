#ifndef RUNNER_BRIDGE_RECORDING_WARNING_CODES_H_
#define RUNNER_BRIDGE_RECORDING_WARNING_CODES_H_

// Machine-readable codes carried by Windows `recordingWarning` events
// (Phase 10.2). Until Phase 10.4 these lived as repeated string literals at
// the emit sites in recording_engine.cpp; a typo there would silently fall
// through to the Dart mapper's verbatim fallback.
//
// IMPORTANT: Keep this list in sync with `RecordingWarningCode` on the Dart
// side (lib/core/bridges/recording_warning_codes.dart) and the emitter
// documentation in workflow_event_publisher.h. macOS warnings never carry a
// code (macOS localizes natively before emitting).
namespace clingfy::bridge::warning {

inline constexpr const char* kMicOpenFailed = "MIC_OPEN_FAILED";
inline constexpr const char* kMicDisconnected = "MIC_DISCONNECTED";
inline constexpr const char* kSystemAudioOpenFailed =
    "SYSTEM_AUDIO_OPEN_FAILED";
inline constexpr const char* kSystemAudioStopped = "SYSTEM_AUDIO_STOPPED";
inline constexpr const char* kCameraUnavailable = "CAMERA_UNAVAILABLE";
inline constexpr const char* kCameraOpenFailed = "CAMERA_OPEN_FAILED";
inline constexpr const char* kCameraDisconnected = "CAMERA_DISCONNECTED";
inline constexpr const char* kEncoderVideoError = "ENCODER_VIDEO_ERROR";
inline constexpr const char* kEncoderAudioError = "ENCODER_AUDIO_ERROR";
inline constexpr const char* kWindowClosedPartialSaved =
    "WINDOW_CLOSED_PARTIAL_SAVED";
inline constexpr const char* kDisplayDisconnectedPartialSaved =
    "DISPLAY_DISCONNECTED_PARTIAL_SAVED";

}  // namespace clingfy::bridge::warning

#endif  // RUNNER_BRIDGE_RECORDING_WARNING_CODES_H_
