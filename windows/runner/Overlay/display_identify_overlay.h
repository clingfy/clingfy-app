#ifndef RUNNER_OVERLAY_DISPLAY_IDENTIFY_OVERLAY_H_
#define RUNNER_OVERLAY_DISPLAY_IDENTIFY_OVERLAY_H_

#include <windows.h>

#include <string>
#include <vector>

namespace clingfy::overlay {

// One card to paint: which monitor, where, and what to say on it.
struct IdentifyTarget {
  HMONITOR monitor = nullptr;
  RECT rect{};
  int ordinal = 0;
  std::wstring label;
};

// Flashes a large ordinal (and the monitor's label) on each target, mirroring
// System Settings > Displays > Identify on macOS.
//
// Windows are created on the platform thread and dismissed by WM_TIMER through
// the engine's existing pump — deliberately no nested message loop, which
// would starve the Flutter platform thread, and no extra thread, since the
// card is static rather than an animated surface.
//
// Calling this while a flash is up replaces it.
void ShowDisplayIdentify(const std::vector<IdentifyTarget>& targets,
                         int duration_ms);

// Tears every card down immediately. Idempotent.
void HideDisplayIdentify();

}  // namespace clingfy::overlay

#endif  // RUNNER_OVERLAY_DISPLAY_IDENTIFY_OVERLAY_H_
