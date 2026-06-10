#include "Capture/Camera/camera_export_layout.h"

#include <algorithm>
#include <cmath>

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

namespace {

// Slide travel margin (px) past the named edge, matching macOS `slideMargin`.
constexpr double kSlideMarginPx = 1.0;

double Lerp(double from, double to, double progress) {
  return from + ((to - from) * progress);
}

double EaseOutCubic(double v) { return 1.0 - std::pow(1.0 - v, 3.0); }
double EaseInCubic(double v) { return std::pow(v, 3.0); }

// Normalized 0..1 progress through the intro window.
double IntroProgress(std::int64_t frame_ms, int duration_ms) {
  const double denom = std::max(static_cast<double>(duration_ms), 0.0001);
  return Clamp(static_cast<double>(frame_ms) / denom, 0.0, 1.0);
}

// Normalized 0..1 progress through the trailing outro window.
double OutroProgress(std::int64_t frame_ms, std::int64_t total_duration_ms,
                     int duration_ms) {
  const double denom = std::max(static_cast<double>(duration_ms), 0.0001);
  const double start =
      std::max(static_cast<double>(total_duration_ms) - denom, 0.0);
  return Clamp((static_cast<double>(frame_ms) - start) / denom, 0.0, 1.0);
}

// Offset (canvas px) that pushes `bubble` fully past `edge`, in D2D y-DOWN
// space. Returned as the destination offset relative to the resting position.
void OffscreenOffset(CameraSlideEdge edge, const CameraBubbleRect& bubble,
                     double canvas_w, double canvas_h, double* dx, double* dy) {
  *dx = 0.0;
  *dy = 0.0;
  switch (edge) {
    case CameraSlideEdge::kLeft:
      *dx = -(bubble.x + bubble.width + kSlideMarginPx);
      break;
    case CameraSlideEdge::kRight:
      *dx = canvas_w + kSlideMarginPx - bubble.x;
      break;
    case CameraSlideEdge::kTop:
      *dy = -(bubble.y + bubble.height + kSlideMarginPx);
      break;
    case CameraSlideEdge::kBottom:
      *dy = canvas_h + kSlideMarginPx - bubble.y;
      break;
  }
}

}  // namespace

CameraIntroKind ParseCameraIntroKind(const std::string& name) {
  if (name == "fade") return CameraIntroKind::kFade;
  if (name == "pop") return CameraIntroKind::kPop;
  if (name == "slide") return CameraIntroKind::kSlide;
  return CameraIntroKind::kNone;
}

CameraOutroKind ParseCameraOutroKind(const std::string& name) {
  if (name == "fade") return CameraOutroKind::kFade;
  if (name == "shrink") return CameraOutroKind::kShrink;
  if (name == "slide") return CameraOutroKind::kSlide;
  return CameraOutroKind::kNone;
}

CameraSlideEdge ResolveCameraSlideEdge(const std::string& layout_preset,
                                       bool has_center,
                                       const CameraBubbleRect& bubble,
                                       double canvas_w, double canvas_h) {
  if (!has_center) {
    if (layout_preset == "overlayTopLeft" ||
        layout_preset == "overlayBottomLeft" ||
        layout_preset == "sideBySideLeft") {
      return CameraSlideEdge::kLeft;
    }
    if (layout_preset == "stackedTop") {
      return CameraSlideEdge::kTop;
    }
    if (layout_preset == "stackedBottom") {
      return CameraSlideEdge::kBottom;
    }
    // overlayTopRight / overlayBottomRight / sideBySideRight / backgroundBehind
    // / hidden / unknown → the right edge (macOS default).
    return CameraSlideEdge::kRight;
  }

  // Manual placement: nearest visual edge to the bubble center (y-DOWN).
  const double cx = bubble.x + bubble.width / 2.0;
  const double cy = bubble.y + bubble.height / 2.0;
  const double left_dist = cx;
  const double right_dist = std::max(canvas_w - cx, 0.0);
  const double top_dist = cy;
  const double bottom_dist = std::max(canvas_h - cy, 0.0);
  const double min_horizontal = std::min(left_dist, right_dist);
  const double min_vertical = std::min(top_dist, bottom_dist);
  if (min_horizontal <= min_vertical) {
    return left_dist <= right_dist ? CameraSlideEdge::kLeft
                                   : CameraSlideEdge::kRight;
  }
  // Strict <: a vertical tie resolves to the bottom edge, matching macOS
  // (y-UP `bottomDistance <= topDistance → .bottom` in
  // CameraAnimationTimelineBuilder.resolvedSlideEdge).
  return top_dist < bottom_dist ? CameraSlideEdge::kTop
                                : CameraSlideEdge::kBottom;
}

CameraAnimationOutput ResolveCameraAnimation(const CameraAnimationParams& params,
                                             std::int64_t frame_ms,
                                             std::int64_t total_duration_ms,
                                             const CameraBubbleRect& bubble,
                                             double canvas_w, double canvas_h,
                                             CameraSlideEdge edge) {
  CameraAnimationOutput out;
  if (!CameraHasPresentationEffects(params) || total_duration_ms <= 0) {
    return out;  // identity
  }

  const std::int64_t t =
      std::max<std::int64_t>(0, std::min(frame_ms, total_duration_ms));

  // --- Opacity: fade/pop/slide ramp in; fade/shrink/slide ramp out. ---
  double opacity = 1.0;
  if (params.intro != CameraIntroKind::kNone) {
    opacity *= IntroProgress(t, params.intro_duration_ms);
  }
  if (params.outro != CameraOutroKind::kNone) {
    opacity *= 1.0 - OutroProgress(t, total_duration_ms, params.outro_duration_ms);
  }
  out.opacity = Clamp(opacity, 0.0, 1.0);

  // --- Scale: only `pop` (intro) and `shrink` (outro) scale. ---
  double scale = 1.0;
  if (params.intro == CameraIntroKind::kPop) {
    const double eased = EaseOutCubic(IntroProgress(t, params.intro_duration_ms));
    scale *= Lerp(0.90, 1.0, eased);
  }
  if (params.outro == CameraOutroKind::kShrink) {
    const double eased =
        EaseInCubic(OutroProgress(t, total_duration_ms, params.outro_duration_ms));
    scale *= Lerp(1.0, 0.90, eased);
  }
  out.scale = scale;

  // --- Translation: only `slide` moves; intro eases in from offscreen, outro
  // eases out to offscreen. The two never overlap in time. ---
  double off_dx = 0.0;
  double off_dy = 0.0;
  OffscreenOffset(edge, bubble, canvas_w, canvas_h, &off_dx, &off_dy);
  if (params.intro == CameraIntroKind::kSlide) {
    const double eased = EaseOutCubic(IntroProgress(t, params.intro_duration_ms));
    out.translate_x += Lerp(off_dx, 0.0, eased);
    out.translate_y += Lerp(off_dy, 0.0, eased);
  }
  if (params.outro == CameraOutroKind::kSlide) {
    const double eased =
        EaseInCubic(OutroProgress(t, total_duration_ms, params.outro_duration_ms));
    out.translate_x += Lerp(0.0, off_dx, eased);
    out.translate_y += Lerp(0.0, off_dy, eased);
  }
  return out;
}

}  // namespace clingfy::capture
