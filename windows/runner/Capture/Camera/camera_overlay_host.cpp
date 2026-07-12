#include "Capture/Camera/camera_overlay_host.h"

#include <utility>

#include "Bridge/native_log_publisher.h"
#include "Capture/Camera/camera_floating_overlay.h"

namespace clingfy::capture {

namespace {

// Default fallback factory: a started opaque GDI bubble, or nullptr if it
// could not start.
std::shared_ptr<ICameraOverlayPresenter> StartGdiPresenter(
    const FloatingPlacement& placement) {
  auto gdi = std::make_shared<CameraFloatingOverlay>();
  if (gdi->Start(placement)) {
    return gdi;
  }
  gdi->Stop();
  return nullptr;
}

}  // namespace

bool CameraOverlayHost::Start(const FloatingPlacement& placement) {
  std::lock_guard<std::mutex> lock(mutex_);
  placement_ = placement;
  inner_ = StartCameraOverlayPresenter(placement);
  // If the ladder already landed on GDI (default selection, or DComp failed at
  // start), there is nothing to fall back to at runtime; mark it so.
  fell_back_ = inner_ == nullptr;
  return inner_ != nullptr;
}

void CameraOverlayHost::AdoptInnerForTest(
    std::shared_ptr<ICameraOverlayPresenter> inner,
    const FloatingPlacement& placement) {
  std::lock_guard<std::mutex> lock(mutex_);
  placement_ = placement;
  inner_ = std::move(inner);
  fell_back_ = inner_ == nullptr;
}

void CameraOverlayHost::MaybeFallbackLocked() {
  if (inner_ == nullptr || fell_back_ || !inner_->needs_fallback()) {
    return;
  }
  fell_back_ = true;  // one-shot regardless of the outcome below
  const bool was_showing = showing_;
  inner_->Stop();

  std::shared_ptr<ICameraOverlayPresenter> gdi =
      gdi_factory_ ? gdi_factory_(placement_) : StartGdiPresenter(placement_);
  // Mid-recording degradations log at WARN — release logs/Sentry must show
  // why the bubble changed (or vanished) without the verbose toggle.
  if (gdi == nullptr) {
    // Safe mode could not start either — no floating bubble (matches the
    // startup ladder's "WDA failed on both" outcome). Drop the inner presenter.
    inner_.reset();
    clingfy::bridge::NativeLogPublisher::Instance().Warn(
        "Camera",
        "DComp parked on device loss and the GDI fallback could not start — "
        "no floating bubble");
    return;
  }
  inner_ = std::move(gdi);
  clingfy::bridge::NativeLogPublisher::Instance().Warn(
      "Camera", "DComp parked on device loss — swapped to the GDI presenter");
  // Never show a bubble whose capture-exclusion failed (would burn into the
  // recording); honor the last Show/Hide intent otherwise.
  if (was_showing && inner_->wda_excluded()) {
    inner_->Show();
  }
}

void CameraOverlayHost::Show() {
  std::lock_guard<std::mutex> lock(mutex_);
  // showing_ records the user's intent (so a later swap to an excluded
  // presenter re-shows). The ACTUAL show is gated on capture-exclusion HERE,
  // atomically under the host mutex — the engine's own wda_excluded()+Show()
  // pair is two separate calls, and a mid-session swap between them could
  // otherwise substitute an unexcluded GDI presenter and burn the camera into
  // the recording (never show an unexcluded bubble).
  showing_ = true;
  if (inner_ != nullptr && inner_->wda_excluded()) {
    inner_->Show();
  }
}

void CameraOverlayHost::Hide() {
  std::lock_guard<std::mutex> lock(mutex_);
  showing_ = false;
  if (inner_ != nullptr) {
    inner_->Hide();
  }
}

void CameraOverlayHost::PublishBgra(const std::uint8_t* bgra, int width,
                                    int height) {
  std::shared_ptr<ICameraOverlayPresenter> target;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    MaybeFallbackLocked();
    target = inner_;
  }
  // Publish outside the lock: PublishBgra copies the frame and returns quickly,
  // and keeping the lock only around the swap decision minimizes contention
  // with Show/Hide on the platform thread.
  if (target != nullptr) {
    target->PublishBgra(bgra, width, height);
  }
}

void CameraOverlayHost::Stop() {
  std::shared_ptr<ICameraOverlayPresenter> inner;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    inner = std::move(inner_);
    inner_.reset();
    showing_ = false;
  }
  if (inner != nullptr) {
    inner->Stop();
  }
}

bool CameraOverlayHost::running() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return inner_ != nullptr && inner_->running();
}

bool CameraOverlayHost::wda_excluded() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return inner_ != nullptr && inner_->wda_excluded();
}

bool CameraOverlayHost::did_fall_back_for_test() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return fell_back_ && inner_ != nullptr;
}

}  // namespace clingfy::capture
