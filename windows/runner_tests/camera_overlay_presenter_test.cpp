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

// Initial bubble placement geometry (renderer P4c-c4). The engine feeds this
// the work area of the RECORDED monitor (display/area resolve it; window mode
// now derives it from the captured window via MonitorFromWindow), and the
// placement's coordinates decide which monitor the presenter's window — and
// therefore the bubble — lands on.
TEST(ComputeInitialFloatingPlacement, BottomRightInsetSixteenByNine) {
  // 1080p at the origin, no taskbar inset.
  const FloatingPlacement p =
      ComputeInitialFloatingPlacement(0, 0, 1920, 1080);
  EXPECT_EQ(p.width, 1920 * 22 / 100);        // 422
  EXPECT_EQ(p.height, p.width * 9 / 16);      // 237
  const int margin = 1920 * 3 / 100;          // 57
  EXPECT_EQ(p.x, 1920 - p.width - margin);
  EXPECT_EQ(p.y, 1080 - p.height - margin);
  EXPECT_TRUE(p.rounded);
}

TEST(ComputeInitialFloatingPlacement, LandsOnTheGivenMonitorOriginRight) {
  // A secondary monitor to the right (origin 1920,0), 2560x1440. EXACT x/y so
  // dropping the work_left offset (x would be 1921, which coincidentally still
  // clears >= 1920) is caught — that offset is the whole retarget mechanism.
  const FloatingPlacement p =
      ComputeInitialFloatingPlacement(1920, 0, 1920 + 2560, 1440);
  const int width = 2560 * 22 / 100;         // 563
  const int margin = 2560 * 3 / 100;         // 76
  EXPECT_EQ(p.width, width);
  EXPECT_EQ(p.x, 1920 + (2560 - width - margin));   // 3841, pins work_left
  EXPECT_EQ(p.y, 1440 - p.height - margin);          // 1048
}

TEST(ComputeInitialFloatingPlacement, HonorsNonZeroWorkTop) {
  // A monitor stacked BELOW the primary (work area top = 1080): the y-origin
  // offset must be applied, or the bubble lands on the primary vertically and
  // silently defeats the retarget. EXACT y pins the work_top term (all other
  // cases use work_top = 0).
  const FloatingPlacement p =
      ComputeInitialFloatingPlacement(0, 1080, 1920, 2160);
  const int width = 1920 * 22 / 100;         // 422
  const int margin = 1920 * 3 / 100;         // 57
  EXPECT_EQ(p.x, 1920 - width - margin);              // 1441
  EXPECT_EQ(p.y, 1080 + (1080 - p.height - margin));  // 1866, pins work_top
  EXPECT_GE(p.y, 1080);                                // on the lower monitor
}

TEST(ComputeInitialFloatingPlacement, ClampsToMinimumWidthOnTinyWorkArea) {
  const FloatingPlacement p = ComputeInitialFloatingPlacement(0, 0, 300, 200);
  EXPECT_EQ(p.width, 160);              // max(160, 300*22/100=66)
  EXPECT_EQ(p.height, 160 * 9 / 16);   // 90
  EXPECT_GE(p.x, 0);
  EXPECT_GE(p.y, 0);
}

TEST(ComputeInitialFloatingPlacement, HonorsNegativeOriginWorkArea) {
  // Secondary monitor left of the primary: negative coordinates.
  const FloatingPlacement p =
      ComputeInitialFloatingPlacement(-1920, 0, 0, 1080);
  EXPECT_GE(p.x, -1920);
  EXPECT_LT(p.x + p.width, 0);  // stays on the left-hand monitor
}

}  // namespace
}  // namespace clingfy::capture
