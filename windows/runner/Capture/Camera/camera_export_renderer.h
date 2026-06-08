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

#include "Capture/Camera/camera_export_layout.h"

// Phase 9.4 — composites the recorded `camera/raw.mov` into the export as an
// editable bubble.
//
// The recording keeps the camera OUT of `screen.mov` (the live preview is an
// in-app Flutter texture, `previewBurnedIn=false`), so the export draws the
// camera exactly once from its own file. This renderer owns a second
// system-memory `IMFSourceReader` on `raw.mov` and, for each export frame at
// recording-relative `frame_ms`, holds the camera frame at
// `cameraTimeMs = frame_ms - startOffsetMs` (the 9.2 sync key). Both timelines
// are pause-aware, so a held-frame pull-forward (no seeking) stays aligned
// across pause/resume.
//
// All failures are soft: Create returns nullptr (bad/missing file) and Prepare
// returns false (D2D resource failure); the caller then exports screen-only.
namespace clingfy::capture {

class CameraExportRenderer {
 public:
  // Open `camera_path` and negotiate BGRA decode. `start_offset_ms` is the
  // camera.meta.json sync key. Returns nullptr when the file is missing /
  // unreadable / has no video stream — the export proceeds screen-only.
  static std::unique_ptr<CameraExportRenderer> Create(
      const std::wstring& camera_path, std::int64_t start_offset_ms);

  // Build the bubble mask + the source bitmap + the cover/contain dest rect on
  // this device. `shape` is the CameraShape enum name ("circle" / "roundedRect"
  // / "square" / "squircle"); `corner_radius` is the Dart 0..0.5 fraction;
  // `content_mode` is "fill" (cover, default) or "fit" (contain). Returns false
  // if a resource could not be created (caller then skips the camera). Call once.
  bool Prepare(ID2D1Factory1* factory, ID2D1DeviceContext* ctx,
               const CameraBubbleRect& bubble, const std::string& shape,
               double corner_radius, const std::string& content_mode);

  // Advance the held camera frame forward to `frame_ms - startOffsetMs` (the
  // 9.2 sync key), decoding + uploading the new frame into the source bitmap.
  // Call OUTSIDE BeginDraw/EndDraw — it does the CopyFromMemory upload, matching
  // how the pipeline uploads the screen frame before the composite. No-op before
  // the camera's first frame; holds the final frame after EOS.
  void Advance(std::int64_t frame_ms);

  // Draw the held camera frame as a masked bubble. Call INSIDE BeginDraw/EndDraw
  // in canvas space (NOT under the smart-zoom transform). No-op when there is no
  // held frame yet (before the camera started) or Prepare failed.
  void Draw(ID2D1DeviceContext* ctx);

  bool ready() const { return ready_; }

 private:
  CameraExportRenderer() = default;

  // Decode `sample` (RGB32) into `frame_bitmap_`. Returns false on a buffer
  // lock / copy failure (the previous held frame, if any, stays).
  bool UploadSample(IMFSample* sample);

  Microsoft::WRL::ComPtr<IMFSourceReader> reader_;
  DWORD stream_index_ = 0;
  UINT cam_w_ = 0;
  UINT cam_h_ = 0;
  std::int64_t start_offset_ms_ = 0;

  // Decode cursor (pull-forward, no seeking).
  Microsoft::WRL::ComPtr<IMFSample> pending_sample_;
  std::int64_t pending_pts_hns_ = 0;
  bool has_pending_ = false;
  bool has_held_frame_ = false;
  bool eos_ = false;
  std::vector<BYTE> scratch_;  // reused top-down BGRA staging

  // D2D resources (built in Prepare, reused every frame).
  Microsoft::WRL::ComPtr<ID2D1Bitmap1> frame_bitmap_;
  Microsoft::WRL::ComPtr<ID2D1Geometry> mask_geometry_;  // null => square clip
  Microsoft::WRL::ComPtr<ID2D1Layer> mask_layer_;
  D2D1_RECT_F bubble_rect_{};  // the square bubble on the canvas
  D2D1_RECT_F dest_rect_{};    // where the camera bitmap draws (cover/contain)
  bool ready_ = false;
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CAMERA_CAMERA_EXPORT_RENDERER_H_
