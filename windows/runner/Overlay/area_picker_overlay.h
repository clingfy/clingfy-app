#ifndef RUNNER_OVERLAY_AREA_PICKER_OVERLAY_H_
#define RUNNER_OVERLAY_AREA_PICKER_OVERLAY_H_

#include <cstdint>
#include <optional>

// Phase 7.3 — native Win32 area-picker overlay.
//
// Drops a dimmed, topmost, layered window over every monitor (one window per
// monitor — simpler monitor-local coordinates and DPI than a single
// virtual-desktop window, and no negative-origin arithmetic) and lets the user
// drag-select a rectangle on any monitor. Returns the selection as a
// monitor-local crop rect plus the display id, ready for
// `WindowsSelectionState::AreaRegion` and the Phase 7.2 crop pipeline.
//
// Modal: `PickArea()` runs its own message loop and blocks the calling
// (platform) thread until the user confirms (mouse-up) or cancels (Esc /
// right-click), mirroring how the native file dialog blocks. The selection math
// is all in `area_picker_geometry.h` (unit-tested); this header is the
// human-smoke surface.
namespace clingfy::overlay {

struct PickedArea {
  // Hashed display id (matches the display enumerator / DisplayInfo), for the
  // returned map + AreaRegion. The engine resolves it back to an HMONITOR.
  std::int64_t display_id = 0;
  // Monitor-local physical pixels (origin = the monitor's top-left). width/
  // height are even.
  std::int32_t x = 0;
  std::int32_t y = 0;
  std::int32_t width = 0;
  std::int32_t height = 0;
};

// Show the modal picker. Returns the picked area, or std::nullopt when the user
// cancelled or no monitor/selection was available. Must be called on the
// platform (UI) thread.
std::optional<PickedArea> PickArea();

}  // namespace clingfy::overlay

#endif  // RUNNER_OVERLAY_AREA_PICKER_OVERLAY_H_
