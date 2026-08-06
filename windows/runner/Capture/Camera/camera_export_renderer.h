#ifndef RUNNER_CAPTURE_CAMERA_CAMERA_EXPORT_RENDERER_H_
#define RUNNER_CAPTURE_CAMERA_CAMERA_EXPORT_RENDERER_H_

#include <d2d1_1.h>
// mfidl.h (IMFSample / IMFMediaSource / IMFAttributes) MUST precede
// mfreadwrite.h (IMFSourceReader), which references those types unqualified.
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "Capture/Camera/camera_bubble_painter.h"
#include "Capture/Camera/camera_export_layout.h"

// Phase 9.4/9.5 — composites the recorded `camera/raw.mov` into the export as an
// editable, styled bubble.
//
// Owns a second system-memory `IMFSourceReader` on `raw.mov` and, for each export
// frame at recording-relative `frame_ms`, holds the camera frame at
// `cameraTimeMs = frame_ms - startOffsetMs` via a forward-only (monotonic) pull
// — export frames advance monotonically, so no seeking is needed. The styled
// draw (mask / mirror / opacity / border / shadow) is delegated to the shared
// `CameraBubblePainter` so it is byte-identical to the inline-preview camera.
//
// All failures are soft: Create returns nullptr, Prepare returns false; the
// caller then exports screen-only.
namespace clingfy::capture {

class CameraExportRenderer {
 public:
  using Style = CameraBubblePainter::Style;

  static std::unique_ptr<CameraExportRenderer> Create(
      const std::wstring& camera_path, std::int64_t start_offset_ms);

  bool Prepare(ID2D1Factory1* factory, ID2D1DeviceContext* ctx,
               const CameraBubbleRect& bubble, const std::string& shape,
               double corner_radius, const std::string& content_mode,
               const Style& style, const CameraAnimationParams& anim,
               double canvas_w, double canvas_h, CameraSlideEdge slide_edge,
               const std::string& zoom_behavior, double zoom_scale_multiplier,
               const std::string& layout_preset);

  // Advance the held camera frame forward to `frame_ms - startOffsetMs`, decoding
  // + uploading the new frame. Call OUTSIDE BeginDraw/EndDraw. No-op before the
  // camera's first frame; holds the final frame after EOS.
  void Advance(std::int64_t frame_ms);

  // Seek the camera reader so the next Advance re-primes from `frame_ms` rather
  // than the forward-only pull's current (later) position. Editing port (clips,
  // 3b-2, §5.5): call at a reorder range boundary where the source clock jumps
  // BACKWARD — the forward-only Advance cannot rewind, so without this the bubble
  // would freeze on a stale later frame. MF seeks to the nearest prior keyframe;
  // the next Advance decodes forward to the exact frame. Call OUTSIDE
  // BeginDraw/EndDraw. No-op before Prepare.
  void SeekTo(std::int64_t frame_ms);

  // Draw the held camera frame as a styled bubble, applying the Phase 9.7
  // intro/outro animation for recording-relative `frame_ms` of a
  // `total_duration_ms` clip. Call INSIDE BeginDraw/EndDraw in canvas space (NOT
  // under smart zoom). No-op before the first frame.
  //
  // `screen_zoom` is the SMOOTHED per-frame smart-zoom factor. It reaches the
  // bubble only as a scalar that grows it (scale-with-screen-zoom); the bubble
  // is still drawn in canvas space, deliberately outside the zoom transform, so
  // it never pans with the magnified screen. Pass 1.0 when not zooming.
  void Draw(ID2D1DeviceContext* ctx, std::int64_t frame_ms,
            std::int64_t total_duration_ms, double screen_zoom);

  bool ready() const { return ready_; }

 private:
  CameraExportRenderer() = default;

  bool UploadSample(IMFSample* sample);

  Microsoft::WRL::ComPtr<IMFSourceReader> reader_;
  DWORD stream_index_ = 0;
  UINT cam_w_ = 0;
  UINT cam_h_ = 0;
  std::int64_t start_offset_ms_ = 0;

  // Phase 9.7 animation context, resolved once at Prepare. `anim_params_`'s
  // zoom_scale is the one field that is NOT loop-invariant — it is recomputed
  // per frame in Draw from the live screen zoom.
  CameraAnimationParams anim_params_{};
  // Scale-with-screen-zoom inputs, captured at Prepare alongside the rest.
  std::string zoom_behavior_;
  double zoom_scale_multiplier_ = 0.0;
  std::string layout_preset_;
  CameraBubbleRect bubble_{};
  double canvas_w_ = 0.0;
  double canvas_h_ = 0.0;
  CameraSlideEdge slide_edge_ = CameraSlideEdge::kRight;

  Microsoft::WRL::ComPtr<IMFSample> pending_sample_;
  std::int64_t pending_pts_hns_ = 0;
  bool has_pending_ = false;
  bool has_held_frame_ = false;
  bool eos_ = false;
  std::vector<BYTE> scratch_;

  Microsoft::WRL::ComPtr<ID2D1Bitmap1> frame_bitmap_;
  CameraBubblePainter painter_;
  bool ready_ = false;
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CAMERA_CAMERA_EXPORT_RENDERER_H_
