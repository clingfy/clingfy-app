#ifndef RUNNER_CAPTURE_CAPTURED_VIDEO_FRAME_H_
#define RUNNER_CAPTURE_CAPTURED_VIDEO_FRAME_H_

#include <d3d11.h>
#include <wrl/client.h>

#include <cstdint>

// One captured display frame on its way from the WGC capture backend to the
// encoder. Phase 3B only fills these from `WgcDisplayCaptureBackend` and
// drops them on the floor (no encoder yet); Phase 3C wires the
// `MfSinkWriterEncoder` to drain `VideoFrameQueue` and emit MP4 samples.
//
// `texture` holds a strong reference (`ComPtr`) so the GPU resource stays
// alive until the consumer is done with it. The capture backend recycles
// frame-pool buffers, so without the refcount bump the underlying surface
// would be reused for the next frame before the encoder could read it.
namespace clingfy::capture {

struct CapturedVideoFrame {
  Microsoft::WRL::ComPtr<ID3D11Texture2D> texture;
  std::uint32_t width = 0;
  std::uint32_t height = 0;
  // System-relative timestamp in 100-nanosecond units (Media Foundation's
  // canonical timestamp unit, matches `RecordingClock::ElapsedHns`).
  std::int64_t timestamp_hns = 0;
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CAPTURED_VIDEO_FRAME_H_
