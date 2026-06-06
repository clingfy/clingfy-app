#ifndef RUNNER_BRIDGE_DEVICES_WINDOW_ENUMERATOR_H_
#define RUNNER_BRIDGE_DEVICES_WINDOW_ENUMERATOR_H_

#include <windows.h>

#include <cstdint>
#include <optional>
#include <vector>

#include "Bridge/Devices/device_record.h"

// Phase 2: real `getAppWindows` implementation.
//
// Walks all top-level windows via `EnumWindows`, filters out invisible /
// system / cloaked / zero-sized windows, and resolves the owning process so
// the user sees a recognizable app name in the picker.
//
// Filtering rules (mirroring what other screen-share tooling does):
//   * Window must be visible (`IsWindowVisible`).
//   * Window must not be cloaked (UWP suspended / virtual desktops).
//   * Window must have a non-empty title OR be the main window of its
//     process (so untitled apps like "Settings" still show up).
//   * Window must have an extended frame larger than 1x1.
//
// The DWM-extended frame is used for bounds (matches what the user perceives
// as the window edge — `GetWindowRect` includes invisible drop-shadows).
namespace clingfy::bridge::devices {

std::vector<AppWindowRecord> EnumerateAppWindows();

// Phase 7.1 helper: resolve a `window_id` (the HWND-as-int64 that
// `EnumerateAppWindows` surfaces) back to a live `HWND` for WGC
// `CreateForWindow`. Returns `std::nullopt` when `id` is missing or the window
// no longer exists (`IsWindow` is false) — the engine maps that to a friendly
// "window no longer available" target error. The deeper capturability check is
// left to `CreateForWindow` at Start time; this only validates the handle.
std::optional<HWND> ResolveAppWindow(std::optional<std::int64_t> id);

}  // namespace clingfy::bridge::devices

#endif  // RUNNER_BRIDGE_DEVICES_WINDOW_ENUMERATOR_H_
