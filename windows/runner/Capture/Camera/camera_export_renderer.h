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
               const Style& style);

  // Advance the held camera frame forward to `frame_ms - startOffsetMs`, decoding
  // + uploading the new frame. Call OUTSIDE BeginDraw/EndDraw. No-op before the
  // camera's first frame; holds the final frame after EOS.
  void Advance(std::int64_t frame_ms);

  // Draw the held camera frame as a styled bubble. Call INSIDE BeginDraw/EndDraw
  // in canvas space (NOT under smart zoom). No-op before the first frame.
  void Draw(ID2D1DeviceContext* ctx);

  bool ready() const { return ready_; }

 private:
  CameraExportRenderer() = default;

  bool UploadSample(IMFSample* sample);

  Microsoft::WRL::ComPtr<IMFSourceReader> reader_;
  DWORD stream_index_ = 0;
  UINT cam_w_ = 0;
  UINT cam_h_ = 0;
  std::int64_t start_offset_ms_ = 0;

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
