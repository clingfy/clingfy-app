#include "Capture/capture_frame_pacer.h"

#include <gtest/gtest.h>

#include <cstdint>
#include <vector>

namespace clingfy::capture {
namespace {

constexpr std::int64_t kHnsPerSecond = 10'000'000;

// Feed `seconds` of frames at `source_hz` (optionally jittered) and count the
// keeps.
int KeptOver(int fps, double source_hz, double seconds,
             std::int64_t jitter_hns = 0) {
  CaptureFramePacer pacer(fps);
  const int frames = static_cast<int>(source_hz * seconds);
  int kept = 0;
  for (int i = 0; i < frames; ++i) {
    std::int64_t ts = static_cast<std::int64_t>(i * kHnsPerSecond / source_hz);
    if (jitter_hns != 0) {
      ts += (i % 2 == 0) ? jitter_hns : -jitter_hns;  // alternating early/late
    }
    if (pacer.Keep(ts)) {
      ++kept;
    }
  }
  return kept;
}

TEST(CaptureFramePacerTest, SixtyHertzPacedToThirtyKeepsEveryOtherFrame) {
  CaptureFramePacer pacer(30);
  std::vector<bool> keeps;
  for (int i = 0; i < 8; ++i) {
    keeps.push_back(pacer.Keep(i * kHnsPerSecond / 60));
  }
  EXPECT_EQ(keeps, (std::vector<bool>{true, false, true, false, true, false,
                                      true, false}));
}

TEST(CaptureFramePacerTest, TheRateNeverExceedsTheSetting) {
  // 10 s from common display rates. The cap holds within one frame.
  for (const double hz : {60.0, 75.0, 120.0, 144.0, 165.0, 240.0}) {
    EXPECT_LE(KeptOver(30, hz, 10.0), 301) << hz << " Hz -> 30";
    EXPECT_GE(KeptOver(30, hz, 10.0), 295) << hz << " Hz -> 30";
    EXPECT_LE(KeptOver(60, hz, 10.0), 601) << hz << " Hz -> 60";
    EXPECT_GE(KeptOver(60, hz, 10.0), 590) << hz << " Hz -> 60";
  }
}

TEST(CaptureFramePacerTest, ASourceAtOrBelowTheSettingIsUntouched) {
  EXPECT_EQ(KeptOver(60, 60.0, 10.0), 600);
  EXPECT_EQ(KeptOver(60, 30.0, 10.0), 300);
  EXPECT_EQ(KeptOver(30, 30.0, 10.0), 300);
  EXPECT_EQ(KeptOver(30, 24.0, 10.0), 240);
}

TEST(CaptureFramePacerTest, TimestampJitterDoesNotDropFramesAtTheSameRate) {
  // A 60 Hz compositor whose timestamps wobble by +/-1.5 ms, paced to 60:
  // every frame is on time and must be kept.
  EXPECT_EQ(KeptOver(60, 60.0, 10.0, /*jitter_hns=*/15'000), 600);
  // Paced to 30, the jitter must not turn into extra or missing frames.
  EXPECT_EQ(KeptOver(30, 60.0, 10.0, /*jitter_hns=*/15'000), 300);
}

TEST(CaptureFramePacerTest, AGapDoesNotAdmitACatchUpBurst) {
  // A static screen: WGC sends nothing for 2 s, then resumes at 144 Hz. The
  // grid must snap to the new frames, not fill the gap with a burst.
  CaptureFramePacer pacer(30);
  EXPECT_TRUE(pacer.Keep(0));
  int kept = 0;
  const std::int64_t resume = 2 * kHnsPerSecond;
  for (int i = 0; i < 144; ++i) {  // one second at 144 Hz
    if (pacer.Keep(resume + i * kHnsPerSecond / 144)) {
      ++kept;
    }
  }
  EXPECT_LE(kept, 31);
  EXPECT_GE(kept, 29);
}

TEST(CaptureFramePacerTest, TheFirstFrameIsAlwaysKept) {
  CaptureFramePacer pacer(30);
  EXPECT_TRUE(pacer.Keep(123'456'789));
}

TEST(CaptureFramePacerTest, ANonPositiveRateKeepsEverything) {
  CaptureFramePacer off(0);
  CaptureFramePacer negative(-5);
  for (int i = 0; i < 10; ++i) {
    EXPECT_TRUE(off.Keep(i));
    EXPECT_TRUE(negative.Keep(i));
  }
  EXPECT_EQ(off.interval_hns(), 0);
}

}  // namespace
}  // namespace clingfy::capture
