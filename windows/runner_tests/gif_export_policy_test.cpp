#include "Capture/Export/gif_export_policy.h"

#include <gtest/gtest.h>

#include <cstdint>
#include <cstdlib>
#include <cmath>
#include <numeric>
#include <vector>

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

// ---- GifDelayAccumulator ----------------------------------------------------
// Mirrors GifExportPolicyTests.swift (testDelayAccumulator*).

TEST(GifExportPolicyTest, DelayAccumulatorKillsUniform15FpsDrift) {
  // A uniform 15 fps stream: each gap is one frame interval. The stateless
  // round stamps every frame at 7 cs -> 6 frames = 42 cs (+5% slow). The
  // accumulator carries the residual so delays alternate, summing to 40 cs
  // (== the true elapsed centiseconds) instead.
  const std::int64_t interval = GifFrameIntervalHns();
  GifDelayAccumulator acc;
  std::vector<std::uint16_t> delays;
  for (int i = 0; i < 6; ++i) {
    delays.push_back(acc.Next(interval));
  }
  EXPECT_EQ(delays, (std::vector<std::uint16_t>{7, 6, 7, 7, 6, 7}));
  const int total = std::accumulate(delays.begin(), delays.end(), 0);
  EXPECT_EQ(total, 40);  // true elapsed: 6 * 666'666 HNS = 40.0 cs
  EXPECT_LT(total, 6 * kGifDefaultDelayCentiseconds);  // the naive 42
}

TEST(GifExportPolicyTest, DelayAccumulatorTracksWallClockOverLongRuns) {
  // The brief's acceptance rule: N frames at 15 fps sum to round(N * 100 / 15)
  // cs within 1 cs, for every N — the error never accumulates. A 10 s GIF
  // (150 frames) stamps 1000 cs, where per-gap rounding stamped 1050.
  const std::int64_t interval = GifFrameIntervalHns();
  GifDelayAccumulator acc;
  std::int64_t total = 0;
  for (int n = 1; n <= 9000; ++n) {  // ten minutes
    total += acc.Next(interval);
    const std::int64_t expected = std::llround(n * 100.0 / 15.0);
    ASSERT_LE(std::llabs(total - expected), 1) << "after " << n << " frames";
  }
  GifDelayAccumulator ten_seconds;
  std::int64_t ten_second_total = 0;
  for (int n = 0; n < 150; ++n) {
    ten_second_total += ten_seconds.Next(interval);
  }
  EXPECT_EQ(ten_second_total, 1000);
}

TEST(GifExportPolicyTest, DelayAccumulatorMixesSevensAndSixes) {
  // At 15 fps every delay is 6 or 7, and two thirds of them are 7.
  GifDelayAccumulator acc;
  int sixes = 0;
  int sevens = 0;
  for (int i = 0; i < 300; ++i) {
    const std::uint16_t d = acc.Next(GifFrameIntervalHns());
    ASSERT_TRUE(d == 6 || d == 7) << "delay " << d << " at frame " << i;
    (d == 6 ? sixes : sevens) += 1;
  }
  EXPECT_EQ(sixes, 100);
  EXPECT_EQ(sevens, 200);
}

