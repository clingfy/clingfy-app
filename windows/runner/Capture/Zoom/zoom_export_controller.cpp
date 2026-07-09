#include "Capture/Zoom/zoom_export_controller.h"

#include <algorithm>
#include <cmath>
#include <fstream>
#include <sstream>
#include <utility>

#include "Capture/Zoom/zoom_follow_smoother.h"
#include "preview/zoom_easing_constants.h"

namespace clingfy::capture {

namespace {

double Clamp01(double v) {
  if (v < 0.0) return 0.0;
  if (v > 1.0) return 1.0;
  return v;
}

}  // namespace

ZoomFocus ResolveZoomFocus(const std::vector<CursorSidecarSample>& samples,
                           std::int64_t start_ms, std::int64_t end_ms,
                           std::int32_t width, std::int32_t height) {
  const bool has_bounds = width > 0 && height > 0;
  const double w = static_cast<double>(width);
  const double h = static_cast<double>(height);

  // Visible, in-bounds samples within [start,end].
  const CursorSidecarSample* first = nullptr;
  double min_x = 0, max_x = 0, min_y = 0, max_y = 0;
  bool any = false;
  for (const auto& s : samples) {
    if (s.t_ms < start_ms || s.t_ms > end_ms || !s.visible) {
      continue;
    }
    if (has_bounds && (s.x < 0 || s.x > width || s.y < 0 || s.y > height)) {
      continue;
    }
    if (!any) {
      first = &s;
      min_x = max_x = s.x;
      min_y = max_y = s.y;
      any = true;
    } else {
      min_x = std::min<double>(min_x, s.x);
      max_x = std::max<double>(max_x, s.x);
      min_y = std::min<double>(min_y, s.y);
      max_y = std::max<double>(max_y, s.y);
    }
  }

  ZoomFocus focus;
  auto fixed_at = [&](const CursorSidecarSample* s) {
    focus.mode = ZoomFocusMode::kFixedTarget;
    if (s != nullptr && has_bounds) {
      focus.fixed_x = Clamp01(static_cast<double>(s->x) / w);
      focus.fixed_y = Clamp01(static_cast<double>(s->y) / h);
    } else {
      focus.fixed_x = 0.5;
      focus.fixed_y = 0.5;
    }
  };

  if (!any) {
    fixed_at(nullptr);
    return focus;
  }
  const double dx = max_x - min_x;
  const double dy = max_y - min_y;
  const double motion = std::sqrt(dx * dx + dy * dy);
  if (motion <= clingfy::preview::kZoomCursorMotionThresholdPx) {
    fixed_at(first);  // static segment → anchor on the triggering click point.
    return focus;
  }
  focus.mode = ZoomFocusMode::kFollowCursor;
  return focus;
}

std::unique_ptr<ZoomExportController> ZoomExportController::CreateFromData(
    CursorSidecarData data, std::int64_t duration_ms, double zoom_factor) {
  double factor = std::isfinite(zoom_factor) ? zoom_factor : 1.0;
  factor = std::min(std::max(factor, clingfy::preview::kZoomFactorMin),
                    clingfy::preview::kZoomFactorMax);
  if (factor <= 1.0 + clingfy::preview::kZoomFactorWriteEpsilon) {
    return nullptr;  // no magnification requested → no zoom.
  }
  const auto raw_segments =
      BuildZoomSegments(data.samples, data.clicks, duration_ms);
  if (raw_segments.empty()) {
    return nullptr;
  }
  std::unique_ptr<ZoomExportController> controller(new ZoomExportController());
  controller->zoom_factor_ = factor;
  for (const auto& seg : raw_segments) {
    ResolvedSegment resolved;
    resolved.start_ms = seg.start_ms;
    resolved.end_ms = seg.end_ms;
    resolved.focus = ResolveZoomFocus(data.samples, seg.start_ms, seg.end_ms,
                                      data.width, data.height);
    controller->segments_.push_back(resolved);
  }
  controller->data_ = std::move(data);
  return controller;
}

std::unique_ptr<ZoomExportController> ZoomExportController::Create(
    const std::wstring& sidecar_path, std::int64_t duration_ms,
    double zoom_factor) {
  if (sidecar_path.empty()) {
    return nullptr;
  }
  std::ifstream in(sidecar_path, std::ios::binary);
  if (!in) {
    return nullptr;
  }
  std::ostringstream ss;
  ss << in.rdbuf();
  auto parsed = ParseCursorSidecar(ss.str());
  if (!parsed.has_value()) {
    return nullptr;
  }
  return CreateFromData(std::move(*parsed), duration_ms, zoom_factor);
}

ZoomExportController::Frame ZoomExportController::Advance(std::int64_t frame_ms,
                                                         double dt_seconds) {
  // Find the active segment (segments are sorted, few in number).
  const ResolvedSegment* active = nullptr;
  for (const auto& seg : segments_) {
    // Half-open [start, end) to match macOS CompositionBuilder's membership test
    // (and so adjacent segments can never both claim a boundary frame).
    if (frame_ms >= seg.start_ms && frame_ms < seg.end_ms) {
      active = &seg;
      break;
    }
  }

  double target_zoom = 1.0;
  double target_cx = cur_cx_;
  double target_cy = cur_cy_;
  if (active != nullptr) {
    target_zoom = zoom_factor_;
    if (active->focus.mode == ZoomFocusMode::kFixedTarget) {
      target_cx = active->focus.fixed_x;
      target_cy = active->focus.fixed_y;
    } else {
      // followCursor: ease toward the live cursor; if it's hidden at this frame,
      // hold the current center rather than snapping away.
      const CursorAtResult at = SampleCursorAt(data_.samples, frame_ms);
      if (at.has && at.visible && data_.width > 0 && data_.height > 0) {
        target_cx = Clamp01(at.x / static_cast<double>(data_.width));
        target_cy = Clamp01(at.y / static_cast<double>(data_.height));
      }
    }
  }

  const double alpha = ZoomFollowAlpha(
      clingfy::preview::kZoomFollowStrengthDefault, dt_seconds,
      clingfy::preview::kZoomFollowReferenceFPS);
  cur_zoom_ = ZoomFollowLerp(cur_zoom_, target_zoom, alpha);
  cur_cx_ = ZoomFollowLerp(cur_cx_, target_cx, alpha);
  cur_cy_ = ZoomFollowLerp(cur_cy_, target_cy, alpha);

  // Clamp the center so the zoom window (size 1/zoom) stays inside the content.
  const double effective_zoom = std::max(cur_zoom_, 1.0);
  const double half = 0.5 / effective_zoom;
  cur_cx_ = std::min(std::max(cur_cx_, half), 1.0 - half);
  cur_cy_ = std::min(std::max(cur_cy_, half), 1.0 - half);

  Frame frame;
  frame.zoom = cur_zoom_;
  frame.center_x = cur_cx_;
  frame.center_y = cur_cy_;
  frame.active = cur_zoom_ > 1.0 + clingfy::preview::kZoomFactorWriteEpsilon;
  return frame;
}

void ZoomExportController::ResetSmoothing() {
  // Same rest state the smoother is constructed with, so the next Advance
  // eases in from neutral for the new range instead of from the stale
  // (later-frame) zoom left behind by a backward source jump.
  cur_zoom_ = 1.0;
  cur_cx_ = 0.5;
  cur_cy_ = 0.5;
}

}  // namespace clingfy::capture
