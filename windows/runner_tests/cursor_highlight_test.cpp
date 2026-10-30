// The live cursor highlight (Overlay/cursor_highlight_model.h,
// cursor_highlight_overlay.h): the macOS show rule, the click pulse curve,
// the pixels, and the overlay's reaction to the Dart setters and the
// recording state.

#include "Overlay/cursor_highlight_model.h"
#include "Overlay/cursor_highlight_overlay.h"

#include <windows.h>

#include <gtest/gtest.h>

#include <chrono>
#include <cstdint>
#include <thread>
#include <vector>

namespace clingfy::overlay {
namespace {

// --- the show rule: macOS CursorHighlightCoordinator ----------------------

TEST(CursorHighlightShouldShowTest, LinkedShowsOnlyWhileActivelyRecording) {
  EXPECT_FALSE(CursorHighlightShouldShow(true, true, false, false));
  EXPECT_TRUE(CursorHighlightShouldShow(true, true, true, false));
  EXPECT_FALSE(CursorHighlightShouldShow(false, true, true, false));
}

TEST(CursorHighlightShouldShowTest, UnlinkedFollowsTheToggleAlone) {
  EXPECT_TRUE(CursorHighlightShouldShow(true, false, false, false));
  EXPECT_TRUE(CursorHighlightShouldShow(true, false, true, false));
  EXPECT_FALSE(CursorHighlightShouldShow(false, false, true, false));
}

TEST(CursorHighlightShouldShowTest, TheSessionSuppressionWinsEitherWay) {
  // disableCursorHighlight on the request: off for the session, paused or not.
  EXPECT_FALSE(CursorHighlightShouldShow(true, true, true, true));
  EXPECT_FALSE(CursorHighlightShouldShow(true, false, true, true));
  EXPECT_FALSE(CursorHighlightShouldShow(true, false, false, true));
}

// --- the pulse: scale 1 -> 1.35, opacity 1 -> 0, 0.35 s ease-out ----------

TEST(CursorHighlightPulseTest, NothingBeforeAClickOrAfterThePulse) {
  EXPECT_FALSE(CursorHighlightPulseAt(-1.0).active);
  EXPECT_FALSE(CursorHighlightPulseAt(kCursorHighlightPulseSeconds).active);
  EXPECT_FALSE(CursorHighlightPulseAt(10.0).active);
}

TEST(CursorHighlightPulseTest, StartsFullAndGrowsWhileFading) {
  const CursorHighlightPulse start = CursorHighlightPulseAt(0.0);
  EXPECT_TRUE(start.active);
  EXPECT_NEAR(start.scale, 1.0, 1e-6);
  EXPECT_NEAR(start.opacity, 1.0, 1e-6);

  const CursorHighlightPulse end = CursorHighlightPulseAt(0.3499);
  EXPECT_NEAR(end.scale, kCursorHighlightPulseMaxScale, 1e-3);
  EXPECT_NEAR(end.opacity, 0.0, 1e-3);

  double last_scale = 1.0;
  for (double t = 0.0; t < kCursorHighlightPulseSeconds; t += 0.01) {
    const CursorHighlightPulse p = CursorHighlightPulseAt(t);
    EXPECT_GE(p.scale, last_scale - 1e-12) << t;
    EXPECT_NEAR(p.opacity, 1.0 - (p.scale - 1.0) / 0.35, 1e-9) << t;
    last_scale = p.scale;
  }
}

TEST(CursorHighlightPulseTest, IsEaseOutNotLinear) {
  // easeOut (0,0)-(0.58,1) is ahead of linear at the midpoint: y(0.5) ~ 0.69.
  const CursorHighlightPulse mid =
      CursorHighlightPulseAt(kCursorHighlightPulseSeconds / 2);
  const double eased = (mid.scale - 1.0) / 0.35;
  EXPECT_GT(eased, 0.6);
  EXPECT_LT(eased, 0.75);
}

// --- size and pixels ---------------------------------------------------------

TEST(CursorHighlightRasterTest, WindowIs120DipAtEachScale) {
  EXPECT_EQ(CursorHighlightWindowPx(96), 120);
  EXPECT_EQ(CursorHighlightWindowPx(144), 180);
  EXPECT_EQ(CursorHighlightWindowPx(192), 240);
  EXPECT_EQ(CursorHighlightWindowPx(0), 120);  // unknown dpi = 100%
}

std::uint32_t At(const std::vector<std::uint32_t>& px, int size, int x,
                 int y) {
  return px[static_cast<std::size_t>(y) * size + x];
}
int Alpha(std::uint32_t p) { return static_cast<int>(p >> 24); }

TEST(CursorHighlightRasterTest, AQuarterYellowDiscOf60DipAndClearElsewhere) {
  std::vector<std::uint32_t> px;
  RasterizeCursorHighlight(&px, 120, 1.0, CursorHighlightPulse{});
  ASSERT_EQ(px.size(), 120u * 120u);
  // Centre: 25% systemYellow, premultiplied (255,204,0) * 0.25.
  const std::uint32_t c = At(px, 120, 60, 60);
  EXPECT_EQ(Alpha(c), 64);
  EXPECT_EQ((c >> 16) & 0xFF, 64u);
  EXPECT_EQ((c >> 8) & 0xFF, 51u);
  EXPECT_EQ(c & 0xFF, 0u);
  // Inside the 30 px radius, and clear well outside it.
  EXPECT_EQ(Alpha(At(px, 120, 60 + 27, 60)), 64);
  EXPECT_EQ(At(px, 120, 60 + 34, 60), 0u);
  EXPECT_EQ(At(px, 120, 0, 0), 0u);
  // Premultiplied: no channel exceeds alpha anywhere.
  for (const std::uint32_t p : px) {
    ASSERT_LE((p >> 16) & 0xFF, p >> 24);
    ASSERT_LE((p >> 8) & 0xFF, p >> 24);
  }
}

TEST(CursorHighlightRasterTest, TheDiscScalesWithTheMonitor) {
  std::vector<std::uint32_t> px;
  RasterizeCursorHighlight(&px, 240, 2.0, CursorHighlightPulse{});
  EXPECT_EQ(Alpha(At(px, 240, 120 + 55, 120)), 64);  // 60 px radius at 200%
  EXPECT_EQ(At(px, 240, 120 + 66, 120), 0u);
}

TEST(CursorHighlightRasterTest, AClickDrawsAnOpaqueOutlineOutsideTheDisc) {
  CursorHighlightPulse pulse;
  pulse.active = true;
  pulse.scale = 1.0;
  pulse.opacity = 1.0;
  std::vector<std::uint32_t> px;
  RasterizeCursorHighlight(&px, 120, 1.0, pulse);
  // The outline is centred on r = 32 and 3 px wide.
  EXPECT_EQ(Alpha(At(px, 120, 60 + 32, 60)), 255);
  EXPECT_EQ(Alpha(At(px, 120, 60, 60)), 64);  // the disc is unchanged inside
  EXPECT_EQ(At(px, 120, 60 + 36, 60), 0u);

  // Grown and half faded: the outline has moved out to r = 32 * 1.3.
  pulse.scale = 1.3;
  pulse.opacity = 0.5;
  RasterizeCursorHighlight(&px, 120, 1.0, pulse);
  EXPECT_NEAR(Alpha(At(px, 120, 60 + 42, 60)), 128, 2);
  EXPECT_EQ(At(px, 120, 60 + 32, 60), 0u);  // between the disc and the ring
}

TEST(CursorHighlightRasterTest, TheLargestPulseStaysInsideTheWindow) {
  CursorHighlightPulse pulse;
  pulse.active = true;
  pulse.scale = kCursorHighlightPulseMaxScale;
  pulse.opacity = 1.0;
  std::vector<std::uint32_t> px;
  RasterizeCursorHighlight(&px, 120, 1.0, pulse);
  for (int i = 0; i < 120; ++i) {
    EXPECT_EQ(At(px, 120, i, 0), 0u);
    EXPECT_EQ(At(px, 120, 0, i), 0u);
    EXPECT_EQ(At(px, 120, i, 119), 0u);
    EXPECT_EQ(At(px, 120, 119, i), 0u);
  }
}

// --- the overlay: Dart setters + recording state ----------------------------

bool WaitFor(bool (*check)(), int timeout_ms = 2000) {
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
  while (std::chrono::steady_clock::now() < deadline) {
    if (check()) return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  return check();
}

class CursorHighlightOverlayTest : public ::testing::Test {
 protected:
  void SetUp() override { Reset(); }
  void TearDown() override { Reset(); }
  static void Reset() {
    auto& o = CursorHighlightOverlay::Instance();
    o.SetEnabled(false);
    o.SetLinkedToRecording(true);
    o.ClearRecordingState();
    WaitFor([] { return !CursorHighlightOverlay::Instance().IsShownForTesting(); });
  }
};

TEST_F(CursorHighlightOverlayTest, LinkedAppearsWithTheRecordingAndGoesWithIt) {
  auto& o = CursorHighlightOverlay::Instance();
  o.SetEnabled(true);
  EXPECT_FALSE(o.WantsShowForTesting());  // linked, not recording

  o.SetRecordingState(true, false);
  EXPECT_TRUE(o.WantsShowForTesting());
  EXPECT_TRUE(WaitFor([] {
    return CursorHighlightOverlay::Instance().IsShownForTesting();
  })) << "the window did not come up";

  o.SetRecordingState(false, false);  // paused
  EXPECT_FALSE(o.WantsShowForTesting());
  EXPECT_TRUE(WaitFor([] {
    return !CursorHighlightOverlay::Instance().IsShownForTesting();
  }));

  o.SetRecordingState(true, false);  // resumed
  EXPECT_TRUE(WaitFor([] {
    return CursorHighlightOverlay::Instance().IsShownForTesting();
  }));

  o.ClearRecordingState();  // stopped
  EXPECT_TRUE(WaitFor([] {
    return !CursorHighlightOverlay::Instance().IsShownForTesting();
  }));
}

TEST_F(CursorHighlightOverlayTest, ARequestThatSuppressesItKeepsItOff) {
  auto& o = CursorHighlightOverlay::Instance();
  o.SetEnabled(true);
  o.SetLinkedToRecording(false);
  EXPECT_TRUE(o.WantsShowForTesting());  // unlinked: shown before recording

  o.SetRecordingState(true, /*session_disabled=*/true);
  EXPECT_FALSE(o.WantsShowForTesting());
  o.SetRecordingState(false, true);  // paused, still suppressed
  EXPECT_FALSE(o.WantsShowForTesting());
  o.ClearRecordingState();  // the session ended: suppression cleared
  EXPECT_TRUE(o.WantsShowForTesting());
}

TEST_F(CursorHighlightOverlayTest, DisabledNeverShows) {
  auto& o = CursorHighlightOverlay::Instance();
  o.SetLinkedToRecording(false);
  o.SetRecordingState(true, false);
  EXPECT_FALSE(o.WantsShowForTesting());
  std::this_thread::sleep_for(std::chrono::milliseconds(50));
  EXPECT_FALSE(o.IsShownForTesting());
}

}  // namespace
}  // namespace clingfy::overlay
