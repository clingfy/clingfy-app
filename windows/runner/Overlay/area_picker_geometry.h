#ifndef RUNNER_OVERLAY_AREA_PICKER_GEOMETRY_H_
#define RUNNER_OVERLAY_AREA_PICKER_GEOMETRY_H_

#include <cstdint>
#include <optional>

// Phase 7.3 — pure selection geometry for the native area-picker overlay.
//
// The overlay window plumbing (layered/topmost windows, the modal message loop,
// mouse capture, painting) lives in `area_picker_overlay.{h,cpp}` and is
// human-smoke-tested. ALL the coordinate math the picker depends on lives here
// instead, so it can be unit-tested without a GPU, a display, or a UI:
//   * converting a screen point to monitor-local coordinates (the monitor's
//     origin can be negative on a left-of-primary secondary display), and
//   * turning a drag (two monitor-local points, any direction) into a clamped,
//     even-aligned crop rect with a minimum size.
//
// The produced rect is monitor-local physical pixels — exactly the shape
// `WindowsSelectionState::AreaRegion` and the Phase 7.2 crop pipeline consume.
// Even-alignment matches `EvenCaptureDimension` (clamp DOWN to even) so the
// engine's `ResolveCropBox` is a no-op on this rect rather than re-cropping.
namespace clingfy::overlay {

// Minimum selectable edge, in physical pixels. A drag smaller than this in
// either dimension is treated as no selection (the picker cancels).
inline constexpr std::uint32_t kMinAreaSize = 16;

struct LocalPoint {
  std::int32_t x = 0;
  std::int32_t y = 0;
};

struct PickedRect {
  std::uint32_t x = 0;
  std::uint32_t y = 0;
  std::uint32_t width = 0;
  std::uint32_t height = 0;
};

// Translate a screen point into coordinates local to a monitor whose top-left
// (virtual-desktop) origin is (monitor_left, monitor_top). monitor_left/top may
// be negative for displays positioned left of / above the primary.
LocalPoint ScreenToMonitorLocal(std::int32_t screen_x, std::int32_t screen_y,
                                std::int32_t monitor_left,
                                std::int32_t monitor_top);

// Resolve a drag between two monitor-local points into a crop rect:
//   1. normalize (handles a drag in any direction),
//   2. clamp the rect into [0, monitor_width] x [0, monitor_height],
//   3. clamp width/height DOWN to even (H.264),
//   4. reject (std::nullopt) when either even dimension is below `min_size`.
std::optional<PickedRect> ResolvePickedRect(
    std::int32_t x0, std::int32_t y0, std::int32_t x1, std::int32_t y1,
    std::uint32_t monitor_width, std::uint32_t monitor_height,
    std::uint32_t min_size);

}  // namespace clingfy::overlay

#endif  // RUNNER_OVERLAY_AREA_PICKER_GEOMETRY_H_
