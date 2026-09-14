#include "Capture/Camera/camera_render_plan.h"

#include <algorithm>

namespace clingfy::capture {

CameraRenderPlan BuildCameraRenderPlan(const CameraRenderSpec& spec,
                                       double canvas_w, double canvas_h,
                                       double effect_scale) {
  const double scale = effect_scale > 0.0 ? effect_scale : 1.0;

  CameraRenderPlan plan;
  // The floor is the one non-proportional term in ComputeCameraBubbleRect, so
  // it is the one that has to be resolved onto this surface. Everything else in
  // there is a fraction of the canvas and is already correct. The export passes
  // scale 1.0, which makes `kCameraBubbleMinSidePx * 1.0` identical to the
  // 7-argument call it used to make.
  plan.bubble = ComputeCameraBubbleRect(canvas_w, canvas_h, spec.has_center,
                                        spec.center_x, spec.center_y,
                                        spec.layout_preset, spec.size_factor,
                                        kCameraBubbleMinSidePx * scale);

  // ALL ELEVEN, always. The painter's in-class defaults are never reached on
  // either plan leg after this; they survive only for the live-overlay store,
  // which stays off this builder by design.
  plan.style.mirror = spec.mirror;
  plan.style.opacity = spec.opacity;
  plan.style.border_width = spec.border_width;  // authored, UNSCALED
  plan.style.has_border_color = spec.has_border_color;
  plan.style.border_argb = spec.border_argb;
  plan.style.shadow_preset = spec.shadow_preset;
  // Border width and the shadow table are export-canvas lengths; the painter
  // resolves both through this one field.
  plan.style.effect_scale = scale;
  plan.style.chroma_enabled = spec.chroma_enabled;
  plan.style.chroma_strength = spec.chroma_strength;
  plan.style.has_chroma_color = spec.has_chroma_color;
  plan.style.chroma_argb = spec.chroma_argb;

  plan.shape = spec.shape;
  plan.corner_radius = spec.corner_radius;
  plan.content_mode = spec.content_mode;

  plan.anim.intro = ParseCameraIntroKind(spec.intro_preset);
  plan.anim.outro = ParseCameraOutroKind(spec.outro_preset);
  plan.anim.intro_duration_ms = spec.intro_duration_ms;
  plan.anim.outro_duration_ms = spec.outro_duration_ms;
  plan.anim.emphasis = ParseCameraZoomEmphasisKind(spec.zoom_emphasis_preset);
  plan.anim.emphasis_strength = spec.zoom_emphasis_strength;

  plan.canvas_w = canvas_w;
  plan.canvas_h = canvas_h;
  // Derived from the COMPUTED bubble (already D2D y-DOWN, because
  // ComputeCameraBubbleRect flips a manual y-UP center) — NEVER from
  // spec.center_y, which would double-flip and slide the bubble out of the
  // wrong edge. Both legs already resolved it this way.
  plan.slide_edge = ResolveCameraSlideEdge(spec.layout_preset, spec.has_center,
                                           plan.bubble, canvas_w, canvas_h);

  plan.zoom_behavior = spec.zoom_behavior;
  plan.zoom_scale_multiplier = spec.zoom_scale_multiplier;
  plan.layout_preset = spec.layout_preset;
  return plan;
}

CameraAnimationOutput ResolveCameraRenderFrame(
    const CameraRenderPlan& plan, std::int64_t frame_ms,
    std::int64_t total_duration_ms, double screen_zoom, bool zoom_in_segment,
    std::int64_t zoom_segment_local_ms) {
  // Compose the full params LOCALLY rather than mutating cached state, so two
  // frames with different zoom state cannot leak into each other.
  // ResolveCameraZoomScale and ResolveCameraAnimation are untouched.
  CameraAnimationParams params;
  params.intro = plan.anim.intro;
  params.outro = plan.anim.outro;
  params.intro_duration_ms = plan.anim.intro_duration_ms;
  params.outro_duration_ms = plan.anim.outro_duration_ms;
  params.emphasis = plan.anim.emphasis;
  params.emphasis_strength = plan.anim.emphasis_strength;
  params.zoom_scale =
      ResolveCameraZoomScale(plan.zoom_behavior, plan.zoom_scale_multiplier,
                             screen_zoom, plan.layout_preset);
  params.zoom_in_segment = zoom_in_segment;
  params.zoom_local_seconds =
      static_cast<double>(std::max<std::int64_t>(0, zoom_segment_local_ms)) /
      1000.0;
  return ResolveCameraAnimation(params, frame_ms, total_duration_ms,
                                plan.bubble, plan.canvas_w, plan.canvas_h,
                                plan.slide_edge);
}

}  // namespace clingfy::capture
