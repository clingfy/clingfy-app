#ifndef RUNNER_CAPTURE_CAMERA_CAMERA_RENDER_PLAN_H_
#define RUNNER_CAPTURE_CAMERA_CAMERA_RENDER_PLAN_H_

#include <cstdint>
#include <string>

#include "Capture/Camera/camera_export_layout.h"

// The ONE derivation of the camera bubble, shared by the inline preview
// (preview/preview_camera_renderer.cpp) and the export
// (Capture/Export/export_pipeline.cpp). Both legs used to derive the same five
// things independently — the bubble rect, the eleven style fields, the parsed
// animation invariants, the slide edge, and the cached zoom trio — from the
// same authored composition. This is that derivation, once, pure.
//
// D2D-free on purpose so the plan is unit-testable without a device. Do NOT
// include camera_bubble_painter.h here: it pulls d2d1_1.h / mfidl.h /
// mfreadwrite.h. `CameraBubbleStyle` lives in camera_export_layout.h for
// exactly that reason, and because camera_overlay_style_store.h holds one by
// value while deliberately staying OUT of this builder — if the style lived
// here, the live-overlay leg would have to include the builder it must not use.
//
// NOT macOS parity in two respects, and the next reader must not assume it is:
// macOS `clampPresentationFrame` also SHRINKS a bubble to fit and insets it by
// a border/shadow outset, while camera_export_layout.cpp only translates. This
// seam does not close that gap.
namespace clingfy::capture {

// The authored camera composition, as both drawing legs receive it off the
// wire. Nullable colours are flattened (bool + value) rather than carried as
// std::optional: the optional form was only ever derived from this one at the
// bridge and flattened straight back at the export, so the flat form end to end
// deletes both hops.
//
// The defaults below are the WIRE table, and they are NOT the same table as
// `CameraBubbleStyle`'s (chroma_strength is 0.4 here and 0.0 there). Both
// drawing legs assign every style field explicitly through BuildCameraRenderPlan
// below, so the disagreement stays latent — but that is a property the builder
// maintains, not an accident, and `PlanAssignsEveryStyleField` pins it.
//
// These must also NOT default to the CameraEditorSeed values: an absent
// animation key means "no animation", not "whatever the editor seeds a new
// project with", and the export request parser takes the same fallbacks.
struct CameraRenderSpec {
  // `visible` is the PREVIEW's per-frame toggle and the export's asset gate.
  // The plan builder NEVER reads it — it is carried here so the preview's
  // composition type can be a pure alias of this struct with zero call-site
  // churn. It MUST keep its `= false` default: flip it and the export's asset
  // gate silently opens.
  bool visible = false;
  bool has_center = false;
  double center_x = 0.0;
  double center_y = 0.0;
  std::string layout_preset;
  double size_factor = 0.18;
  std::string shape;
  double corner_radius = 0.0;
  std::string content_mode;
  bool mirror = false;
  double opacity = 1.0;
  double border_width = 0.0;
  bool has_border_color = false;
  std::uint32_t border_argb = 0;
  int shadow_preset = 0;
  // Phase 9.7 chroma key, mirrored into the inline preview for WYSIWYG with the
  // export.
  bool chroma_enabled = false;
  double chroma_strength = 0.4;
  bool has_chroma_color = false;
  std::uint32_t chroma_argb = 0;
  // Phase 9.7 intro/outro animations, also previewed (macOS parity: its inline
  // preview runs CameraAnimationTimelineBuilder.resolvePresentation too). The
  // player DOES have a timeline — the engine already carries the edited
  // position + edited duration to the draw call, which is the clock the export
  // animates on. Empty preset / 0 ms parse to "no animation", matching the
  // export request parser.
  std::string intro_preset;
  std::string outro_preset;
  int intro_duration_ms = 0;
  int outro_duration_ms = 0;
  // Scale-with-screen-zoom. Empty behaviour / 0 multiplier = a fixed bubble,
  // matching the export parser's fallbacks.
  std::string zoom_behavior;
  double zoom_scale_multiplier = 0.0;
  // Zoom emphasis (the pulse). Empty / unknown preset = "none", so an absent
  // key leaves the bubble resting — the same soft-fail the animation presets
  // take. Strength is the raw wire value; ResolveCameraPulseScale clamps it.
  std::string zoom_emphasis_preset;
  double zoom_emphasis_strength = 0.0;
};

// The LOOP-INVARIANT half of CameraAnimationParams — a DISTINCT type, never a
// CameraAnimationParams with its three per-frame fields left at their defaults.
// Those defaults (zoom_scale = 1.0, zoom_in_segment = false,
// zoom_local_seconds = 0.0) describe a silently-never-pulsing bubble, which is
// verbatim the failure CameraExportRenderer::Draw's contract forbids: "A
// default would let a new call site compile while silently never pulsing."
// Admitting the per-frame fields here as struct defaults would re-open it.
struct CameraAnimationInvariants {
  CameraIntroKind intro = CameraIntroKind::kNone;
  CameraOutroKind outro = CameraOutroKind::kNone;
  int intro_duration_ms = 0;
  int outro_duration_ms = 0;
  CameraZoomEmphasisKind emphasis = CameraZoomEmphasisKind::kNone;
  double emphasis_strength = 0.0;
};

// THE INVARIANT FOR THIS STRUCT: every field is fixed for one prepared epoch —
// one (spec, canvas, effect_scale) tuple. Nothing per-frame may be added here.
// The per-frame values are arguments to ResolveCameraRenderFrame below, and
// there are exactly six of them.
//
// `zoom_behavior` / `zoom_scale_multiplier` / `layout_preset` are carried raw
// because both legs cache them at Prepare and consume them PER FRAME through
// ResolveCameraZoomScale. Omitting them would leave the behaviour string empty,
// and an empty behaviour means a fixed bubble — scale-with-screen-zoom would
// die silently on the export. `canvas_w` / `canvas_h` are here because
// ResolveCameraAnimation needs them every frame for the post-scale clamp and
// the offscreen slide offset.
struct CameraRenderPlan {
  CameraBubbleRect bubble;    // the resting rect
  CameraBubbleStyle style;    // all 11 fields ALWAYS assigned
  std::string shape;          // -> CameraBubblePainter::Prepare
  double corner_radius = 0.0; // -> CameraBubblePainter::Prepare
  std::string content_mode;   // -> CameraBubblePainter::Prepare
  CameraAnimationInvariants anim;
  CameraSlideEdge slide_edge = CameraSlideEdge::kRight;
  double canvas_w = 0.0;
  double canvas_h = 0.0;
  std::string zoom_behavior;
  double zoom_scale_multiplier = 0.0;
  std::string layout_preset;
};

// The export paints ON the export canvas, so every `CameraBubbleStyle` length
// is already in its own pixels and the bubble's min-side floor needs no
// resolving. Naming it gives that argument one symbol, one grep and one
// assertion: until this existed, the export left `effect_scale` at the
// painter's in-class 1.0 and took `ComputeCameraBubbleRect`'s defaulted floor,
// so the value was correct but written down nowhere.
inline constexpr double kExportCameraEffectScale = 1.0;

// THE builder: resolve `spec` onto a `canvas_w` x `canvas_h` surface.
//
// `effect_scale` is a FIRST-CLASS input — short_side(surface)/short_side(export)
// for the inline preview (see `PreviewCameraEffectScale`), and
// kExportCameraEffectScale for the export. A non-positive value degrades to
// 1.0; that clamp is the only thing standing between a 0.0 input and a painter
// that erases the border and collapses the shadow.
CameraRenderPlan BuildCameraRenderPlan(const CameraRenderSpec& spec,
                                       double canvas_w, double canvas_h,
                                       double effect_scale);

// The per-frame half, once. Replaces the nine duplicated lines in each leg's
// Draw (the preview's own comment there already reads "Same nine lines as
// CameraExportRenderer::Draw").
//
// SIX inputs, none defaulted, for the reason on CameraExportRenderer::Draw: a
// default would let a new call site compile while silently never pulsing. Takes
// the plan by const& and composes a local CameraAnimationParams, so neither
// renderer keeps mutable per-frame state and two frames cannot leak into each
// other.
CameraAnimationOutput ResolveCameraRenderFrame(
    const CameraRenderPlan& plan, std::int64_t frame_ms,
    std::int64_t total_duration_ms, double screen_zoom, bool zoom_in_segment,
    std::int64_t zoom_segment_local_ms);

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CAMERA_CAMERA_RENDER_PLAN_H_
