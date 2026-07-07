// Presenter selection (renderer redesign P2). The factory is the seam where
// P3's DirectComposition attempt (with GDI fallback) plugs in; today it must
// deterministically hand back the shipping GDI presenter — with and without
// the support kill switch — so the engine's behavior is unchanged by the
// refactor.

#include "Capture/Camera/camera_overlay_presenter.h"

#include <windows.h>

#include <gtest/gtest.h>

#include "Capture/Camera/camera_dcomp_overlay.h"
#include "Capture/Camera/camera_floating_overlay.h"

namespace clingfy::capture {
namespace {

// Every selection test starts from a clean slate: a developer dogfooding the
// DComp opt-in (CLINGFY_OVERLAY_DCOMP exported in their shell) must still get
// green factory tests when running the standard ctest validation.
void ClearSelectionEnv() {
  ::SetEnvironmentVariableW(L"CLINGFY_FORCE_GDI_OVERLAY", nullptr);
  ::SetEnvironmentVariableW(L"CLINGFY_OVERLAY_DCOMP", nullptr);
  ::SetEnvironmentVariableW(L"CLINGFY_TEST_DCOMP_WDA_FAIL", nullptr);
}

TEST(CameraOverlayPresenterFactory, DefaultSelectionIsTheGdiPresenter) {
  ClearSelectionEnv();
  const std::shared_ptr<ICameraOverlayPresenter> p =
      CreateCameraOverlayPresenter();
  ASSERT_NE(p, nullptr);
  EXPECT_NE(dynamic_cast<CameraFloatingOverlay*>(p.get()), nullptr);
  EXPECT_FALSE(p->running());  // constructed, not started.
}

TEST(CameraOverlayPresenterFactory, KillSwitchStillYieldsTheGdiPresenter) {
  ClearSelectionEnv();
  ::SetEnvironmentVariableW(L"CLINGFY_FORCE_GDI_OVERLAY", L"1");
  const std::shared_ptr<ICameraOverlayPresenter> p =
      CreateCameraOverlayPresenter();
  ::SetEnvironmentVariableW(L"CLINGFY_FORCE_GDI_OVERLAY", nullptr);
  ASSERT_NE(p, nullptr);
  EXPECT_NE(dynamic_cast<CameraFloatingOverlay*>(p.get()), nullptr);
}

TEST(CameraOverlayPresenterFactory, DcompOptInSelectsTheDcompPresenter) {
  ClearSelectionEnv();
  ::SetEnvironmentVariableW(L"CLINGFY_OVERLAY_DCOMP", L"1");
  const std::shared_ptr<ICameraOverlayPresenter> p =
      CreateCameraOverlayPresenter();
  ClearSelectionEnv();
  ASSERT_NE(p, nullptr);
  EXPECT_NE(dynamic_cast<CameraDcompOverlay*>(p.get()), nullptr);
  EXPECT_FALSE(p->running());  // constructed, not started — no GPU touched.
}

TEST(CameraOverlayPresenterFactory, KillSwitchBeatsDcompOptIn) {
  // The one guarantee that makes shipping the opt-in safe: the support kill
  // switch wins over the DComp opt-in, whatever else is set.
  ClearSelectionEnv();
  ::SetEnvironmentVariableW(L"CLINGFY_FORCE_GDI_OVERLAY", L"1");
  ::SetEnvironmentVariableW(L"CLINGFY_OVERLAY_DCOMP", L"1");
  const std::shared_ptr<ICameraOverlayPresenter> p =
      CreateCameraOverlayPresenter();
  ClearSelectionEnv();
  ASSERT_NE(p, nullptr);
  EXPECT_NE(dynamic_cast<CameraFloatingOverlay*>(p.get()), nullptr);
}

// The safety-critical rung of the ladder (ADR §5): a DComp presenter that
// starts but has no capture exclusion must be stopped and replaced by the GDI
// fallback — never returned, or the bubble could burn into the recording.
// Driven by the CLINGFY_TEST_DCOMP_WDA_FAIL fault-injection hook instead of
// the afflicted-hardware Win11 defect. Real windows + real GPU stack; skips
// only when this session cannot create any overlay at all.
TEST(CameraOverlayPresenterFactory, LadderFallsBackToGdiWhenDcompLosesExclusion) {
  ClearSelectionEnv();
  ::SetEnvironmentVariableW(L"CLINGFY_OVERLAY_DCOMP", L"1");
  ::SetEnvironmentVariableW(L"CLINGFY_TEST_DCOMP_WDA_FAIL", L"1");
  FloatingPlacement place;
  place.x = 100;
  place.y = 100;
  place.width = 400;
  place.height = 225;
  const std::shared_ptr<ICameraOverlayPresenter> p =
      StartCameraOverlayPresenter(place);
  ClearSelectionEnv();
  if (p == nullptr) {
    GTEST_SKIP() << "no overlay window could be created in this session";
  }
  EXPECT_NE(dynamic_cast<CameraFloatingOverlay*>(p.get()), nullptr)
      << "the ladder returned the DComp presenter without capture exclusion";
  EXPECT_TRUE(p->running());
  p->Stop();
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
  ClearSelectionEnv();
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
