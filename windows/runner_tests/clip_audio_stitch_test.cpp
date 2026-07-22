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

// ---- PlanReorderAudioSlots (Step 3b-2b): the reorder/silence-fill plan -------

// Build the ms-based AudioSlots the reorder planner consumes.
std::vector<clip_planner::AudioSlot> Slots(
    std::initializer_list<std::pair<std::int64_t, std::int64_t>> pairs,
    std::int64_t audio_duration_ms) {
  return clip_planner::AudioSlots(Ranges(pairs), audio_duration_ms);
}

TEST(ReorderAudioSlotsTest, EditedStartsAreMonotonicDespiteReversedSource) {
  // Timeline B(6000,8000) THEN A(0,2000): the source jumps BACKWARD (6000 -> 0)
  // but the edited placement tiles forward 0 -> 2000, so a reader that reads B's
  // window first still produces monotonically-increasing edited timestamps.
  const auto plan = PlanReorderAudioSlots(
      Slots({{6000, 8000}, {0, 2000}}, /*audio_duration_ms=*/10000), kMsRate);
  ASSERT_EQ(plan.size(), 2u);
  EXPECT_EQ(plan[0].source_in_frame, 6000);
  EXPECT_EQ(plan[0].edited_start_frame, 0);
  EXPECT_EQ(plan[0].copy_frame_count, 2000);
  EXPECT_EQ(plan[0].silence_frame_count, 0);
  EXPECT_EQ(plan[1].source_in_frame, 0);
  EXPECT_EQ(plan[1].edited_start_frame, 2000);
  EXPECT_EQ(plan[1].copy_frame_count, 2000);
  EXPECT_EQ(plan[1].silence_frame_count, 0);
  EXPECT_LT(plan[0].edited_start_frame, plan[1].edited_start_frame);
  EXPECT_GT(plan[0].source_in_frame, plan[1].source_in_frame);
}

TEST(ReorderAudioSlotsTest, ShortAudioClampsCopyAndSilenceFillsTheSlotTail) {
  // Audio track ends at 4000 ms. B(3000,6000)'s copy clamps to [3000,4000) and
  // the remaining 2000 ms of the slot is silence (the captured audio ran out).
  const auto plan = PlanReorderAudioSlots(
      Slots({{0, 2000}, {3000, 6000}}, /*audio_duration_ms=*/4000), kMsRate);
  ASSERT_EQ(plan.size(), 2u);
  EXPECT_EQ(plan[1].source_in_frame, 3000);
  EXPECT_EQ(plan[1].edited_start_frame, 2000);
  EXPECT_EQ(plan[1].copy_frame_count, 1000);    // min(6000,4000) - 3000
  EXPECT_EQ(plan[1].silence_frame_count, 2000);  // 3000 - 1000
}

TEST(ReorderAudioSlotsTest, MidTimelineSilenceDoesNotPullLaterAudioEarlier) {
  // §5.2 regression (only reachable under reorder): the FIRST edited slot is
  // clamped short (its source runs past the audio end), yet the SECOND slot must
  // stay at edited 2000, NOT slide back to 1000. Advancing by the copied length
  // instead of the full duration would desync every later slot.
  const auto plan = PlanReorderAudioSlots(
      Slots({{5000, 7000}, {0, 2000}}, /*audio_duration_ms=*/6000), kMsRate);
  ASSERT_EQ(plan.size(), 2u);
  EXPECT_EQ(plan[0].copy_frame_count, 1000);     // min(7000,6000) - 5000
  EXPECT_EQ(plan[0].silence_frame_count, 1000);  // full 2000 - copied 1000
  EXPECT_EQ(plan[1].edited_start_frame, 2000)
      << "the clamped slot keeps its full duration; the next slot must not move";
}

TEST(ReorderAudioSlotsTest, SlotsTileContiguouslyAtRealSampleRate) {
  // At 48 kHz each slot's end frame must be exactly the next slot's start frame
  // (boundaries derived from cumulative-ms->frame, not summed frame counts).
  const auto plan = PlanReorderAudioSlots(
      Slots({{0, 100}, {500, 600}}, /*audio_duration_ms=*/1000),
      /*sample_rate_hz=*/48000);
  ASSERT_EQ(plan.size(), 2u);
  EXPECT_EQ(plan[0].edited_start_frame, 0);
  EXPECT_EQ(plan[0].copy_frame_count, 4800);  // 100 ms * 48
  EXPECT_EQ(plan[0].silence_frame_count, 0);
  const std::int64_t slot0_end = plan[0].edited_start_frame +
                                 plan[0].copy_frame_count +
                                 plan[0].silence_frame_count;
  EXPECT_EQ(slot0_end, plan[1].edited_start_frame);  // 4800, no gap/overlap
  EXPECT_EQ(plan[1].source_in_frame, 24000);         // 500 ms * 48
}

TEST(ReorderAudioSlotsTest, EmptyOrNonPositiveRateProducesNoSlots) {
  EXPECT_TRUE(PlanReorderAudioSlots({}, kMsRate).empty());
  EXPECT_TRUE(
      PlanReorderAudioSlots(Slots({{0, 1000}}, 1000), /*sample_rate_hz=*/0)
          .empty());
}

}  // namespace
}  // namespace clingfy::capture::export_::clip_audio
