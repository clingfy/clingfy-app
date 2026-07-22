#include "Capture/Export/reorder_audio_pump.h"

#include <gtest/gtest.h>

#include <cstdint>
#include <vector>

#include "Capture/Export/clip_audio_stitch.h"
#include "Capture/Export/clip_playback_planner.h"

// Step 4-7a: the scrub/prime cursor for the edited-preview audio pump.
//
// PrimeReorderCursor is the pure decision behind
// ReorderAudioPump::PrimeAtEditedFrame — the preview seeks, so its pump must
// re-prime mid-timeline (the export's cursor is forward-only and never
// re-primes; its behavior is pinned end-to-end by
// ExportPipelineTest.ReorderExportStitchesAudioInEditedOrder and must stay
// byte-identical through the 4-7a sink-seam refactor).
//
// The MF-bound halves (Create / the seeked decode) stay covered by the
// export's device tests; everything here is headless.

namespace clingfy::capture::export_::clip_audio {
namespace {

// A three-slot plan at 48 kHz with distinct shapes:
//   slot 0: edited [0, 48000)      copy 48000, silence 0      (full second)
//   slot 1: edited [48000, 96000)  copy 24000, silence 24000  (half silent)
//   slot 2: edited [96000, 144000) copy 0,     silence 48000  (fully silent)
std::vector<ReorderAudioSlot> ThreeSlotPlan() {
  return {
      ReorderAudioSlot{/*source_in_frame=*/240000, /*edited_start_frame=*/0,
                       /*copy_frame_count=*/48000, /*silence_frame_count=*/0},
      ReorderAudioSlot{/*source_in_frame=*/0, /*edited_start_frame=*/48000,
                       /*copy_frame_count=*/24000,
                       /*silence_frame_count=*/24000},
      ReorderAudioSlot{/*source_in_frame=*/480000, /*edited_start_frame=*/96000,
                       /*copy_frame_count=*/0, /*silence_frame_count=*/48000},
  };
}

TEST(PrimeReorderCursorTest, TimelineStartIsSlotZeroFrameZero) {
  const auto plan = ThreeSlotPlan();
  EXPECT_EQ(PrimeReorderCursor(plan, 0), (PumpCursor{0, 0}));
}

TEST(PrimeReorderCursorTest, NegativeTargetClampsToStart) {
  const auto plan = ThreeSlotPlan();
  EXPECT_EQ(PrimeReorderCursor(plan, -4800), (PumpCursor{0, 0}));
}

TEST(PrimeReorderCursorTest, MidSlotCopyRegion) {
  const auto plan = ThreeSlotPlan();
  // 12345 frames into slot 0's copy window.
  EXPECT_EQ(PrimeReorderCursor(plan, 12345), (PumpCursor{0, 12345}));
}

TEST(PrimeReorderCursorTest, ExactSlotBoundaryLandsOnNextSlot) {
  const auto plan = ThreeSlotPlan();
  // Frame 48000 is slot 1's first frame, not slot 0's past-the-end.
  EXPECT_EQ(PrimeReorderCursor(plan, 48000), (PumpCursor{1, 0}));
}

TEST(PrimeReorderCursorTest, MidSlotSilenceRegion) {
  const auto plan = ThreeSlotPlan();
  // 30000 frames into slot 1 = past its 24000-frame copy, inside silence.
  EXPECT_EQ(PrimeReorderCursor(plan, 48000 + 30000), (PumpCursor{1, 30000}));
}

TEST(PrimeReorderCursorTest, FullySilentSlot) {
  const auto plan = ThreeSlotPlan();
  EXPECT_EQ(PrimeReorderCursor(plan, 96000 + 7), (PumpCursor{2, 7}));
}

TEST(PrimeReorderCursorTest, AtOrPastPlanEndIsDone) {
  const auto plan = ThreeSlotPlan();
  // The plan's end frame (144000) and anything beyond read as "done":
  // slot_index == plan.size().
  EXPECT_EQ(PrimeReorderCursor(plan, 144000), (PumpCursor{3, 0}));
  EXPECT_EQ(PrimeReorderCursor(plan, 1'000'000), (PumpCursor{3, 0}));
}

TEST(PrimeReorderCursorTest, EmptyPlanIsDoneAtAnyTarget) {
  const std::vector<ReorderAudioSlot> empty;
  // slot_index 0 == plan.size() == 0 — the pump's done() predicate.
  EXPECT_EQ(PrimeReorderCursor(empty, 0), (PumpCursor{0, 0}));
  EXPECT_EQ(PrimeReorderCursor(empty, 5000), (PumpCursor{0, 0}));
}

TEST(PrimeReorderCursorTest, RoundTripsThroughPlanReorderAudioSlots) {
  // Cursor priming must agree with the real plan builder's tiling: prime at
  // every slot's first edited frame and get exactly {i, 0} back.
  std::vector<clip_planner::ClipKeptRange> ranges;
  ranges.push_back(clip_planner::ClipKeptRange{/*source_in_ms=*/6000,
                                               /*source_out_ms=*/8000});
  ranges.push_back(clip_planner::ClipKeptRange{/*source_in_ms=*/0,
                                               /*source_out_ms=*/2000});
  ranges.push_back(clip_planner::ClipKeptRange{/*source_in_ms=*/3000,
                                               /*source_out_ms=*/3500});
  const auto slots =
      clip_planner::AudioSlots(ranges, /*audio_duration_ms=*/7000);
  const auto plan = PlanReorderAudioSlots(slots, /*sample_rate_hz=*/48000);
  ASSERT_EQ(plan.size(), 3u);
  for (std::size_t i = 0; i < plan.size(); ++i) {
    EXPECT_EQ(PrimeReorderCursor(plan, plan[i].edited_start_frame),
              (PumpCursor{i, 0}))
        << "slot " << i;
  }
}

}  // namespace
}  // namespace clingfy::capture::export_::clip_audio
