#ifndef RUNNER_PREVIEW_PREVIEW_CAMERA_RENDERER_H_
#define RUNNER_PREVIEW_PREVIEW_CAMERA_RENDERER_H_

#include <d2d1_1.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "Capture/Camera/camera_bubble_painter.h"
#include "Capture/Camera/camera_export_layout.h"

// Phase 9.6 — composites `camera/raw.mov` into the post-record inline preview as
// the SAME styled bubble the export draws (shared CameraBubblePainter → WYSIWYG).
//
// Unlike the export renderer (linear, monotonic), the preview is a PLAYER: the
// user pauses, scrubs, and seeks. So the camera frame source seeks — it tracks
// the held camera frame for the current playback position, re-seeking the
// IMFSourceReader on a backward jump or a large forward jump, and pulling
// forward otherwise. Time key: cameraHns = playbackUs*10 - startOffsetMs*10000.
//
// Threading: SetComposition is called from the platform thread (processVideo /
// previewSetCameraPlacement); PrepareAndAdvance + Draw run on the MediaPlayer
// frame-server thread that owns the D2D context. A mutex guards the pending
// composition params. The painter's Prepare does SetTarget round-trips, so
// PrepareAndAdvance MUST be called OUTSIDE the engine's BeginDraw and Draw INSIDE.
namespace clingfy::preview {

// Re-seek (vs pull forward) when the requested camera time jumps backward at
// all, or forward by more than this (a scrub, not normal playback).
inline constexpr std::int64_t kPreviewCameraSeekThresholdHns = 10'000'000;  // 1s

// Pure seek decision for the preview camera, exposed for unit tests.
//   camera_hns      — target camera-file time (>= 0).
//   held_pts_hns    — pts of the currently held frame, or -1 if none.
//   has_held_frame  — whether a frame is currently uploaded.
// Returns true when the reader should SetCurrentPosition rather than pull
// forward: a backward jump, a large forward jump, or a cold start far into the
// clip (held_pts_hns < 0 and camera_hns past the threshold).
bool PreviewCameraShouldSeek(std::int64_t camera_hns, std::int64_t held_pts_hns,
                             bool has_held_frame);

struct PreviewCameraComposition {
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
  // export request parser; see camera_composition_args.h for why these must not
  // default to the CameraEditorSeed values.
  std::string intro_preset;
  std::string outro_preset;
  int intro_duration_ms = 0;
  int outro_duration_ms = 0;
  // Scale-with-screen-zoom. Empty behaviour / 0 multiplier = a fixed bubble,
  // matching the export parser's fallbacks.
  std::string zoom_behavior;
  double zoom_scale_multiplier = 0.0;
};

// Ratio that converts an EXPORT-canvas length into a length on the preview
// surface: short_side(surface) / short_side(export).
//
// Soft-fails to 1.0 — NOT to 0.0 like `core::NormalizeToShortSide`. The
// difference is deliberate. A zero fraction means "no padding", which is a
// sane-looking canvas; a zero SCALE would erase the border and collapse the
// shadow, so an export size that is not yet resolved (no decoded frame, so
// `ResolveTargetSize` cannot run) would silently draw an unstyled bubble.
// Falling back to identity reproduces the pre-fix appearance for those first
// frames instead, and the rebuild predicate corrects it once the size lands.
double PreviewCameraEffectScale(double surface_short_side,
                                double export_short_side);

// Whether the painter must be rebuilt. Pure so the effect-scale term is
// testable: a scale that arrives LATE (the export size is unknown until the
// first decoded frame) must force a rebuild on its own, or the bubble keeps the
// identity-scaled border and shadow for the rest of the session even though the
// canvas never changed.
bool PreviewCameraNeedsRebuild(bool dirty, UINT canvas_w, UINT canvas_h,
                               double effect_scale, UINT prepared_canvas_w,
                               UINT prepared_canvas_h,
                               double prepared_effect_scale);

// The surface-resolved geometry + style for one preview frame.
struct PreviewCameraPlan {
  clingfy::capture::CameraBubbleRect bubble;
  clingfy::capture::CameraBubblePainter::Style style;
};

// Pure: resolve `comp` onto a `canvas_w` x `canvas_h` preview surface whose
// export-relative scale is `effect_scale`.
//
// This exists as a free function so the scaling can be asserted without a D2D
// device — `PrepareAndAdvance` needs a real camera file and a GPU, so wiring
// bugs there would otherwise only be catchable by the pixel test.
PreviewCameraPlan ResolvePreviewCameraPlan(const PreviewCameraComposition& comp,
                                           double canvas_w, double canvas_h,
                                           double effect_scale);

class PreviewCameraRenderer {
 public:
  // Open `camera_path` (BGRA decode) for seeking. `start_offset_ms` is the
  // camera.meta.json sync key. Returns nullptr when the file is missing /
  // unreadable / has no video stream → the preview proceeds camera-free.
  static std::unique_ptr<PreviewCameraRenderer> Create(
      const std::wstring& camera_path, std::int64_t start_offset_ms);

