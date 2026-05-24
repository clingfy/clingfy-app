#ifndef RUNNER_CAPTURE_WGC_DISPLAY_CAPTURE_BACKEND_H_
#define RUNNER_CAPTURE_WGC_DISPLAY_CAPTURE_BACKEND_H_

#include <windows.h>

#include <cstdint>
#include <memory>
#include <optional>
#include <string>

#include "Capture/video_frame_queue.h"

namespace clingfy::graphics {
class D3DDevice;
}

// Windows.Graphics.Capture display-capture backend.
//
// Phase 3B's job: stand up a capture session for a single HMONITOR, push
// each arriving frame into a `VideoFrameQueue`, and tear everything down
// cleanly on `Stop()`. Phase 3C will read out of the queue.
//
// All of the WinRT plumbing — `GraphicsCaptureItem`, `Direct3D11Device`,
// `Direct3D11CaptureFramePool`, `GraphicsCaptureSession` — lives in the
// implementation file behind an opaque `Impl` so headers that include this
// one do not have to drag in `<winrt/...>` or `<windows.graphics.capture.h>`.
namespace clingfy::capture {

struct WgcCaptureError {
  std::string message;
  HRESULT hr = 0;
};

struct WgcCaptureStats {
  std::uint32_t frame_width = 0;
  std::uint32_t frame_height = 0;
  std::uint64_t frames_received = 0;
  std::uint64_t frames_dropped = 0;
};

class WgcDisplayCaptureBackend {
 public:
  WgcDisplayCaptureBackend();
  ~WgcDisplayCaptureBackend();

  WgcDisplayCaptureBackend(const WgcDisplayCaptureBackend&) = delete;
  WgcDisplayCaptureBackend& operator=(const WgcDisplayCaptureBackend&) = delete;

  // Spins up a capture session for `monitor`, using `device` for surface
  // allocation. Captured frames are pushed into `queue` (the engine owns
  // it; the backend just holds a non-owning pointer so Phase 3C's encoder
  // can drain the same instance).
  //
  // Returns std::nullopt on success.
  std::optional<WgcCaptureError> Start(HMONITOR monitor,
                                       clingfy::graphics::D3DDevice& device,
                                       VideoFrameQueue& queue);

  // Stops the capture session, closes the frame pool, and waits for any
  // in-flight FrameArrived callbacks to drain before returning. Safe to
  // call multiple times.
  void Stop();

  // Snapshot of frame counters for diagnostics / smoke-test logging.
  WgcCaptureStats Stats() const;

  bool running() const;

 private:
  // Pimpl so the WinRT types stay out of the public header — keeps the
  // headers in this PR free of `<winrt/...>` includes that would otherwise
  // bleed into every consumer of `recording_engine.h`.
  class Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_WGC_DISPLAY_CAPTURE_BACKEND_H_
