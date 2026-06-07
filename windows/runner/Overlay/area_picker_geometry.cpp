#include "Overlay/area_picker_geometry.h"

#include <algorithm>

namespace clingfy::overlay {

LocalPoint ScreenToMonitorLocal(std::int32_t screen_x, std::int32_t screen_y,
                                std::int32_t monitor_left,
                                std::int32_t monitor_top) {
  return LocalPoint{screen_x - monitor_left, screen_y - monitor_top};
}

std::optional<PickedRect> ResolvePickedRect(
    std::int32_t x0, std::int32_t y0, std::int32_t x1, std::int32_t y1,
    std::uint32_t monitor_width, std::uint32_t monitor_height,
    std::uint32_t min_size) {
  if (monitor_width == 0 || monitor_height == 0) {
    return std::nullopt;
  }
  const std::int64_t mw = static_cast<std::int64_t>(monitor_width);
  const std::int64_t mh = static_cast<std::int64_t>(monitor_height);

  // Normalize: order the two corners regardless of drag direction.
  std::int64_t left = std::min<std::int64_t>(x0, x1);
  std::int64_t top = std::min<std::int64_t>(y0, y1);
  std::int64_t right = std::max<std::int64_t>(x0, x1);
  std::int64_t bottom = std::max<std::int64_t>(y0, y1);

  // Clamp the rect into the monitor.
  left = std::clamp<std::int64_t>(left, 0, mw);
  top = std::clamp<std::int64_t>(top, 0, mh);
  right = std::clamp<std::int64_t>(right, 0, mw);
  bottom = std::clamp<std::int64_t>(bottom, 0, mh);

  const std::int64_t w = right - left;
  const std::int64_t h = bottom - top;

  // Clamp DOWN to even (H.264), matching EvenCaptureDimension.
  const std::uint32_t even_w = static_cast<std::uint32_t>(w) & ~1u;
  const std::uint32_t even_h = static_cast<std::uint32_t>(h) & ~1u;
  if (even_w < min_size || even_h < min_size) {
    return std::nullopt;
  }

  return PickedRect{static_cast<std::uint32_t>(left),
                    static_cast<std::uint32_t>(top), even_w, even_h};
}

}  // namespace clingfy::overlay