TEST(GifExportPolicyTest, DelayAccumulatorClampsTinyAndZeroGapsToTheFloor) {
  GifDelayAccumulator acc;
  // 0.1 cs gap -> floor.
  EXPECT_EQ(acc.Next(10'000), kGifMinDelayCentiseconds);
  // A follow-up zero gap still floors (and doesn't run the clock backwards).
  EXPECT_EQ(acc.Next(0), kGifMinDelayCentiseconds);
  EXPECT_EQ(acc.Next(-5'000'000), kGifMinDelayCentiseconds);
}

TEST(GifExportPolicyTest, DelayAccumulatorClampsDownToThe16BitCeiling) {
  GifDelayAccumulator acc;
  EXPECT_EQ(acc.Next(700LL * 10'000'000), 0xFFFF);
}

TEST(GifExportPolicyTest, DelayAccumulatorFloorActsAsARateLimiter) {
  // Floored delays advance the stamped clock past the true one, so the frames
  // after them give the time back instead of the GIF running long forever.
  GifDelayAccumulator acc;
  EXPECT_EQ(acc.Next(10'000), 2);  // true 0.1 cs, stamped 2
  EXPECT_EQ(acc.Next(10'000), 2);  // true 0.2 cs, stamped 4
  // A 10 cs gap: true 10.2 -> 10, stamped 4 -> this frame gets 6, not 10.
  EXPECT_EQ(acc.Next(1'000'000), 6);
}

// ---- Size presets and the long-edge cap -------------------------------------
// Mirrors GifExportPolicyTests.swift (renderSize / maxLongEdge /
// intermediateRenderSize).

bool SameSize(SizeF a, SizeF b) {
  return a.width == b.width && a.height == b.height;
}

TEST(GifExportPolicyTest, SizePresetCapsMatchTheContract) {
  // Mirror of the Flutter GifSizePreset.longEdgePx values — keep in sync.
  EXPECT_EQ(kGifSmallMaxLongEdge, 480.0);
  EXPECT_EQ(kGifMediumMaxLongEdge, 720.0);
  EXPECT_EQ(kGifLargeMaxLongEdge, 1080.0);
  // Large is the default so an omitted preset renders at the old 1080 cap.
  EXPECT_EQ(kGifDefaultMaxLongEdge, kGifLargeMaxLongEdge);
  // fps is not a lever: one target rate for every preset.
  EXPECT_EQ(kGifTargetFps, 15u);
}

TEST(GifExportPolicyTest, MaxLongEdgeResolvesEachSizePreset) {
  EXPECT_EQ(GifMaxLongEdgeForSizePreset("small"), 480.0);
  EXPECT_EQ(GifMaxLongEdgeForSizePreset("medium"), 720.0);
  EXPECT_EQ(GifMaxLongEdgeForSizePreset("large"), 1080.0);
}

TEST(GifExportPolicyTest, MaxLongEdgeIsCaseInsensitiveAndTrimmed) {
  EXPECT_EQ(GifMaxLongEdgeForSizePreset("SMALL"), 480.0);
  EXPECT_EQ(GifMaxLongEdgeForSizePreset("  Medium "), 720.0);
  EXPECT_EQ(GifMaxLongEdgeForSizePreset("Large\n"), 1080.0);
  EXPECT_EQ(GifMaxLongEdgeForSizePreset("\tsmall\r\n"), 480.0);
}

TEST(GifExportPolicyTest, MaxLongEdgeFallsBackToLargeForUnknownOrEmpty) {
  EXPECT_EQ(GifMaxLongEdgeForSizePreset(""), 1080.0);
  EXPECT_EQ(GifMaxLongEdgeForSizePreset("   "), 1080.0);
  EXPECT_EQ(GifMaxLongEdgeForSizePreset("gigantic"), 1080.0);
  EXPECT_EQ(GifMaxLongEdgeForSizePreset("sma ll"), 1080.0);
}

TEST(GifExportPolicyTest, RenderSizeLeavesWithinCapCanvasUnchanged) {
  EXPECT_TRUE(SameSize(GifRenderSize({960, 540}), {960, 540}));
  // Exactly at the cap is not downscaled (strict greater-than).
  EXPECT_TRUE(SameSize(GifRenderSize({1080, 1080}), {1080, 1080}));
}

TEST(GifExportPolicyTest, RenderSizeDownscales4KToTheCapPreservingAspect) {
  // 2160 * (1080 / 3840) = 607.5 -> 608 (half away from zero, as Swift).
  EXPECT_TRUE(SameSize(GifRenderSize({3840, 2160}), {1080, 608}));
  EXPECT_TRUE(SameSize(GifRenderSize({1080, 1920}), {608, 1080}));
}

TEST(GifExportPolicyTest, RenderSizeHonorsCustomMaxLongEdge) {
  EXPECT_TRUE(SameSize(GifRenderSize({1920, 1080}, 480), {480, 270}));
}

TEST(GifExportPolicyTest, RenderSizeGuardsDegenerateMaxLongEdge) {
  EXPECT_TRUE(SameSize(GifRenderSize({1920, 1080}, 0), {1920, 1080}));
  EXPECT_TRUE(SameSize(GifRenderSize({1920, 1080}, -5), {1920, 1080}));
}

TEST(GifExportPolicyTest, RenderSizeNeverCollapsesAThinEdgeToZero) {
  // A 4000x1 strip at 480: 1 * 0.12 rounds to 0, floored to 1.
  EXPECT_TRUE(SameSize(GifRenderSize({4000, 1}, 480), {480, 1}));
}

TEST(GifExportPolicyTest, EachSizePresetDownscalesA1080LandscapeCanvas) {
  const SizeF canvas{1920, 1080};
  EXPECT_TRUE(SameSize(
      GifRenderSize(canvas, GifMaxLongEdgeForSizePreset("small")), {480, 270}));
  EXPECT_TRUE(SameSize(
      GifRenderSize(canvas, GifMaxLongEdgeForSizePreset("medium")), {720, 405}));
  EXPECT_TRUE(SameSize(
      GifRenderSize(canvas, GifMaxLongEdgeForSizePreset("large")), {1080, 608}));
}

TEST(GifExportPolicyTest, IntermediateRenderSizeCapsAndEvensTheCanvas) {
  PixelSize s = GifIntermediateRenderSize({1920, 1080});
  EXPECT_EQ(s.width, 1080u);
  EXPECT_EQ(s.height, 608u);
  // 3840x2160 lands on the same frame — the resolution preset is NOT what a
  // GIF encodes at, which is why Flutter has to ask.
  s = GifIntermediateRenderSize({3840, 2160});
  EXPECT_EQ(s.width, 1080u);
  EXPECT_EQ(s.height, 608u);
}

TEST(GifExportPolicyTest, IntermediateRenderSizeRoundsOddDimensionsUpToEven) {
  // 1920x1080 at Medium: 720 x 405 -> 405 is odd -> 406.
  const PixelSize s = GifIntermediateRenderSize(
      {1920, 1080}, GifMaxLongEdgeForSizePreset("medium"));
  EXPECT_EQ(s.width, 720u);
  EXPECT_EQ(s.height, 406u);
}

TEST(GifExportPolicyTest, IntermediateRenderSizeLeavesAFittingEvenCanvasAlone) {
  const PixelSize s = GifIntermediateRenderSize({960, 540});
  EXPECT_EQ(s.width, 960u);
  EXPECT_EQ(s.height, 540u);
}

TEST(GifExportPolicyTest, IntermediateRenderSizeNeverGoesBelowTwo) {
  const PixelSize s = GifIntermediateRenderSize({4000, 1}, 480);
  EXPECT_EQ(s.width, 480u);
  EXPECT_EQ(s.height, 2u);
}

TEST(GifExportPolicyTest, IntermediateRenderSizeShrinksTheFrameCaptionsAreDrawnFor) {
  // At Small a 1080p canvas becomes a 480-wide frame, so a bitmap laid out for
  // 1920 would cover 4x the width it was meant to. Anything that reports the
  // uncapped canvas here brings that back.
  const PixelSize s = GifIntermediateRenderSize(
      {1920, 1080}, GifMaxLongEdgeForSizePreset("small"));
  EXPECT_EQ(s.width, 480u);
  EXPECT_EQ(s.height, 270u);
}

// ---- Length cap -------------------------------------------------------------
// Mirrors GifExportPolicyTests.swift (the "Length cap" group).

using clip_planner::ClipKeptRange;

ClipKeptRange Range(std::int64_t in_ms, std::int64_t out_ms) {
  ClipKeptRange r;
  r.source_in_ms = in_ms;
  r.source_out_ms = out_ms;
  return r;
}

TEST(GifExportPolicyTest, TheCapIsSixtySecondsOfExportedTime) {
  // Dart's kGifMaxExportDurationMs and Swift's maxExportedDurationMs are the
  // same number; keep all three equal.
  EXPECT_EQ(kGifMaxExportedDurationMs, 60'000);
  EXPECT_EQ(kGifDurationCapSlackMs, 100);
}

TEST(GifExportPolicyTest, NoClipsMeansTheWholeRecording) {
  EXPECT_EQ(GifExportedDurationMs({}, 90'000), 90'000);
  // A nonsense negative duration never reports a negative length.
  EXPECT_EQ(GifExportedDurationMs({}, -5), 0);
}

TEST(GifExportPolicyTest, ClipsSumTheirKeptTimeInAnyOrder) {
  const ClipKeptRange a = Range(0, 10'000);
  const ClipKeptRange b = Range(30'000, 45'000);
  EXPECT_EQ(GifExportedDurationMs({a, b}, 90'000), 25'000);
  EXPECT_EQ(GifExportedDurationMs({b, a}, 90'000), 25'000);
}

TEST(GifExportPolicyTest, ARangePastTheRecordingIsClamped) {
  // A stale range past the end of the recording counts only what exists.
  EXPECT_EQ(GifExportedDurationMs({Range(50'000, 200'000)}, 70'000), 20'000);
  // Entirely past the end, or inverted, or before zero: nothing / the overlap.
  EXPECT_EQ(GifExportedDurationMs({Range(80'000, 90'000)}, 70'000), 0);
  EXPECT_EQ(GifExportedDurationMs({Range(10'000, 5'000)}, 70'000), 0);
  EXPECT_EQ(GifExportedDurationMs({Range(-4'000, 6'000)}, 70'000), 6'000);
}

TEST(GifExportPolicyTest, TheBoundaryAndTheSlack) {
  // Exactly the cap exports, and the slack means the backstop never refuses
  // what the dialog allowed. Past the slack, it refuses.
  EXPECT_FALSE(GifExceedsDurationCap(60'000));
  EXPECT_FALSE(GifExceedsDurationCap(60'000 + kGifDurationCapSlackMs));
  EXPECT_TRUE(GifExceedsDurationCap(60'001 + kGifDurationCapSlackMs));
  EXPECT_FALSE(GifExceedsDurationCap(0));
}

}  // namespace
}  // namespace clingfy::capture::export_