  // Update the desired composition (thread-safe). Marks the painter dirty so the
  // next PrepareAndAdvance rebuilds the mask/border/shadow. Cheap; does no D2D.
  void SetComposition(const PreviewCameraComposition& composition);

  // OUTSIDE BeginDraw: (re)build the painter if the composition or canvas
  // changed, then seek/advance + upload the camera frame for `playback_us`.
  // No-op when not visible. `canvas_w`/`canvas_h` are the preview output size.
  //
  // `effect_scale` is short_side(this surface) / short_side(export canvas) —
  // see `PreviewCameraEffectScale`. It resolves the authored border width,
  // shadow table and bubble min-side floor, all of which are expressed in
  // export-output pixels, onto this smaller texture. Pass 1.0 to render at
  // export scale.
  void PrepareAndAdvance(ID2D1DeviceContext* ctx, UINT canvas_w, UINT canvas_h,
                         std::int64_t playback_us, double effect_scale);

  // INSIDE BeginDraw: draw the styled bubble for the frame advanced to above.
  //
  // `frame_ms` / `total_duration_ms` drive the intro/outro animation and are
  // EDITED-timeline values, NOT the source `playback_us` handed to
  // PrepareAndAdvance. That split is deliberate and mirrors the export, which
  // advances the camera VIDEO on source time while running the animation clock
  // on edited time (export_pipeline.cpp, "camera_clock_ms"): on a trimmed
  // project the source origin may never be reached in the edited preview, so a
  // source-keyed intro would fire somewhere the user never sees. A
  // total_duration_ms <= 0 (duration not resolved yet) resolves to a static
  // bubble rather than an error.
  // `screen_zoom` is the preview compositor's smoothed smart-zoom factor for
  // this frame; it scales the bubble (scale-with-screen-zoom) without moving
  // it under the zoom transform. Pass 1.0 when not zooming.
  void Draw(ID2D1DeviceContext* ctx, std::int64_t frame_ms,
            std::int64_t total_duration_ms, double screen_zoom);

 private:
  PreviewCameraRenderer() = default;

  bool UploadSample(IMFSample* sample);
  // Seek the reader to `camera_hns` and reset the decode cursor.
  void SeekTo(std::int64_t camera_hns);
  // Pull forward (no seek) until the held frame is the latest <= camera_hns.
  void PullForward(std::int64_t camera_hns);

  Microsoft::WRL::ComPtr<IMFSourceReader> reader_;
  DWORD stream_index_ = 0;
  UINT cam_w_ = 0;
  UINT cam_h_ = 0;
  std::int64_t start_offset_ms_ = 0;

  // Pending composition (guarded). dirty_ → rebuild painter on next Prepare.
  std::mutex mutex_;
  PreviewCameraComposition composition_;
  bool dirty_ = true;

  // Painter + the canvas it was prepared for (rebuild on canvas change).
  clingfy::capture::CameraBubblePainter painter_;
  bool painter_ready_ = false;
  UINT prepared_canvas_w_ = 0;
  UINT prepared_canvas_h_ = 0;
  double prepared_effect_scale_ = 1.0;
  bool composition_visible_ = false;  // snapshot used by Draw

  // Animation context, resolved alongside the painter rebuild and consumed by
  // Draw — the same state CameraExportRenderer::Prepare caches. It must be
  // recomputed in the rebuild branch rather than once at construction: the
  // bubble rect and the slide edge both depend on the live placement, so
  // dragging the bubble from the right edge to the left would otherwise keep
  // sliding it out the right.
  clingfy::capture::CameraAnimationParams anim_params_;
  clingfy::capture::CameraBubbleRect bubble_;
  double canvas_w_ = 0.0;
  double canvas_h_ = 0.0;
  clingfy::capture::CameraSlideEdge slide_edge_ =
      clingfy::capture::CameraSlideEdge::kRight;
  // Scale-with-screen-zoom inputs; the scale itself is per-frame in Draw.
  std::string zoom_behavior_;
  double zoom_scale_multiplier_ = 0.0;
  std::string layout_preset_;

  // Decode cursor (frame-server thread only). A pending sample buffer (like the
  // export renderer) parks a peeked future frame so normal forward playback
  // never SKIPS a frame, and a paused position never re-seeks every frame.
  Microsoft::WRL::ComPtr<ID2D1Bitmap1> frame_bitmap_;
  std::vector<BYTE> scratch_;
  Microsoft::WRL::ComPtr<IMFSample> pending_sample_;
  std::int64_t pending_pts_hns_ = 0;
  bool has_pending_ = false;
  std::int64_t held_pts_hns_ = -1;  // pts of the currently uploaded frame
  bool has_held_frame_ = false;
  bool eos_ = false;
};

}  // namespace clingfy::preview

#endif  // RUNNER_PREVIEW_PREVIEW_CAMERA_RENDERER_H_
