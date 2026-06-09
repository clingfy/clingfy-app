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
};

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
  void PrepareAndAdvance(ID2D1DeviceContext* ctx, UINT canvas_w, UINT canvas_h,
                         std::int64_t playback_us);

  // INSIDE BeginDraw: draw the styled bubble for the frame advanced to above.
  void Draw(ID2D1DeviceContext* ctx);

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
  bool composition_visible_ = false;  // snapshot used by Draw

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
