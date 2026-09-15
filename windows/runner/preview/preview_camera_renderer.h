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
#include "Capture/Camera/camera_render_plan.h"

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

// The authored camera composition. An alias of the shared spec: the body used
// to live here and was field-for-field identical to the one the export parsed
// into, which is how an effect_scale defect could exist on one leg and not the
// other. The name stays so the bridge parser, the routers and the engine read
// unchanged; see camera_render_plan.h for the fields and their wire defaults.
using PreviewCameraComposition = clingfy::capture::CameraRenderSpec;

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
//
// `painter_ready` is the RETRY term, and it is the reason this predicate now
// answers the question completely rather than partially. It used to sit at the
// call site as `if (needs_rebuild || !painter_ready_)`, which meant the one
// path that recovers from a failed painter build was the one path no test
// could reach. A rebuild can fail (the bitmap or the D2D factory is
// unavailable for a frame), and nothing else would ever ask again: the canvas
// and the scale are unchanged, so every other term reads false forever and the
// camera silently never draws for the rest of the session.
//
// It is deliberately the LAST parameter rather than sitting beside `dirty`: a
// transposed argument next to another bool could invert two terms at once and
// still compile.
bool PreviewCameraNeedsRebuild(bool dirty, UINT canvas_w, UINT canvas_h,
                               double effect_scale, UINT prepared_canvas_w,
                               UINT prepared_canvas_h,
                               double prepared_effect_scale,
                               bool painter_ready);

// The surface-resolved geometry + style for one preview frame, plus the
// animation invariants and the zoom inputs Draw needs. An alias, not a type:
// there is ONE plan and one builder, shared with the export leg.
using PreviewCameraPlan = clingfy::capture::CameraRenderPlan;

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
  // `zoom_in_segment` / `zoom_segment_local_ms` are the zoom-SEGMENT state for
  // this frame, from the compositor's ZoomState — which since the shared-segment
  // slice resolves through the SAME ZoomSegmentStateAt over the SAME builder's
  // segments the export uses. That identity is what lets the pulse be in phase
  // between the editor and the exported file; see
  // CameraAnimationParams::zoom_local_seconds for why phase is the whole game.
  // Not defaulted, for the reason given on CameraExportRenderer::Draw.
  void Draw(ID2D1DeviceContext* ctx, std::int64_t frame_ms,
            std::int64_t total_duration_ms, double screen_zoom,
            bool zoom_in_segment, std::int64_t zoom_segment_local_ms);

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

  // The loop-invariant render plan, built alongside the painter rebuild and
  // consumed by Draw — the same state CameraExportRenderer::Prepare caches. It
  // must be rebuilt in the rebuild branch rather than once at construction: the
  // bubble rect and the slide edge both depend on the live placement, so
  // dragging the bubble from the right edge to the left would otherwise keep
  // sliding it out the right.
  //
  // This replaced eight separate cached members (the params, the bubble, the
  // canvas pair, the slide edge and the zoom trio). They were the export leg's
  // Prepare-time cache, spelled a second time; one plan is the point of the
  // shared builder.
  clingfy::capture::CameraRenderPlan plan_;

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
