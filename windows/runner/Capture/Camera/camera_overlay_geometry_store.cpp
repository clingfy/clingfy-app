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

// The editor's size-factor band. Same values ComputeCameraBubbleRect re-clamps
// to and macOS applies when it builds the seed, kept here so the seeded value
// the size slider opens on is already in range.
constexpr double kMinSizeFactor = 0.08;
constexpr double kMaxSizeFactor = 0.45;

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

FloatingRect ComputeSquareFloatingRect(int work_left, int work_top,
                                       int work_right, int work_bottom,
                                       double dpi_scale,
                                       const CameraOverlayGeometry& g) {
  const int work_w = std::max(1, work_right - work_left);
  const int work_h = std::max(1, work_bottom - work_top);
  const double scale = dpi_scale > 0.0 ? dpi_scale : 1.0;

  double side = std::clamp(g.size, kMinSize, kMaxSize) * scale;
  side = std::min(side, static_cast<double>(std::min(work_w, work_h)));
  const int s = std::max(1, static_cast<int>(std::lround(side)));

  const int margin = std::max(8, work_w * 3 / 100);

  int x = 0;
  int y = 0;
  if (g.use_custom) {
    const double cx =
        work_left + std::clamp(g.normalized_x, 0.0, 1.0) * work_w;
    const double cy =
        work_top + std::clamp(g.normalized_y, 0.0, 1.0) * work_h;
    x = static_cast<int>(std::lround(cx - s / 2.0));
    y = static_cast<int>(std::lround(cy - s / 2.0));
  } else {
    const bool right = g.position == 1 || g.position == 3;
    const bool bottom = g.position == 2 || g.position == 3;
    x = right ? (work_right - s - margin) : (work_left + margin);
    y = bottom ? (work_bottom - s - margin) : (work_top + margin);
  }

  x = std::clamp(x, work_left, std::max(work_left, work_right - s));
  y = std::clamp(y, work_top, std::max(work_top, work_bottom - s));

  return FloatingRect{x, y, s, s};
}

PaddedSquareRect ComputePaddedSquareFloatingRect(
    int work_left, int work_top, int work_right, int work_bottom,
    double dpi_scale, const CameraOverlayGeometry& g,
    double effect_padding_px) {
  PaddedSquareRect out;
  const FloatingRect content = ComputeSquareFloatingRect(
      work_left, work_top, work_right, work_bottom, dpi_scale, g);
  out.padding_px = static_cast<int>(
      std::ceil(std::max(0.0, effect_padding_px)));
  out.content_side = content.width;
  out.window = FloatingRect{content.x - out.padding_px,
                            content.y - out.padding_px,
                            content.width + 2 * out.padding_px,
                            content.height + 2 * out.padding_px};
  return out;
}

bool CameraOverlayPointInContent(int client_x, int client_y, int padding_px,
                                 int content_side) {
  return client_x >= padding_px && client_x < padding_px + content_side &&
         client_y >= padding_px && client_y < padding_px + content_side;
}

NormalizedCenter NormalizedCenterForRect(int work_left, int work_top,
                                         int work_right, int work_bottom,
                                         const FloatingRect& rect) {
  const double work_w = std::max(1, work_right - work_left);
  const double work_h = std::max(1, work_bottom - work_top);
  const double cx = rect.x + rect.width / 2.0;
  const double cy = rect.y + rect.height / 2.0;
  return NormalizedCenter{
      std::clamp((cx - work_left) / work_w, 0.0, 1.0),
      std::clamp((cy - work_top) / work_h, 0.0, 1.0),
  };
}

std::string CameraLayoutPresetForOverlayPosition(int position) {
  switch (position) {
    case 0:
      return "overlayTopLeft";
    case 1:
      return "overlayTopRight";
    case 2:
      return "overlayBottomLeft";
    default:
      return "overlayBottomRight";
  }
}

CameraSeedGeometry ResolveCameraSeedGeometry(
    const CameraOverlayGeometry& g, int work_left, int work_top,
    int work_right, int work_bottom, int content_left, int content_top,
    int content_right, int content_bottom, double dpi_scale) {
  CameraSeedGeometry seed;
  seed.layout_preset = CameraLayoutPresetForOverlayPosition(g.position);

  const double content_w = static_cast<double>(content_right - content_left);
  const double content_h = static_cast<double>(content_bottom - content_top);
  if (content_w <= 0.0 || content_h <= 0.0) {
    // No usable content rect (a target-loss finalize before the first frame,
    // or a monitor that vanished). Leave the defaults: a corner preset and the
    // baseline size factor still open the editor somewhere sane.
    return seed;
  }

  const double scale = dpi_scale > 0.0 ? dpi_scale : 1.0;
  const double side_px = std::clamp(g.size, kMinSize, kMaxSize) * scale;
  seed.size_factor = std::clamp(side_px / std::max(1.0, std::min(content_w, content_h)),
                                kMinSizeFactor, kMaxSizeFactor);

  if (!g.use_custom) {
    return seed;  // preset placement; the center stays absent (macOS: nil).
  }

  const double work_w = static_cast<double>(work_right - work_left);
  const double work_h = static_cast<double>(work_bottom - work_top);
  if (work_w <= 0.0 || work_h <= 0.0) {
    return seed;
  }

  // Work-area-normalized -> absolute screen px -> content-normalized.
  const double absolute_x =
      work_left + std::clamp(g.normalized_x, 0.0, 1.0) * work_w;
  const double absolute_y =
      work_top + std::clamp(g.normalized_y, 0.0, 1.0) * work_h;
  const double content_x =
      std::clamp((absolute_x - content_left) / content_w, 0.0, 1.0);
  const double content_y =
      std::clamp((absolute_y - content_top) / content_h, 0.0, 1.0);

  seed.normalized_center_x = content_x;
  // y-DOWN (store / Win32) -> y-UP (the cameraNormalizedCenter wire contract).
  seed.normalized_center_y = 1.0 - content_y;
  return seed;
}

std::uint64_t AdoptDragRevision(std::uint64_t last_seen,
                                std::uint64_t returned) {
  return returned == last_seen + 1 ? returned : last_seen;
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

std::uint64_t CameraOverlayGeometryStore::SetCustomPosition(
    double normalized_x, double normalized_y) {
  std::lock_guard<std::mutex> lock(mutex_);
  geometry_.normalized_x = normalized_x;
  geometry_.normalized_y = normalized_y;
  geometry_.use_custom = true;
  return ++revision_;
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
