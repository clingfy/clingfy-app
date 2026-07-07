// Presenter selection (renderer redesign P2). The factory is the seam where
// P3's DirectComposition attempt (with GDI fallback) plugs in; today it must
// deterministically hand back the shipping GDI presenter — with and without
// the support kill switch — so the engine's behavior is unchanged by the
// refactor.

#include "Capture/Camera/camera_overlay_presenter.h"

#include <windows.h>

#include <gtest/gtest.h>

#include "Capture/Camera/camera_floating_overlay.h"

namespace clingfy::capture {
namespace {

TEST(CameraOverlayPresenterFactory, DefaultSelectionIsTheGdiPresenter) {
  ::SetEnvironmentVariableW(L"CLINGFY_FORCE_GDI_OVERLAY", nullptr);
  const std::shared_ptr<ICameraOverlayPresenter> p =
      CreateCameraOverlayPresenter();
  ASSERT_NE(p, nullptr);
  EXPECT_NE(dynamic_cast<CameraFloatingOverlay*>(p.get()), nullptr);
  EXPECT_FALSE(p->running());  // constructed, not started.
}

TEST(CameraOverlayPresenterFactory, KillSwitchStillYieldsTheGdiPresenter) {
  ::SetEnvironmentVariableW(L"CLINGFY_FORCE_GDI_OVERLAY", L"1");
  const std::shared_ptr<ICameraOverlayPresenter> p =
      CreateCameraOverlayPresenter();
  ::SetEnvironmentVariableW(L"CLINGFY_FORCE_GDI_OVERLAY", nullptr);
  ASSERT_NE(p, nullptr);
  EXPECT_NE(dynamic_cast<CameraFloatingOverlay*>(p.get()), nullptr);
}

// In P2 both selection paths construct the same GDI presenter, so the factory
// tests above cannot distinguish a broken kill switch — this direct test is
// what actually pins the ADR §5 escape hatch before P3 makes it load-bearing.
TEST(CameraOverlayPresenterFactory, ForceGdiOverlayReadsTheKillSwitch) {
  ::SetEnvironmentVariableW(L"CLINGFY_FORCE_GDI_OVERLAY", nullptr);
  EXPECT_FALSE(ForceGdiOverlay());

  ::SetEnvironmentVariableW(L"CLINGFY_FORCE_GDI_OVERLAY", L"1");
  EXPECT_TRUE(ForceGdiOverlay());

  // Documented contract: ANY non-empty value pins GDI — including "0".
  ::SetEnvironmentVariableW(L"CLINGFY_FORCE_GDI_OVERLAY", L"0");
  EXPECT_TRUE(ForceGdiOverlay());

  // Longer than the probe buffer still reads as set.
  ::SetEnvironmentVariableW(L"CLINGFY_FORCE_GDI_OVERLAY",
                            L"definitely-longer-than-the-probe-buffer");
  EXPECT_TRUE(ForceGdiOverlay());

  ::SetEnvironmentVariableW(L"CLINGFY_FORCE_GDI_OVERLAY", nullptr);
  EXPECT_FALSE(ForceGdiOverlay());
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
