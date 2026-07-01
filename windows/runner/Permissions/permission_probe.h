#ifndef RUNNER_PERMISSIONS_PERMISSION_PROBE_H_
#define RUNNER_PERMISSIONS_PERMISSION_PROBE_H_

#include <string>

#include "Permissions/camera_readiness.h"

// Windows-side permission probe + settings deep-link helpers.
//
// Windows does NOT have a per-app screen-recording or accessibility
// permission (unlike macOS TCC), and there is no system-level "request
// permission" prompt that a non-packaged Win32 app can trigger directly.
// What Windows does gate is:
//
//   * Microphone — `Settings > Privacy > Microphone > Allow desktop apps`
//   * Camera     — `Settings > Privacy > Camera > Allow desktop apps`
//
// Both are reflected through the WinRT `AppCapabilityAccess` API, which
// returns `Allowed` when the global + per-app toggles permit the
// non-packaged app and a denial reason otherwise.
//
// Because the system prompt is owned by `Settings`, our `request*`
// methods cannot pop the TCC-style dialog macOS shows. Instead the
// recording controller asks for the current value, and the engine deep-
// links into the right Settings page (via `ms-settings:`) so the user
// can flip the toggle and try again. The helpers below make that
// behavior explicit and unit-testable.
namespace clingfy::permissions {

struct PermissionSnapshot {
  // Screen recording on Windows requires no system grant — WGC operates
  // without a privacy toggle. Always true so the Dart preflight does
  // not block.
  bool screen_recording = true;
  bool microphone = false;
  bool camera = false;
  // Same story as screen_recording: Windows has no accessibility
  // permission concept that gates input capture / cursor coordinates.
  bool accessibility = true;
};

// Live probe — calls into `Windows.Security.Authorization.AppCapabilityAccess`
// for mic + camera. Returns a sensible-default snapshot when the WinRT
// API is unavailable (very old Windows hosts), so the bridge never
// surfaces a parse error from the probe itself.
PermissionSnapshot ProbePermissionStatus();

// Phase 9.1: the detailed camera privacy status, mapped from the WinRT
// `AppCapabilityAccessStatus`. `ProbePermissionStatus().camera` is exactly
// `ProbeCameraPermission() == CameraPermission::kGranted` — this richer form
// lets the camera-readiness check (and Phase 9.2's recording preflight)
// distinguish a system/global denial from a per-app denial from a
// not-yet-determined state. See `camera_readiness.h` for why the global vs.
// desktop-apps toggles cannot be told apart.
CameraPermission ProbeCameraPermission();

// Phase 10.2: the same detailed probe for the microphone capability. The
// enum is named for its Phase 9.1 camera origin, but the buckets are
// capability-agnostic AppCapabilityAccess states — reusing it keeps the
// mic and camera detail mappings (and their Dart wire names) identical.
CameraPermission ProbeMicrophonePermission();

// Pane id → `ms-settings:` URI. The Dart side calls
// `openSystemSettings(pane)` with one of:
//   * `"microphone"` → `ms-settings:privacy-microphone`
//   * `"camera"`     → `ms-settings:privacy-webcam`
//   * `"sound"`      → `ms-settings:sound` (input/output device settings —
//                      Phase 10.2, for system-audio guidance)
//   * `"screenRecording"` → `ms-settings:privacy` (no dedicated page; the
//                          general privacy hub is the closest analogue)
//   * `"accessibility"` → `ms-settings:easeofaccess` (closest analogue —
//                          Windows has no AX trust gate per app)
// Returns an empty string for unknown panes so the caller can short-
// circuit without launching anything.
std::wstring ResolveSettingsUri(const std::string& pane);

// Fire-and-forget: launches `uri` via `ShellExecuteW`. Returns true if
// the shell accepted the launch (success is asynchronous; the URI may
// still fail to open later, which we cannot observe from here).
bool LaunchSettingsUri(const std::wstring& uri);

}  // namespace clingfy::permissions

#endif  // RUNNER_PERMISSIONS_PERMISSION_PROBE_H_
