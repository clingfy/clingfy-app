// Headless tests for the sample-accurate clip audio stitch (editing Step 3b-1).
// These pin the seam behavior that replaces 3a's packet-granular keep/drop:
// a packet straddling a cut is trimmed to the exact frame, and a packet that
// spans a cut contributes to both adjacent kept ranges. Pure integer-frame
// math — no Media Foundation, no device (docs/windows-port-editing-features.md
// §5.2/§6). Most cases use sample_rate = 1000 so a frame index equals a
// millisecond and the expected offsets read directly.

#include "Capture/Export/clip_audio_stitch.h"

#include <gtest/gtest.h>

#include <cstdint>
#include <initializer_list>
#include <utility>
#include <vector>

#include "Capture/Export/clip_playback_planner.h"

namespace clingfy::capture::export_::clip_audio {
namespace {

using clip_planner::ClipKeptRange;

std::vector<ClipKeptRange> Ranges(
    std::initializer_list<std::pair<std::int64_t, std::int64_t>> pairs) {
  std::vector<ClipKeptRange> out;
  out.reserve(pairs.size());
  for (const auto& [in_ms, out_ms] : pairs) {
    out.push_back(ClipKeptRange{in_ms, out_ms});
  }
  return out;
}

// 1 frame == 1 ms at this rate, so expectations read as milliseconds.
constexpr std::int64_t kMsRate = 1000;

TEST(ClipAudioStitchTest, NoRangesPassesPacketThroughOneToOne) {
  const auto spans = PlanKeptAudioCopies(/*start=*/5000, /*frames=*/100, {},
                                         kMsRate);
  ASSERT_EQ(spans.size(), 1u);
  EXPECT_EQ(spans[0].edited_start_frame, 5000);
  EXPECT_EQ(spans[0].src_offset_frames, 0u);
  EXPECT_EQ(spans[0].frame_count, 100u);
}

TEST(ClipAudioStitchTest, PacketFullyInsideRangeReStampsToEditedBase) {
  // r0 source [1000,4000) -> edited [0,3000).
  const auto r = Ranges({{1000, 4000}, {6000, 10000}});
  const auto spans = PlanKeptAudioCopies(/*start=*/1500, /*frames=*/500, r,
                                         kMsRate);
  ASSERT_EQ(spans.size(), 1u);
  EXPECT_EQ(spans[0].edited_start_frame, 500);  // 0 + (1500 - 1000)
  EXPECT_EQ(spans[0].src_offset_frames, 0u);
  EXPECT_EQ(spans[0].frame_count, 500u);
}

TEST(ClipAudioStitchTest, PacketStraddlingCutTrimsTailAtBoundary) {
  // The 3a leak fix: a packet that runs past a cut end keeps only the frames
  // before the boundary, not the whole packet.
  const auto r = Ranges({{1000, 4000}, {6000, 10000}});
  const auto spans = PlanKeptAudioCopies(/*start=*/3800, /*frames=*/400, r,
                                         kMsRate);
  ASSERT_EQ(spans.size(), 1u);
  EXPECT_EQ(spans[0].edited_start_frame, 2800);  // 0 + (3800 - 1000)
  EXPECT_EQ(spans[0].src_offset_frames, 0u);
  EXPECT_EQ(spans[0].frame_count, 200u);  // trimmed from 400 at source 4000
}

TEST(ClipAudioStitchTest, PacketStartingInGapTrimsHeadToRangeStart) {
  // The other half of the leak fix: leading audio of the range after a cut is
  // no longer dropped just because the packet started in the gap.
  const auto r = Ranges({{1000, 4000}, {6000, 10000}});
  const auto spans = PlanKeptAudioCopies(/*start=*/5800, /*frames=*/400, r,
                                         kMsRate);
  ASSERT_EQ(spans.size(), 1u);
  EXPECT_EQ(spans[0].edited_start_frame, 3000);  // base1, at the range start
  EXPECT_EQ(spans[0].src_offset_frames, 200u);   // first 200 frames were in gap
  EXPECT_EQ(spans[0].frame_count, 200u);
}

TEST(ClipAudioStitchTest, PacketSpanningACutSplitsIntoBothRanges) {
  const auto r = Ranges({{1000, 4000}, {6000, 10000}});
  // 3900..6100 crosses the tail of r0, the gap, and the head of r1.
  const auto spans = PlanKeptAudioCopies(/*start=*/3900, /*frames=*/2200, r,
                                         kMsRate);
  ASSERT_EQ(spans.size(), 2u);
  // r0 tail.
  EXPECT_EQ(spans[0].edited_start_frame, 2900);  // 0 + (3900 - 1000)
  EXPECT_EQ(spans[0].src_offset_frames, 0u);
  EXPECT_EQ(spans[0].frame_count, 100u);  // 3900..4000
  // r1 head — edited timeline stays monotonically increasing.
  EXPECT_EQ(spans[1].edited_start_frame, 3000);  // base1
  EXPECT_EQ(spans[1].src_offset_frames, 2100u);  // 6000 - 3900
  EXPECT_EQ(spans[1].frame_count, 100u);  // 6000..6100
  EXPECT_LT(spans[0].edited_start_frame, spans[1].edited_start_frame);
}

TEST(ClipAudioStitchTest, PacketFullyInsideACutProducesNoSpans) {
  const auto r = Ranges({{1000, 4000}, {6000, 10000}});
  const auto spans = PlanKeptAudioCopies(/*start=*/4500, /*frames=*/500, r,
                                         kMsRate);
  EXPECT_TRUE(spans.empty());
}

TEST(ClipAudioStitchTest, EditedBaseTilesCumulativeDurations) {
  // Durations 1000, 500, 1000 -> edited bases 0, 1000, 1500.
  const auto r = Ranges({{2000, 3000}, {5000, 5500}, {8000, 9000}});
  const auto spans = PlanKeptAudioCopies(/*start=*/2000, /*frames=*/7000, r,
                                         kMsRate);
  ASSERT_EQ(spans.size(), 3u);
  EXPECT_EQ(spans[0].edited_start_frame, 0);
  EXPECT_EQ(spans[0].frame_count, 1000u);
  EXPECT_EQ(spans[1].edited_start_frame, 1000);
  EXPECT_EQ(spans[1].frame_count, 500u);
  EXPECT_EQ(spans[2].edited_start_frame, 1500);
  EXPECT_EQ(spans[2].frame_count, 1000u);
}

TEST(ClipAudioStitchTest, ZeroFramesOrNonPositiveRateProducesNoSpans) {
  const auto r = Ranges({{0, 4000}});
  EXPECT_TRUE(PlanKeptAudioCopies(0, 0, r, kMsRate).empty());
  EXPECT_TRUE(PlanKeptAudioCopies(0, 100, r, 0).empty());
  EXPECT_TRUE(PlanKeptAudioCopies(0, 100, r, -48000).empty());
}

TEST(ClipAudioStitchTest, RealSampleRateConvertsAndTruncatesMsToFrames) {
  // At 48 kHz a 100 ms range is 4800 frames; a 5000-frame packet is trimmed to
  // the range end.
  const auto r = Ranges({{0, 100}});
  const auto spans = PlanKeptAudioCopies(/*start=*/0, /*frames=*/5000, r,
                                         /*sample_rate_hz=*/48000);
  ASSERT_EQ(spans.size(), 1u);
  EXPECT_EQ(spans[0].edited_start_frame, 0);
  EXPECT_EQ(spans[0].src_offset_frames, 0u);
  EXPECT_EQ(spans[0].frame_count, 4800u);  // 100 ms * 48 frames/ms
}

}  // namespace
}  // namespace clingfy::capture::export_::clip_audio
