#include "Capture/Camera/camera_overlay_geometry_store.h"

#include <algorithm>
#include <cmath>

namespace clingfy::capture {

namespace {

// Slider bounds from lib/app/home/recording/widgets/recording_overlay_section
// (min 120, max 400) — also the macOS max(120, size) clamp floor.
constexpr double kMinSize = 120.0;
constexpr double kMaxSize = 400.0;
constexpr double kAspectW = 16.0;
constexpr double kAspectH = 9.0;

}  // namespace

FloatingRect ComputeFloatingRect(int work_left, int work_top, int work_right,
                                 int work_bottom, double dpi_scale,
                                 const CameraOverlayGeometry& g) {
  const int work_w = std::max(1, work_right - work_left);
  const int work_h = std::max(1, work_bottom - work_top);
  const double scale = dpi_scale > 0.0 ? dpi_scale : 1.0;

  // Height carries `size` (logical px -> physical px via the monitor scale);
  // width follows the 16:9 camera aspect.
  double h = std::clamp(g.size, kMinSize, kMaxSize) * scale;
  double w = h * (kAspectW / kAspectH);
  // Never exceed the work area (a large `size` on a small screen).
  if (w > work_w) {
    w = work_w;
    h = w * (kAspectH / kAspectW);
  }
  if (h > work_h) {
    h = work_h;
    w = h * (kAspectW / kAspectH);
  }
  const int iw = std::max(1, static_cast<int>(std::lround(w)));
  const int ih = std::max(1, static_cast<int>(std::lround(h)));

  // Margin from the work-area edge: 3% of the work width (matches the initial
  // placement convention in recording_engine.cpp), floored at 8 physical px.
  const int margin = std::max(8, work_w * 3 / 100);

  int x = 0;
  int y = 0;
  if (g.use_custom) {
    const double cx =
        work_left + std::clamp(g.normalized_x, 0.0, 1.0) * work_w;
    const double cy =
        work_top + std::clamp(g.normalized_y, 0.0, 1.0) * work_h;
    x = static_cast<int>(std::lround(cx - iw / 2.0));
    y = static_cast<int>(std::lround(cy - ih / 2.0));
  } else {
    // OverlayPosition: topLeft(0) topRight(1) bottomLeft(2) bottomRight(3).
    const bool right = g.position == 1 || g.position == 3;
    const bool bottom = g.position == 2 || g.position == 3;
    x = right ? (work_right - iw - margin) : (work_left + margin);
    y = bottom ? (work_bottom - ih - margin) : (work_top + margin);
  }

  // Keep the whole window inside the work area.
  x = std::clamp(x, work_left, std::max(work_left, work_right - iw));
  y = std::clamp(y, work_top, std::max(work_top, work_bottom - ih));

  return FloatingRect{x, y, iw, ih};
}

CameraOverlayGeometryStore& CameraOverlayGeometryStore::Instance() {
  static CameraOverlayGeometryStore instance;
  return instance;
}

void CameraOverlayGeometryStore::SetSize(double size) {
  std::lock_guard<std::mutex> lock(mutex_);
  geometry_.size = size;
  ++revision_;
}

void CameraOverlayGeometryStore::SetPosition(int position) {
  std::lock_guard<std::mutex> lock(mutex_);
  geometry_.position = position;
  geometry_.use_custom = false;
  ++revision_;
}

void CameraOverlayGeometryStore::SetCustomPosition(double normalized_x,
                                                   double normalized_y) {
  std::lock_guard<std::mutex> lock(mutex_);
  geometry_.normalized_x = normalized_x;
  geometry_.normalized_y = normalized_y;
  geometry_.use_custom = true;
  ++revision_;
}

CameraOverlayGeometry CameraOverlayGeometryStore::Snapshot() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return geometry_;
}

std::uint64_t CameraOverlayGeometryStore::revision() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return revision_;
}

}  // namespace clingfy::capture
