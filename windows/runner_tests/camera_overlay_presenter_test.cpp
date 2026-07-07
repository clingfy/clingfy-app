// Presenter selection (renderer redesign P2). The factory is the seam where
// P3's DirectComposition attempt (with GDI fallback) plugs in; today it must
// deterministically hand back the shipping GDI presenter — with and without
// the support kill switch — so the engine's behavior is unchanged by the
// refactor.

#include "Capture/Camera/camera_overlay_presenter.h"

#include <cstdlib>

#include <gtest/gtest.h>

#include "Capture/Camera/camera_floating_overlay.h"

namespace clingfy::capture {
namespace {

TEST(CameraOverlayPresenterFactory, DefaultSelectionIsTheGdiPresenter) {
  ::_putenv_s("CLINGFY_FORCE_GDI_OVERLAY", "");
  const std::shared_ptr<ICameraOverlayPresenter> p =
      CreateCameraOverlayPresenter();
  ASSERT_NE(p, nullptr);
  EXPECT_NE(dynamic_cast<CameraFloatingOverlay*>(p.get()), nullptr);
  EXPECT_FALSE(p->running());  // constructed, not started.
}

TEST(CameraOverlayPresenterFactory, KillSwitchStillYieldsTheGdiPresenter) {
  ::_putenv_s("CLINGFY_FORCE_GDI_OVERLAY", "1");
  const std::shared_ptr<ICameraOverlayPresenter> p =
      CreateCameraOverlayPresenter();
  ::_putenv_s("CLINGFY_FORCE_GDI_OVERLAY", "");
  ASSERT_NE(p, nullptr);
  EXPECT_NE(dynamic_cast<CameraFloatingOverlay*>(p.get()), nullptr);
}

TEST(CameraOverlayPresenterFactory, LifecycleIsSafeWithoutStart) {
  const std::shared_ptr<ICameraOverlayPresenter> p =
      CreateCameraOverlayPresenter();
  ASSERT_NE(p, nullptr);
  // The engine calls these unconditionally on teardown paths; they must be
  // no-ops on a presenter that never started.
  const std::uint8_t px[4] = {0, 0, 0, 255};
  p->PublishBgra(px, 1, 1);
  p->Hide();
  p->Stop();
  EXPECT_FALSE(p->running());
  EXPECT_FALSE(p->wda_excluded());
}

}  // namespace
}  // namespace clingfy::capture
