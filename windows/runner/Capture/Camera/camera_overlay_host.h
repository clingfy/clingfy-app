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
// The swap Stops the parked inner presenter (which posts WM_QUIT to and joins
// that presenter's own overlay thread) and Starts a GDI CameraFloatingOverlay
// at the same placement, re-Showing it only if the bubble was showing AND the
// new presenter's capture-exclusion succeeded (the
// never-show-an-unexcluded-bubble invariant). One-shot: the GDI presenter never
// asks to fall back, so there is no re-entry.
//
// TWO TRIGGERS, because the park is produced on a clock the frames do not
// share:
//
//   * PublishBgra — the camera capture thread, polling needs_fallback().
//   * SetParkObserver — pushed from the presenter's own 33 ms tick.
//
// The poll alone was not enough. The DComp presenter reaches its park entirely
// from its timer (the tick-top rebuild retry needs no frame), while frames stop
// for reasons that have nothing to do with the GPU: a user pause drops every
// preview frame for an unbounded time, end-of-stream and a wedged ReadSample
// end them permanently. A park during any of those was simply never noticed,
// and the bubble stayed frozen on screen.
//
// The pushed trigger arrives on the PRESENTER'S OWN THREAD, and the swap joins
// that thread — so it is marshalled to the platform thread through a poster
// that never falls back to running inline (PlatformThreadDispatcher::TryPost).
// An undeliverable notification is dropped, not run in place.
namespace clingfy::capture {

class CameraOverlayHost : public ICameraOverlayPresenter,
                          public std::enable_shared_from_this<CameraOverlayHost> {
 public:
  // Factory for the fallback (GDI) presenter, injectable for tests. Default:
  // a started CameraFloatingOverlay, or nullptr if it could not start.
  using GdiFactory =
      std::function<std::shared_ptr<ICameraOverlayPresenter>(
          const FloatingPlacement&)>;

  // Marshals the park-triggered swap off the presenter's own thread. Returns
  // false if the task could not be queued, in which case it is DROPPED — see
  // PlatformThreadDispatcher::TryPost. Injectable so tests can run the swap
  // synchronously; production must never use an inline poster, because the
  // swap Stops the presenter whose thread raised the notification.
  using TaskPoster = std::function<bool(std::function<void()>)>;

  // NOTE: instances must be owned by a shared_ptr (weak_from_this is used to
  // keep a posted swap safe across teardown). Both production and test
  // construction sites use make_shared.
  CameraOverlayHost() = default;
  explicit CameraOverlayHost(GdiFactory gdi_factory)
      : gdi_factory_(std::move(gdi_factory)) {}
  CameraOverlayHost(GdiFactory gdi_factory, TaskPoster poster)
      : gdi_factory_(std::move(gdi_factory)), poster_(std::move(poster)) {}

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
  // Same, taking the lock itself. The entry point for the park notification,
  // which arrives without a frame.
  void MaybeFallback();
  // Wire the inner presenter's park notification to MaybeFallback, marshalled
  // through poster_. Caller holds mutex_.
  void InstallParkObserverLocked();

  mutable std::mutex mutex_;
  std::shared_ptr<ICameraOverlayPresenter> inner_;
  FloatingPlacement placement_{};
  bool showing_ = false;
  bool fell_back_ = false;
  GdiFactory gdi_factory_;
  TaskPoster poster_;
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CAMERA_CAMERA_OVERLAY_HOST_H_
