#ifndef RUNNER_CAPTURE_WGC_DISPLAY_CAPTURE_BACKEND_H_
#define RUNNER_CAPTURE_WGC_DISPLAY_CAPTURE_BACKEND_H_

#include <windows.h>

#include <cstdint>
#include <functional>
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

// Phase 7.1: the pixel size WGC will deliver for a window-capture item. The
// engine probes this BEFORE opening the encoder so the encoder is sized to the
// window, not the monitor. Returns std::nullopt when the window is invalid or
// WGC cannot build a capture item for it.
struct WgcTargetSize {
  std::uint32_t width = 0;
  std::uint32_t height = 0;
};
std::optional<WgcTargetSize> ResolveWindowCaptureSize(HWND window);

// Single source of truth for the capture-vs-encoder even-dimension contract.
// H.264 requires even frame dimensions; monitor sizes are even in practice but
// window content sizes are arbitrary (often odd). Both the encoder config (in
// the engine) AND the captured frame (in this backend's frame copy) clamp DOWN
// to even through THIS function, so the encoder input size always equals the
// surface size it is handed — a 1px odd edge is dropped rather than mismatched.
// Pure (no Win32) so it is unit-tested without a GPU.
std::uint32_t EvenCaptureDimension(std::uint32_t value);

// Phase 7.2: a resolved area-recording crop box on a captured monitor surface,
// in monitor-local physical pixels (origin = monitor top-left). width/height
// are even (H.264); width/height == 0 means the requested region was empty / off
// the surface.
struct CaptureCropBox {
  std::uint32_t x = 0;
  std::uint32_t y = 0;
  std::uint32_t width = 0;
  std::uint32_t height = 0;
};

// Resolve a requested area rectangle (monitor-local px) against the captured
// surface size: clamp the origin into the surface, clamp the size to what fits,
// and even-align width/height via EvenCaptureDimension. Pure (no Win32) — the
// SAME function sizes the encoder (engine) and the crop box (backend), so they
// agree by construction. A degenerate / off-surface request yields width or
// height == 0.
CaptureCropBox ResolveCropBox(std::uint32_t src_width, std::uint32_t src_height,
                              std::int64_t req_x, std::int64_t req_y,
                              std::int64_t req_width, std::int64_t req_height);

class WgcDisplayCaptureBackend {
 public:
  WgcDisplayCaptureBackend();
  ~WgcDisplayCaptureBackend();

  WgcDisplayCaptureBackend(const WgcDisplayCaptureBackend&) = delete;
  WgcDisplayCaptureBackend& operator=(const WgcDisplayCaptureBackend&) = delete;

  // Phase 7.4: install a "the capture target was lost" callback BEFORE any
  // Start*. WGC raises `GraphicsCaptureItem.Closed` when the captured window is
  // closed OR the captured monitor is unplugged; this backend forwards that
  // single signal to `callback`. The callback fires at most once per session,
  // on a WinRT thread-pool thread — it MUST NOT call back into this backend
  // synchronously (the engine marshals to the platform thread and then runs the
  // stop+finalize). Passing an empty std::function disables the notification.
  void SetTargetLostCallback(std::function<void()> callback);

  // Test seam: return a COPY of the target-lost callback that a real
  // GraphicsCaptureItem.Closed delivery would invoke (the live session guard's
  // copy when running, else the pending one). The caller invokes it itself,
  // OUTSIDE any backend method, so the teardown it triggers does not destroy
  // this backend while a method of it is still on the stack — mirroring how the
  // real Closed lambda (which captures a shared guard, not `this`) stays valid.
  // Returns an empty std::function when none is installed.
  std::function<void()> GetTargetLostCallbackForTesting();

  // Spins up a capture session for `monitor`, using `device` for surface
  // allocation. Captured frames are pushed into `queue` (the engine owns
  // it; the backend just holds a non-owning pointer so Phase 3C's encoder
  // can drain the same instance).
  //
  // Returns std::nullopt on success.
  std::optional<WgcCaptureError> Start(HMONITOR monitor,
                                       clingfy::graphics::D3DDevice& device,
                                       VideoFrameQueue& queue);

  // Phase 7.1: window capture. Spins up a session for a top-level `window`
  // (HWND) via `IGraphicsCaptureItemInterop::CreateForWindow` — the analog of
  // the monitor path above. The window must be valid (the engine validates it
  // first; this also re-checks `IsWindow`). Everything downstream (frame pool,
  // FrameArrived copy, queue push, cursor-on) is identical to `Start(HMONITOR)`.
  // Returns std::nullopt on success.
  std::optional<WgcCaptureError> StartForWindow(
      HWND window, clingfy::graphics::D3DDevice& device,
      VideoFrameQueue& queue);

  // Phase 7.2: area capture. Captures the full `monitor` (the existing display
  // path) but crops every frame to `crop` (a resolved CaptureCropBox in
  // monitor-local physical pixels) before pushing it downstream, so the encoder
  // — sized to crop.width/height by the engine — receives exactly the cropped
  // region. `crop` must be non-empty (width/height > 0). Returns std::nullopt on
  // success.
  std::optional<WgcCaptureError> StartForArea(
      HMONITOR monitor, CaptureCropBox crop,
      clingfy::graphics::D3DDevice& device, VideoFrameQueue& queue);

  // Stops the capture session, closes the frame pool, and waits for any
  // in-flight FrameArrived callbacks to drain before returning. Safe to
  // call multiple times.
  void Stop();

  // Phase 4: pause / resume. While paused, the FrameArrived handler
  // closes incoming WGC frames immediately and drops them on the
  // floor — no queue push, no extra D3D copies. WGC keeps producing
  // (we don't close the pool) because re-opening it on resume would
  // race the GraphicsCaptureItem activation, but the cost is just
  // wasted work in the system thread pool, not bandwidth or memory.
  void Pause();
  void Resume();
  bool paused() const;

  // Phase 8.1: toggle WGC cursor capture on the LIVE session. The session starts
  // cursor-on (Phase 7 default); the engine calls this with `false` only after a
  // cursor sidecar sampler is confirmed running, so we never ship a cursorless
  // video when sampling fails. Best-effort + safe to call before/after Start.
  void SetCursorCaptureEnabled(bool enabled);

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
