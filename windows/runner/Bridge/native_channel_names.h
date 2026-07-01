#ifndef RUNNER_BRIDGE_NATIVE_CHANNEL_NAMES_H_
#define RUNNER_BRIDGE_NATIVE_CHANNEL_NAMES_H_

// Method/event channel names shared between Flutter and the native Windows
// engine.
//
// IMPORTANT: Keep this in sync with the Dart `NativeChannel`
// (lib/core/bridges/native_method_channel.dart) and the macOS Swift
// counterpart (macos/Runner/Core/NativeChannel.swift). All three sides must
// agree on these strings or the platform plumbing silently no-ops.
namespace clingfy::bridge::channel {

// Main method channel for screen recorder commands.
inline constexpr const char* kScreenRecorder = "com.clingfy/screen_recorder";

// Event channel for device-change notifications (audio/video sources,
// microphone level updates).
inline constexpr const char* kScreenRecorderEvents =
    "com.clingfy/screen_recorder/events";

// Event channel for the preview player (position, duration, state).
inline constexpr const char* kPlayerEvents = "com.clingfy/player/events";

// Event channel for recording / preview workflow lifecycle events
// (e.g. external "open project" requests, finalized recordings).
inline constexpr const char* kWorkflowEvents = "com.clingfy/workflow/events";

// Event channel for app-update notifications. On macOS this is fed by
// Sparkle; on Windows it will be fed by WinSparkle in Phase 10.
inline constexpr const char* kUpdaterEvents = "com.clingfy/updater/events";

}  // namespace clingfy::bridge::channel

// Native -> Flutter method names invoked BY the runner ON the screen_recorder
// method channel (the reverse direction of the router handlers). Keep in sync
// with Dart `NativeToFlutterMethod` (lib/core/bridges/native_method_channel.dart)
// and the macOS Swift counterpart.
namespace clingfy::bridge::method {

// Export progress: invoked with a bare double fraction (0.0..1.0). Dart's
// NativeBridge handles it via `call.arguments as double?` (Slice 5A).
inline constexpr const char* kUpdateExportProgress = "updateExportProgress";

}  // namespace clingfy::bridge::method

#endif  // RUNNER_BRIDGE_NATIVE_CHANNEL_NAMES_H_
