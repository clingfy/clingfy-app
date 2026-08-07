#include "Capture/Camera/camera_overlay_host.h"

#include <utility>

#include "Bridge/native_log_publisher.h"
#include "Bridge/platform_thread_dispatcher.h"
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

void CameraOverlayHost::InstallParkObserverLocked() {
  if (inner_ == nullptr) {
    return;
  }
  // weak, so a notification that lands after the engine dropped the host (any
  // of the three teardown sites) resolves to nothing instead of a dangling
  // call.
  std::weak_ptr<CameraOverlayHost> weak = weak_from_this();
  TaskPoster poster = poster_;
  inner_->SetParkObserver([weak, poster]() {
    auto swap = [weak]() {
      if (auto self = weak.lock()) {
        self->MaybeFallback();
      }
    };
    if (poster) {
      poster(std::move(swap));
      return;
    }
    // Default: the platform thread, via the NON-inline post. If it cannot be
    // queued the notification is dropped rather than run here — this callback
    // is on the presenter's own thread and the swap would join it. Dropping is
    // survivable: the presenter has already hidden its dead window, and the
    // frame-driven poll in PublishBgra still swaps if frames ever resume.
    if (!clingfy::bridge::PlatformThreadDispatcher::Instance().TryPost(
            std::move(swap))) {
      clingfy::bridge::NativeLogPublisher::Instance().Warn(
          "Camera",
          "camera overlay parked but the GDI swap could not be posted to the "
          "platform thread — the bubble stays hidden until frames resume");
    }
  });
}

bool CameraOverlayHost::Start(const FloatingPlacement& placement) {
  std::lock_guard<std::mutex> lock(mutex_);
  placement_ = placement;
  inner_ = StartCameraOverlayPresenter(placement);
  // If the ladder already landed on GDI (default selection, or DComp failed at
  // start), there is nothing to fall back to at runtime; mark it so.
  fell_back_ = inner_ == nullptr;
  InstallParkObserverLocked();
  // StartCameraOverlayPresenter has already spun up the presenter's thread and
  // armed its tick, so it can park before the observer exists. Installing does
  // not fire (that would re-enter us under mutex_), so this poll is what covers
  // the already-parked window.
  MaybeFallbackLocked();
  return inner_ != nullptr;
}

void CameraOverlayHost::AdoptInnerForTest(
    std::shared_ptr<ICameraOverlayPresenter> inner,
    const FloatingPlacement& placement) {
  std::lock_guard<std::mutex> lock(mutex_);
  placement_ = placement;
  inner_ = std::move(inner);
  fell_back_ = inner_ == nullptr;
  // Must install here too: the poc tests adopt an already-started,
  // fault-injected presenter, so without this they would exercise only the
  // frame-driven path and the new one would ship untested.
  InstallParkObserverLocked();
  // The adopted presenter may have parked before we ever saw it. SetParkObserver
  // does not fire on install (it would re-enter us under mutex_), so the
  // already-parked case is this poll's job.
  MaybeFallbackLocked();
}

void CameraOverlayHost::MaybeFallback() {
  std::lock_guard<std::mutex> lock(mutex_);
  MaybeFallbackLocked();
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
    // Drop the notification path before joining the presenter's thread. This
    // cannot unpost a swap already in flight — weak_from_this() is what makes
    // that safe — but it stops a park raised during teardown from queueing a
    // new one.
    inner->SetParkObserver(nullptr);
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
