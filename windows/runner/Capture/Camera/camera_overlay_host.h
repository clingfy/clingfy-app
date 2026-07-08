#ifndef RUNNER_CAPTURE_CAMERA_CAMERA_OVERLAY_HOST_H_
#define RUNNER_CAPTURE_CAMERA_CAMERA_OVERLAY_HOST_H_

#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>

#include "Capture/Camera/camera_overlay_presenter.h"

// Renderer redesign P4c-c3 — the mid-session GDI fallback owner.
//
// A thin ICameraOverlayPresenter that wraps the factory-selected inner
// presenter (StartCameraOverlayPresenter's DComp-or-GDI ladder) and, when the
// inner presenter parks on persistent device loss (needs_fallback()), swaps it
// once for the safe-mode GDI presenter WITHOUT the RecordingEngine noticing —
// the engine keeps its single ICameraOverlayPresenter handle and its existing
// Show/Hide/Publish/Stop/wda_excluded call sites.
//
// The swap runs inside PublishBgra, i.e. on the camera capture thread (the
// only per-frame signal): it Stops the parked inner presenter (which posts
// WM_QUIT to and joins that presenter's own overlay thread — a different
// thread, so no deadlock) and Starts a GDI CameraFloatingOverlay at the same
// placement, re-Showing it only if the bubble was showing AND the new
// presenter's capture-exclusion succeeded (the never-show-an-unexcluded-bubble
// invariant). One-shot: the GDI presenter never asks to fall back, so there is
// no re-entry.
namespace clingfy::capture {

class CameraOverlayHost : public ICameraOverlayPresenter {
 public:
  // Factory for the fallback (GDI) presenter, injectable for tests. Default:
  // a started CameraFloatingOverlay, or nullptr if it could not start.
  using GdiFactory =
      std::function<std::shared_ptr<ICameraOverlayPresenter>(
          const FloatingPlacement&)>;

  CameraOverlayHost() = default;
  explicit CameraOverlayHost(GdiFactory gdi_factory)
      : gdi_factory_(std::move(gdi_factory)) {}

  // Start via the production ladder (StartCameraOverlayPresenter). Returns
  // false when nothing could start (the engine then runs in-app-texture-only,
  // matching the pre-host nullptr contract — the caller drops the host).
  bool Start(const FloatingPlacement& placement) override;

  void Show() override;
  void Hide() override;
  // Swap-then-forward: performs the one-time device-loss fallback if the inner
  // presenter parked, then forwards the frame to the current inner presenter.
  void PublishBgra(const std::uint8_t* bgra, int width, int height) override;
  void Stop() override;
  bool running() const override;
  bool wda_excluded() const override;
  // The host absorbs fallback; it never asks its own owner to swap it.
  bool needs_fallback() const override { return false; }

  // Test seam: adopt an ALREADY-STARTED inner presenter (e.g. a fault-injected
  // DComp presenter) plus its placement, instead of running the ladder.
  void AdoptInnerForTest(std::shared_ptr<ICameraOverlayPresenter> inner,
                         const FloatingPlacement& placement);
  // Test introspection: true once the device-loss fallback swap has run.
  bool did_fall_back_for_test() const;

 private:
  // Perform the DComp->GDI swap if the inner presenter parked. Caller holds
  // mutex_. No-op unless inner_ exists and needs_fallback() is true.
  void MaybeFallbackLocked();

  mutable std::mutex mutex_;
  std::shared_ptr<ICameraOverlayPresenter> inner_;
  FloatingPlacement placement_{};
  bool showing_ = false;
  bool fell_back_ = false;
  GdiFactory gdi_factory_;
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CAMERA_CAMERA_OVERLAY_HOST_H_
