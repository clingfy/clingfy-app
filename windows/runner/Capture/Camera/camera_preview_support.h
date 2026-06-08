#ifndef RUNNER_CAPTURE_CAMERA_CAMERA_PREVIEW_SUPPORT_H_
#define RUNNER_CAPTURE_CAMERA_CAMERA_PREVIEW_SUPPORT_H_

#include <cstdint>

// Phase 9.3 — pure helpers for the live camera preview bubble.
//
// The preview shares frames from the 9.2 CameraRecorder (no second device
// reader — many webcams cannot be opened twice). The recorder hands the latest
// captured frame to these pure converters, which downscale + convert it to
// BGRA for the layered preview window. Keeping the pixel math + geometry pure
// means it is unit-tested without a camera or a window.
namespace clingfy::capture {

// The pixel format the camera capture negotiated (see camera_recorder.cpp).
// RGB32 from Media Foundation is BGRA in memory, so it maps to kBgra32.
enum class CameraPixelFormat {
  kNv12,
  kBgra32,
};

struct PreviewSize {
  int width = 0;
  int height = 0;
};

// Downscale `src_w x src_h` to fit within `max_dim` on its longer side,
// preserving aspect ratio, never upscaling. Floors each axis at 2. Returns
// {0,0} for non-positive input. The preview is small (a bubble), so converting
// at this reduced size keeps the per-frame cost off the encode hot path.
PreviewSize ComputePreviewSize(int src_w, int src_h, int max_dim);

// Convert a captured frame to tightly-packed BGRA (stride = dst_w*4, alpha 255),
// nearest-neighbour downscaling from the source to `dst_w x dst_h`.
//   * kNv12   — `src` is NV12 (Y plane `src_stride*src_h`, then interleaved UV),
//               converted with the BT.601 limited-range coefficients.
//   * kBgra32 — `src` is BGRA at `src_stride`, copied (alpha forced opaque).
// Returns false on any invalid argument (null buffers, non-positive dims); the
// caller then simply skips this preview frame. Recording is never affected.
bool ConvertToBgra(CameraPixelFormat format, const std::uint8_t* src,
                   int src_w, int src_h, int src_stride, std::uint8_t* dst_bgra,
                   int dst_w, int dst_h);

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CAMERA_CAMERA_PREVIEW_SUPPORT_H_
