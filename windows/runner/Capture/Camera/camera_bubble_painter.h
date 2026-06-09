#ifndef RUNNER_CAPTURE_CAMERA_CAMERA_BUBBLE_PAINTER_H_
#define RUNNER_CAPTURE_CAMERA_CAMERA_BUBBLE_PAINTER_H_

#include <d2d1_1.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include <cstdint>
#include <string>
#include <vector>

#include "Capture/Camera/camera_export_layout.h"

// Phase 9.6 — the SHARED, frame-source-agnostic painter for the camera bubble.
//
// Extracted from the Phase 9.4/9.5 export renderer so the export pipeline and the
// post-record inline preview draw the camera identically — WYSIWYG between what
// you style in the editor and what the exported file shows. The painter owns the
// static, loop-invariant resources (mask geometry/layer, cover/contain dest rect,
// border brush, baked blurred shadow) and draws them around a caller-supplied
// "current camera frame" bitmap. It does NOT decode video — the export renderer
// feeds it a monotonically pulled frame, the preview renderer feeds it a seeked
// frame, but the masked/mirrored/opacity/border/shadow draw is one code path.
namespace clingfy::capture {

// Copy an RGB32 `sample` into a tightly-packed top-down BGRA buffer (pitch =
// width*4). Prefers IMF2DBuffer's stride-aware lock, falls back to a contiguous
// buffer assumed top-down packed. Shared by both camera frame sources.
bool ExtractCameraFrameBgra(IMFSample* sample, UINT width, UINT height,
                            std::vector<BYTE>* dest);

class CameraBubblePainter {
 public:
  struct Style {
    bool mirror = false;
    double opacity = 1.0;
    double border_width = 0.0;
    bool has_border_color = false;
    std::uint32_t border_argb = 0;
    int shadow_preset = 0;
  };

  // Build the mask + cover/contain dest rect + border brush + baked shadow for a
  // `cam_w` x `cam_h` source drawn into `bubble` on the canvas. `shape` is the
  // CameraShape enum name; `corner_radius` the Dart 0..0.5 fraction;
  // `content_mode` "fill" (cover) / "fit" (contain). Returns false only on a core
  // failure (bad inputs); styling sub-resources soft-fail individually. The
  // shadow bake does SetTarget round-trips on `ctx`, so call OUTSIDE any
  // BeginDraw/EndDraw. Call once per (canvas, params) tuple.
  bool Prepare(ID2D1Factory1* factory, ID2D1DeviceContext* ctx,
               const CameraBubbleRect& bubble, const std::string& shape,
               double corner_radius, const std::string& content_mode,
               const Style& style, UINT cam_w, UINT cam_h);

  // Draw the styled bubble around `source` (the current camera frame) on the
  // ctx's current target. Call INSIDE BeginDraw/EndDraw in canvas space (identity
  // transform, NOT under smart zoom). No-op if Prepare failed or source is null.
  void Draw(ID2D1DeviceContext* ctx, ID2D1Bitmap1* source);

  bool ready() const { return ready_; }

 private:
  void PrepareShadow(ID2D1Factory1* factory, ID2D1DeviceContext* ctx,
                     const std::string& shape, double corner_radius, double side,
                     double bubble_x, double bubble_y);

  Style style_{};
  D2D1_RECT_F bubble_rect_{};
  D2D1_RECT_F dest_rect_{};
  float bubble_cx_ = 0.0f;
  float bubble_cy_ = 0.0f;
  Microsoft::WRL::ComPtr<ID2D1Geometry> mask_geometry_;  // null => square clip
  Microsoft::WRL::ComPtr<ID2D1Layer> mask_layer_;
  Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> border_brush_;
  float border_width_px_ = 0.0f;
  Microsoft::WRL::ComPtr<ID2D1Bitmap1> shadow_bitmap_;
  D2D1_RECT_F shadow_dest_{};
  bool ready_ = false;
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CAMERA_CAMERA_BUBBLE_PAINTER_H_
