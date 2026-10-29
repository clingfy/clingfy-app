// "Reveal area" (Overlay/area_reveal_overlay.h): where the outline goes, its
// pixels, and the show / auto-hide / clear lifecycle against the stored
// selection.

#include "Overlay/area_reveal_overlay.h"

#include <windows.h>

#include <gtest/gtest.h>

#include <chrono>
#include <cstdint>
#include <optional>
#include <vector>

#include "Capture/windows_selection_state.h"

namespace clingfy::overlay {
namespace {

using clingfy::capture::AreaRegion;
using clingfy::capture::WindowsSelectionState;

RECT Monitor(LONG left, LONG top, LONG right, LONG bottom) {
  return RECT{left, top, right, bottom};
}

// --- geometry ----------------------------------------------------------------

TEST(AreaRevealGeometryTest, A2DipLineCentredOnTheAreaEdge) {
  // Area 100,50 300x200 on a monitor at (1920,0). 100%: 2 px line, so the
  // window is the area grown by 1 px: the line is 1 px out, 1 px in.
  const AreaRevealFrame f = ComputeAreaRevealFrame(
      Monitor(1920, 0, 3840, 1080), 100, 50, 300, 200, 96);
  EXPECT_EQ(f.line_px, 2);
  EXPECT_EQ(f.window.left, 1920 + 99);
  EXPECT_EQ(f.window.top, 49);
  EXPECT_EQ(f.window.right, 1920 + 401);
  EXPECT_EQ(f.window.bottom, 251);
}

TEST(AreaRevealGeometryTest, TheLineScalesWithTheMonitor) {
  EXPECT_EQ(ComputeAreaRevealFrame(Monitor(0, 0, 3840, 2160), 0, 0, 10, 10,
                                   192)
                .line_px,
            4);
  EXPECT_EQ(ComputeAreaRevealFrame(Monitor(0, 0, 1920, 1080), 0, 0, 10, 10,
                                   144)
                .line_px,
            3);
  EXPECT_EQ(ComputeAreaRevealFrame(Monitor(0, 0, 1920, 1080), 0, 0, 10, 10,
                                   0)
                .line_px,
            2);  // unknown dpi = 100%
}

TEST(AreaRevealGeometryTest, StaysOnTheAreasMonitor) {
  // An area flush with the monitor's edges: the window does not spill onto a
  // neighbour, so the line falls just inside the area there.
  const AreaRevealFrame f = ComputeAreaRevealFrame(
      Monitor(-1920, 0, 0, 1080), 0, 0, 1920, 1080, 96);
  EXPECT_EQ(f.window.left, -1920);
  EXPECT_EQ(f.window.top, 0);
  EXPECT_EQ(f.window.right, 0);
  EXPECT_EQ(f.window.bottom, 1080);
}

TEST(AreaRevealGeometryTest, AnAreaLargerThanItsMonitorIsClampedLikeTheRecording) {
  const AreaRevealFrame f = ComputeAreaRevealFrame(
      Monitor(0, 0, 1280, 720), 1000, 600, 800, 800, 96);
  EXPECT_EQ(f.window.left, 999);
  EXPECT_EQ(f.window.top, 599);
  EXPECT_EQ(f.window.right, 1280);
  EXPECT_EQ(f.window.bottom, 720);
}

TEST(AreaRevealGeometryTest, AnAreaOffTheMonitorShowsNothing) {
  const AreaRevealFrame f = ComputeAreaRevealFrame(
      Monitor(0, 0, 1280, 720), 2000, 0, 100, 100, 96);
  EXPECT_LE(f.window.right - f.window.left, 0);
}

// --- pixels ------------------------------------------------------------------

TEST(AreaRevealRasterTest, AnOpaqueWhiteBandAlongEveryEdgeAndClearInside) {
  std::vector<std::uint32_t> px;
  RasterizeAreaRevealFrame(&px, 10, 8, 2);
  ASSERT_EQ(px.size(), 80u);
  const auto at = [&](int x, int y) { return px[y * 10 + x]; };
  for (int x = 0; x < 10; ++x) {
    EXPECT_EQ(at(x, 0), 0xFFFFFFFFu);
    EXPECT_EQ(at(x, 1), 0xFFFFFFFFu);
    EXPECT_EQ(at(x, 7), 0xFFFFFFFFu);
  }
  for (int y = 0; y < 8; ++y) {
    EXPECT_EQ(at(0, y), 0xFFFFFFFFu);
    EXPECT_EQ(at(9, y), 0xFFFFFFFFu);
  }
  for (int y = 2; y < 6; ++y) {
    for (int x = 2; x < 8; ++x) {
      EXPECT_EQ(at(x, y), 0u) << x << "," << y;
    }
  }
}

// --- lifecycle against the stored selection ----------------------------------

void Pump(int ms) {
  const auto end =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(ms);
  while (std::chrono::steady_clock::now() < end) {
    MSG msg;
    while (::PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
      ::TranslateMessage(&msg);
      ::DispatchMessageW(&msg);
    }
    ::Sleep(5);
  }
}

class AreaRevealLifecycleTest : public ::testing::Test {
 protected:
  void SetUp() override {
    // The app is PerMonitorV2 (runner.exe.manifest); the test binary is not.
    // Without this the window's coordinates are DPI-virtualized and the
    // outline lands scaled on a non-100% monitor, which the app never does.
    previous_dpi_ = ::SetThreadDpiAwarenessContext(
        DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    HideAreaReveal();
    WindowsSelectionState::Instance().SetAreaRegion(std::nullopt);
  }
  void TearDown() override {
    HideAreaReveal();
    WindowsSelectionState::Instance().SetAreaRegion(std::nullopt);
    if (previous_dpi_ != nullptr) {
      ::SetThreadDpiAwarenessContext(previous_dpi_);
    }
  }
  DPI_AWARENESS_CONTEXT previous_dpi_ = nullptr;
};

TEST_F(AreaRevealLifecycleTest, NoSelectionMeansNothingToReveal) {
  ShowAreaReveal();
  EXPECT_FALSE(IsAreaRevealShownForTesting());
}

TEST_F(AreaRevealLifecycleTest, ShowsOnThePrimaryMonitorThenHidesItself) {
  AreaRegion region;  // display_id nullopt = the primary monitor
  region.x = 10;
  region.y = 20;
  region.width = 200;
  region.height = 100;
  WindowsSelectionState::Instance().SetAreaRegion(region);

  ShowAreaReveal();
  ASSERT_TRUE(IsAreaRevealShownForTesting());
  const POINT origin{0, 0};
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  ASSERT_TRUE(::GetMonitorInfoW(
      ::MonitorFromPoint(origin, MONITOR_DEFAULTTOPRIMARY), &info));
  const RECT r = AreaRevealWindowRectForTesting();
  EXPECT_LE(r.left, info.rcMonitor.left + 10);
  EXPECT_GE(r.left, info.rcMonitor.left + 10 - 2);
  EXPECT_GE(r.right, info.rcMonitor.left + 210);

  Pump(static_cast<int>(kAreaRevealAutoHideMs) + 400);
  EXPECT_FALSE(IsAreaRevealShownForTesting()) << "did not hide after 1 s";
}

TEST_F(AreaRevealLifecycleTest, HideTakesItDownAtOnce) {
  AreaRegion region;
  region.width = 100;
  region.height = 100;
  WindowsSelectionState::Instance().SetAreaRegion(region);
  ShowAreaReveal();
  ASSERT_TRUE(IsAreaRevealShownForTesting());
  HideAreaReveal();
  EXPECT_FALSE(IsAreaRevealShownForTesting());
}

}  // namespace
}  // namespace clingfy::overlay
