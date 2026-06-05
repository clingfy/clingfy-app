#include "Capture/Export/gif_export_policy.h"

#include <gtest/gtest.h>

#include <cstdint>

namespace clingfy::capture::export_ {
namespace {

// ---- GifFrameIntervalHns ----------------------------------------------------

TEST(GifExportPolicyTest, FrameIntervalMatchesTargetFps) {
  // 10'000'000 HNS / 15 fps.
  EXPECT_EQ(GifFrameIntervalHns(), 10'000'000 / 15);
  EXPECT_GT(GifFrameIntervalHns(), 0);
}

// ---- IsGifDestination -------------------------------------------------------

TEST(GifExportPolicyTest, IsGifDestinationMatchesGifExtensionCaseInsensitively) {
  EXPECT_TRUE(IsGifDestination("clip.gif"));
  EXPECT_TRUE(IsGifDestination("C:\\Users\\me\\Videos\\My Clip.GIF"));
  EXPECT_TRUE(IsGifDestination("/tmp/out.Gif"));
  EXPECT_TRUE(IsGifDestination(".gif"));
}

TEST(GifExportPolicyTest, IsGifDestinationRejectsNonGif) {
  EXPECT_FALSE(IsGifDestination("clip.mov"));
  EXPECT_FALSE(IsGifDestination("clip.mp4"));
  EXPECT_FALSE(IsGifDestination("clip"));
  EXPECT_FALSE(IsGifDestination(""));
  EXPECT_FALSE(IsGifDestination("gif"));         // no dot
  EXPECT_FALSE(IsGifDestination("clip.gif.mov"));  // gif not the final ext
}

// ---- ShouldKeepGifFrame / AdvanceGifEmitTarget ------------------------------

TEST(GifExportPolicyTest, FirstFrameIsAlwaysKept) {
  // The start sentinel target keeps any first frame regardless of timestamp.
  EXPECT_TRUE(ShouldKeepGifFrame(0, kGifEmitTargetStart));
  EXPECT_TRUE(ShouldKeepGifFrame(123456, kGifEmitTargetStart));
}

TEST(GifExportPolicyTest, AdvanceAnchorsGridToTheKeptFrameThenStepsOneInterval) {
  const std::int64_t interval = GifFrameIntervalHns();
  // From the start sentinel, the next target snaps to one interval past frame 0.
  const std::int64_t t0 = AdvanceGifEmitTarget(kGifEmitTargetStart, 0);
  EXPECT_EQ(t0, interval);
  // A normal advance steps exactly one interval along the grid.
  EXPECT_EQ(AdvanceGifEmitTarget(t0, interval), 2 * interval);
  // A long source gap resyncs forward instead of leaving the target behind.
  const std::int64_t jump = 100 * interval;
  EXPECT_EQ(AdvanceGifEmitTarget(t0, jump), jump + interval);
}

TEST(GifExportPolicyTest, KeepsOnlyOncePerIntervalAfterTheFirst) {
  const std::int64_t target = AdvanceGifEmitTarget(kGifEmitTargetStart, 0);
  EXPECT_EQ(target, GifFrameIntervalHns());
  EXPECT_FALSE(ShouldKeepGifFrame(GifFrameIntervalHns() - 1, target));
  EXPECT_TRUE(ShouldKeepGifFrame(GifFrameIntervalHns(), target));
}

TEST(GifExportPolicyTest, Decimates30FpsToEveryOtherFrame) {
  // A 30 fps source (33'333 HNS/frame) becomes ~15 fps walking the grid gate
  // the way the pipeline does.
  const std::int64_t frame_dur = 10'000'000 / 30;
  std::int64_t target = kGifEmitTargetStart;
  int kept = 0;
  for (int i = 0; i < 8; ++i) {
    const std::int64_t ts = static_cast<std::int64_t>(i) * frame_dur;
    if (ShouldKeepGifFrame(ts, target)) {
      ++kept;
      target = AdvanceGifEmitTarget(target, ts);
    }
  }
  // 8 source frames at 30 fps -> 4 kept (frames 0,2,4,6).
  EXPECT_EQ(kept, 4);
}

TEST(GifExportPolicyTest, JitteredCleanDivisorSourceStaysNearTargetRate) {
  // Real decoder timestamps jitter around exact frame multiples. The grid-based
  // target keeps the count at ~half a 30 fps source, where a last-kept-timestamp
  // gate degraded to every third frame under the same jitter. Jitter is a fixed
  // deterministic pattern in +/-12 HNS (no RNG in tests).
  const std::int64_t frame_dur = 10'000'000 / 30;
  const std::int64_t jitter[8] = {0, 9, -7, 11, -12, 5, -3, 8};
  std::int64_t target = kGifEmitTargetStart;
  int kept = 0;
  for (int i = 0; i < 8; ++i) {
    const std::int64_t ts =
        static_cast<std::int64_t>(i) * frame_dur + jitter[i];
    if (ShouldKeepGifFrame(ts, target)) {
      ++kept;
      target = AdvanceGifEmitTarget(target, ts);
    }
  }
  // Grid-anchored: stays at ~every-other (4), not every-third (which the old
  // actual-timestamp gate would have produced for this jitter).
  EXPECT_GE(kept, 4);
  EXPECT_LE(kept, 5);
}

// ---- GifDelayCentiseconds ---------------------------------------------------

TEST(GifExportPolicyTest, DelayIsRoundedCentisecondsOfTheGap) {
  // 0.10 s gap -> 10 cs.
  EXPECT_EQ(GifDelayCentiseconds(0, 1'000'000), 10);
  // One 15 fps interval (~0.0667 s) -> round(6.67) = 7 cs.
  EXPECT_EQ(GifDelayCentiseconds(0, GifFrameIntervalHns()), 7);
  // 0.50 s gap -> 50 cs.
  EXPECT_EQ(GifDelayCentiseconds(1'000'000, 6'000'000), 50);
}

TEST(GifExportPolicyTest, DelayClampsUpToTheMinimumFloor) {
  // A tiny gap (1 ms = 0.1 cs) clamps up to the 2 cs floor most viewers honor.
  EXPECT_EQ(GifDelayCentiseconds(0, 10'000), kGifMinDelayCentiseconds);
  // A zero / negative gap also clamps to the floor (defensive).
  EXPECT_EQ(GifDelayCentiseconds(500, 500), kGifMinDelayCentiseconds);
  EXPECT_EQ(GifDelayCentiseconds(500, 100), kGifMinDelayCentiseconds);
}

TEST(GifExportPolicyTest, DelayClampsDownToThe16BitCeiling) {
  // A very long inter-frame gap (700 s -> 70'000 cs) must clamp to the 16-bit
  // GIF delay maximum (0xFFFF) rather than wrap when cast to uint16_t.
  EXPECT_EQ(GifDelayCentiseconds(0, 700LL * 10'000'000), 0xFFFF);
}

}  // namespace
}  // namespace clingfy::capture::export_
