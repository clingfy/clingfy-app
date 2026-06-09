#include "Capture/Camera/camera_export_layout.h"

#include <algorithm>

namespace clingfy::capture {

namespace {

double Clamp(double v, double lo, double hi) {
  return v < lo ? lo : (v > hi ? hi : v);
}

// Default normalized center for a layout preset when the user hasn't dragged the
// bubble. Corner presets sit a little in from the edge; the post-clamp keeps the
// bubble on-canvas regardless of size. Full-canvas / side-by-side / stacked
// layouts are not bubble layouts (deferred past 9.4) — default them to the
// bottom-right corner so the camera still appears somewhere sensible.
void PresetCenter(const std::string& preset, double* cx, double* cy) {
  constexpr double kNear = 0.18;
  constexpr double kFar = 0.82;
  if (preset == "overlayTopLeft") {
    *cx = kNear;
    *cy = kNear;
  } else if (preset == "overlayTopRight") {
    *cx = kFar;
    *cy = kNear;
  } else if (preset == "overlayBottomLeft") {
    *cx = kNear;
    *cy = kFar;
  } else {
    // overlayBottomRight + everything deferred.
    *cx = kFar;
    *cy = kFar;
  }
}

}  // namespace

CameraBubbleRect ComputeCameraBubbleRect(double canvas_w, double canvas_h,
                                         bool has_center, double center_x,
                                         double center_y,
                                         const std::string& layout_preset,
                                         double size_factor) {
  CameraBubbleRect rect;
  if (canvas_w <= 0.0 || canvas_h <= 0.0) {
    return rect;  // degenerate canvas → empty bubble
  }

  const double factor = Clamp(size_factor, 0.08, 0.45);
  double side = std::min(canvas_w, canvas_h) * factor;
  side = std::max(side, kCameraBubbleMinSidePx);
  // A min-side floor can exceed a tiny canvas; never let the bubble be larger
  // than the canvas itself.
  side = std::min(side, std::min(canvas_w, canvas_h));

  double cx = 0.0;
  double cy = 0.0;
  if (has_center) {
    cx = Clamp(center_x, 0.0, 1.0);
    cy = Clamp(center_y, 0.0, 1.0);
  } else {
    PresetCenter(layout_preset, &cx, &cy);
  }

  rect.width = side;
  rect.height = side;
  rect.x = cx * canvas_w - side / 2.0;
  rect.y = cy * canvas_h - side / 2.0;
  // Clamp fully on-canvas.
  rect.x = Clamp(rect.x, 0.0, canvas_w - side);
  rect.y = Clamp(rect.y, 0.0, canvas_h - side);
  return rect;
}

CameraShadowStyle ResolveCameraShadowStyle(int preset) {
  CameraShadowStyle s;
  switch (preset) {
    case 1:
      s = {true, 0.18, 10.0, 0.0, 2.0};
      break;
    case 2:
      s = {true, 0.24, 16.0, 0.0, 4.0};
      break;
    case 3:
      s = {true, 0.32, 22.0, 0.0, 6.0};
      break;
    default:
      s = {false, 0.0, 0.0, 0.0, 0.0};
      break;
  }
  return s;
}

int SelectHeldCameraFrameIndex(std::int64_t camera_ms,
                               const std::vector<std::int64_t>& frame_ms_list) {
  if (camera_ms < 0) {
    return -1;
  }
  int held = -1;
  for (int i = 0; i < static_cast<int>(frame_ms_list.size()); ++i) {
    if (frame_ms_list[i] <= camera_ms) {
      held = i;  // ascending list → keep advancing to the latest eligible
    } else {
      break;
    }
  }
  return held;
}

}  // namespace clingfy::capture
