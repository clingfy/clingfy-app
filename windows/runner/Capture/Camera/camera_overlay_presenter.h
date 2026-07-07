#ifndef RUNNER_CAPTURE_CAMERA_CAMERA_OVERLAY_PRESENTER_H_
#define RUNNER_CAPTURE_CAMERA_CAMERA_OVERLAY_PRESENTER_H_

#include <cstdint>
#include <memory>

// Presenter abstraction for the live floating camera bubble (renderer redesign
// P2 — docs/decisions/windows-camera-bubble-renderer-architecture.md).
//
// The bubble's LOOK and PLACEMENT come from the shared CameraOverlayStyleStore /
// CameraOverlayGeometryStore (revision-sampled), and its frames from
// CameraRecorder's preview callback — so a presenter is only the WINDOW + DRAW
// technology. Two implementations are planned:
//
//   * CameraFloatingOverlay (camera_floating_overlay.h) — the shipping opaque
//     GDI window ("GdiOpaquePresenter" in the design doc). Renders shape /
//     roundness / mirror / border / geometry live; opacity / shadow / glow /
//     chroma are export-only on it (no per-pixel alpha). The safe-mode
//     fallback.
//   * DComp presenter (P3) — WS_EX_NOREDIRECTIONBITMAP + DirectComposition
//     premultiplied-alpha swapchain + the shared CameraBubblePainter; renders
//     the full style live.
//
// RecordingEngine owns presenters only through this interface + the factory
// below, so swapping/falling back never touches engine logic.
namespace clingfy::capture {

// Initial window placement in physical screen pixels. The presenter corrects
// it from the geometry store before it is ever shown; this is just a sane
// creation-time rect on the capture display.
struct FloatingPlacement {
  int x = 0;
  int y = 0;
  int width = 0;
  int height = 0;
  bool rounded = true;
};

class ICameraOverlayPresenter {
 public:
  virtual ~ICameraOverlayPresenter() = default;

  // Create the (hidden) window + apply capture-exclusion. Blocks until the
  // window is up (or creation failed). Returns false on failure — the caller
  // continues without a floating bubble.
  virtual bool Start(const FloatingPlacement& placement) = 0;

  // Show / hide the bubble. The engine must never Show() a presenter whose
  // wda_excluded() is false — it would be burned into the recording.
  virtual void Show() = 0;
  virtual void Hide() = 0;

  // Feed the latest camera frame (tightly-packed BGRA, stride = width*4).
  // Thread-safe; the caller's buffer is copied. A no-op before Start / after
  // Stop.
  virtual void PublishBgra(const std::uint8_t* bgra, int width,
                           int height) = 0;

  // Tear the window down. Idempotent. Call after the frame producer is
  // stopped so no PublishBgra races teardown.
  virtual void Stop() = 0;

  virtual bool running() const = 0;

  // True only when SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE) succeeded.
  // Best-effort by OS design (a documented Win11 defect can fail the call
  // outright) — which is why this is probed at runtime, never assumed.
  virtual bool wda_excluded() const = 0;
};

// Select and construct the presenter for this recording. P2 scaffolding:
// always the GDI opaque presenter; P3 adds the DirectComposition attempt with
// GDI fallback. Honors the support kill switch — the environment variable
// CLINGFY_FORCE_GDI_OVERLAY (any non-empty value) pins the GDI presenter —
// and logs the selection to the device-probe log.
std::shared_ptr<ICameraOverlayPresenter> CreateCameraOverlayPresenter();

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CAMERA_CAMERA_OVERLAY_PRESENTER_H_
