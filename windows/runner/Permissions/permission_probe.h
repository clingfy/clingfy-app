#ifndef RUNNER_PERMISSIONS_PERMISSION_PROBE_H_
#define RUNNER_PERMISSIONS_PERMISSION_PROBE_H_

#include <string>

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

// Pane id → `ms-settings:` URI. The Dart side calls
// `openSystemSettings(pane)` with one of:
//   * `"microphone"` → `ms-settings:privacy-microphone`
//   * `"camera"`     → `ms-settings:privacy-webcam`
//   * `"screenRecording"` → `ms-settings:privacy-broadFileSystemAccess`
//                          (no dedicated page; broad privacy is the
//                          closest Windows analogue)
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
