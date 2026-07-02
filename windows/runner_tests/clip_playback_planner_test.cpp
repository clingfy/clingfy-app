// C++ port of the macOS ClipPlaybackPlannerTests (macos/RunnerTests/
// RunnerTests.swift). Same fixtures, same expectations, test-for-test — the
// planner is the timeline↔source map the whole clips port hangs off, so the
// two platforms must agree on every edge (docs/windows-port-editing-features.md
// §4). If a behavior changes here, it changes in the Swift suite in the same
// change, or not at all.

#include "Capture/Export/clip_playback_planner.h"

#include <gtest/gtest.h>

#include <cstdint>
#include <initializer_list>
#include <optional>
#include <utility>
#include <vector>

namespace clingfy::capture::export_::clip_planner {
namespace {

std::vector<ClipKeptRange> Ranges(
    std::initializer_list<std::pair<std::int64_t, std::int64_t>> pairs) {
  std::vector<ClipKeptRange> out;
  out.reserve(pairs.size());
  for (const auto& [in_ms, out_ms] : pairs) {
    out.push_back(ClipKeptRange{in_ms, out_ms});
  }
  return out;
}

TEST(ClipPlaybackPlannerTest, IsPassthroughForEmptyOrWholeAsset) {
  EXPECT_TRUE(IsPassthrough({}, 10000));
  EXPECT_TRUE(IsPassthrough(Ranges({{0, 10000}}), 10000));
  EXPECT_FALSE(IsPassthrough(Ranges({{0, 4000}, {6000, 10000}}), 10000));
  EXPECT_FALSE(IsPassthrough(Ranges({{2000, 10000}}), 10000));
}

TEST(ClipPlaybackPlannerTest, DecideProceedsInsideActiveRange) {
  const auto r = Ranges({{0, 4000}, {6000, 10000}});
  EXPECT_EQ(Decide(2000, 0, r), PlaybackDecision::Proceed());
}

TEST(ClipPlaybackPlannerTest, DecideAdvancesAtCutBoundary) {
  const auto r = Ranges({{0, 4000}, {6000, 10000}});
  // Reaching the end of range 0 jumps to the start of range 1 (skips
  // 4000-6000).
  EXPECT_EQ(Decide(4000, 0, r), PlaybackDecision::Advance(1, 6000));
}

TEST(ClipPlaybackPlannerTest, DecideEndsAfterLastRange) {
  const auto r = Ranges({{0, 4000}, {6000, 10000}});
  EXPECT_EQ(Decide(10000, 1, r), PlaybackDecision::End());
}

TEST(ClipPlaybackPlannerTest, DecideEpsilonTriggersJumpEarly) {
  const auto r = Ranges({{0, 4000}, {6000, 10000}});
  // 3990 is within a 17ms epsilon of the 4000 cut, so it advances early.
  EXPECT_EQ(Decide(3990, 0, r, 17), PlaybackDecision::Advance(1, 6000));
}

TEST(ClipPlaybackPlannerTest, ActiveIndexResolution) {
  const auto r = Ranges({{0, 4000}, {6000, 10000}});
  EXPECT_EQ(ActiveIndexForSourceMs(2000, r), 0);
  EXPECT_EQ(ActiveIndexForSourceMs(7000, r), 1);
  // In the cut gap (4000-6000) -> the next range that starts after.
  EXPECT_EQ(ActiveIndexForSourceMs(5000, r), 1);
  // Past everything -> last.
  EXPECT_EQ(ActiveIndexForSourceMs(99999, r), 1);
}

TEST(ClipPlaybackPlannerTest, EditedDurationSumsKeptRanges) {
  const auto r = Ranges({{0, 4000}, {6000, 10000}});
  EXPECT_EQ(EditedDurationMs(r), 8000);
}

TEST(ClipPlaybackPlannerTest, EditedMsMapsSourceToTimeline) {
  const auto r = Ranges({{0, 4000}, {6000, 10000}});
  // In range 0: identity.
  EXPECT_EQ(EditedMsForSourceMs(2000, 0, r), 2000);
  // In range 1 at source 7000: 4000 (range 0) + (7000-6000) = 5000.
  EXPECT_EQ(EditedMsForSourceMs(7000, 1, r), 5000);
}

TEST(ClipPlaybackPlannerTest, EditedMsHandlesArrangeReorder) {
  // Timeline order B then A; source order A before B.
  const auto r = Ranges({{6000, 8000}, {0, 2000}});
  // Active range 1 (source 0-2000) plays second; source 1000 -> edited 3000.
  EXPECT_EQ(EditedMsForSourceMs(1000, 1, r), 3000);
}

TEST(ClipPlaybackPlannerTest, SourceMsInvertsEditedMs) {
  const auto r = Ranges({{0, 4000}, {6000, 10000}});
  // Before the cut: identity.
  EXPECT_EQ(SourceMsForEditedMs(2000, r), 2000);
  // After the cut: edited 5000 -> 4000 (range 0) + 1000 into range 1 =
  // source 7000.
  EXPECT_EQ(SourceMsForEditedMs(5000, r), 7000);
  // The cut boundary maps to the start of range 1 (skips the removed gap).
  EXPECT_EQ(SourceMsForEditedMs(4000, r), 6000);
  // Past the edited end parks on the last kept frame.
  EXPECT_EQ(SourceMsForEditedMs(99999, r), 10000);
}

// EditedMsForKeptSourceMs drives "cut at the writer": kept -> edited
// position, a source moment in a cut gap -> nullopt (drop the frame).
TEST(ClipPlaybackPlannerTest, EditedMsForKeptSourceMsKeepsAndCompacts) {
  const auto r = Ranges({{0, 4000}, {6000, 10000}});
  // Inside range 0: identity.
  EXPECT_EQ(EditedMsForKeptSourceMs(0, r), std::optional<std::int64_t>(0));
  EXPECT_EQ(EditedMsForKeptSourceMs(3999, r),
            std::optional<std::int64_t>(3999));
  // Inside range 1: compacted by the removed 4000-6000 gap.
  EXPECT_EQ(EditedMsForKeptSourceMs(6000, r),
            std::optional<std::int64_t>(4000));
  EXPECT_EQ(EditedMsForKeptSourceMs(7000, r),
            std::optional<std::int64_t>(5000));
}

TEST(ClipPlaybackPlannerTest, EditedMsForKeptSourceMsDropsCutGapAndBoundary) {
  const auto r = Ranges({{0, 4000}, {6000, 10000}});
  // Squarely in the removed gap -> dropped.
  EXPECT_EQ(EditedMsForKeptSourceMs(5000, r), std::nullopt);
  // The exclusive end of a kept range is itself a cut -> dropped (the next
  // kept frame re-enters at the following range's start).
  EXPECT_EQ(EditedMsForKeptSourceMs(4000, r), std::nullopt);
  // Past the very end -> dropped.
  EXPECT_EQ(EditedMsForKeptSourceMs(10000, r), std::nullopt);
}

TEST(ClipPlaybackPlannerTest, EditedMsForKeptSourceMsPassthroughKeepsEverything) {
  // Empty ranges == no cuts: every source moment maps to itself.
  EXPECT_EQ(EditedMsForKeptSourceMs(1234, {}),
            std::optional<std::int64_t>(1234));
}

TEST(ClipPlaybackPlannerTest, IsSourceMonotonicResolution) {
  EXPECT_TRUE(IsSourceMonotonic({}));
  EXPECT_TRUE(IsSourceMonotonic(Ranges({{0, 4000}})));
  // Split / cut / trim keep timeline order == source order.
  EXPECT_TRUE(IsSourceMonotonic(Ranges({{0, 4000}, {6000, 10000}})));
  // Reordered (arrange) clips run source-backwards in places.
  EXPECT_FALSE(IsSourceMonotonic(Ranges({{6000, 8000}, {0, 2000}})));
}

TEST(ClipPlaybackPlannerTest, ActiveIndexForEditedMsResolution) {
  const auto r = Ranges({{0, 4000}, {6000, 10000}});
  EXPECT_EQ(ActiveIndexForEditedMs(2000, r), 0);
  EXPECT_EQ(ActiveIndexForEditedMs(5000, r), 1);
  // The cut boundary belongs to the second range.
  EXPECT_EQ(ActiveIndexForEditedMs(4000, r), 1);
}

TEST(ClipPlaybackPlannerTest, SeekBackBeforeCutResolvesEditedPositionNotCut) {
  // Regression: after playing past the cut (active index 1), seeking back to
  // an edited position before the cut must re-resolve the active range so
  // the emitted edited position equals the target — not clamp to the cut
  // point.
  const auto r = Ranges({{0, 4000}, {6000, 10000}});
  const std::int64_t edited_target = 2000;
  const std::int64_t src = SourceMsForEditedMs(edited_target, r);
  const int idx = ActiveIndexForEditedMs(edited_target, r);
  EXPECT_EQ(src, 2000);
  EXPECT_EQ(idx, 0);
  EXPECT_EQ(EditedMsForSourceMs(src, idx, r), edited_target)
      << "edited->source->edited must round-trip, not stick at the cut";

  // The stale-index bug: with the OLD active index (1), the same source maps
  // to the cut point (4000) instead of 2000 — the symptom we fixed.
  EXPECT_EQ(EditedMsForSourceMs(src, 1, r), 4000);
}

TEST(ClipPlaybackPlannerTest, EditedSourceRoundTripAcrossCut) {
  const auto r = Ranges({{0, 4000}, {6000, 10000}});
  for (const std::int64_t edited : {0, 1500, 3999, 4000, 4001, 6000, 8000}) {
    const std::int64_t src = SourceMsForEditedMs(edited, r);
    const int idx = ActiveIndexForEditedMs(edited, r);
    EXPECT_EQ(EditedMsForSourceMs(src, idx, r), edited)
        << "round-trip failed at edited " << edited;
  }
}

TEST(ClipPlaybackPlannerTest, CoalesceMergesSourceContiguousRanges) {
  // A split with no deletion: two source-adjacent ranges collapse into one.
  EXPECT_EQ(Coalesce(Ranges({{0, 8400}, {8400, 12000}})),
            Ranges({{0, 12000}}));
  // ...which then reads as a passthrough (no removed footage).
  EXPECT_TRUE(
      IsPassthrough(Coalesce(Ranges({{0, 8400}, {8400, 12000}})), 12000));
}

TEST(ClipPlaybackPlannerTest, CoalesceLeavesRealGapsAndReorderIntact) {
  // A real delete leaves a gap — not merged.
  EXPECT_EQ(Coalesce(Ranges({{0, 4000}, {6000, 10000}})),
            Ranges({{0, 4000}, {6000, 10000}}));
  // Reordered ranges are not source-adjacent — left intact.
  EXPECT_EQ(Coalesce(Ranges({{6000, 8000}, {0, 2000}})),
            Ranges({{6000, 8000}, {0, 2000}}));
}

// The export reorder path (PR-3c5) reads each kept range's source window in
// TIMELINE order and re-stamps its frames onto `base + offset`, where `base`
// is the sum of the earlier ranges' durations. This must tile
// [0, editedDuration) with strictly increasing, gapless edited starts
// regardless of source order — otherwise the writer would emit a
// non-monotonic (rejected) output PTS.
TEST(ClipPlaybackPlannerTest, ReorderRestampTilesEditedTimelineMonotonically) {
  const auto r = Ranges({{6000, 8000}, {0, 2000}, {10000, 11000}});  // reordered
  EXPECT_FALSE(IsSourceMonotonic(r));
  std::int64_t base = 0;
  for (std::size_t i = 0; i < r.size(); ++i) {
    // Each range's edited start abuts the previous range's edited end (no
    // gap, no overlap) and equals the planner's source->edited map at this
    // index.
    EXPECT_EQ(
        EditedMsForSourceMs(r[i].source_in_ms, static_cast<int>(i), r), base)
        << "range " << i << " edited start";
    base += r[i].DurationMs();
  }
  EXPECT_EQ(base, EditedDurationMs(r));
}

TEST(ClipPlaybackPlannerTest, EditedSourceRoundTripAcrossReorder) {
  // Timeline order B(6000-8000) then A(0-2000): the inverse map must follow
  // the reordered timeline, not source order.
  const auto r = Ranges({{6000, 8000}, {0, 2000}});
  EXPECT_EQ(SourceMsForEditedMs(0, r), 6000);
  EXPECT_EQ(SourceMsForEditedMs(1999, r), 7999);
  EXPECT_EQ(SourceMsForEditedMs(2000, r), 0);
  EXPECT_EQ(SourceMsForEditedMs(3500, r), 1500);
}

// The kept-range audio composition must advance by each range's FULL
// duration (matching the video re-stamp's editedBase), copying only the
// audio that exists and leaving the shortfall silent — otherwise a
// clamped/absent range sitting mid-timeline under reorder pulls every later
// range's audio earlier (§5.2).
TEST(ClipPlaybackPlannerTest, AudioSlotsAlignReorderedRangesToFullDurations) {
  // Reordered ranges against a short 4000ms audio track (mic stopped before
  // the screen recording ended, then the tail clip dragged earlier).
  const auto r = Ranges({{6000, 10000}, {0, 3000}, {3000, 6000}});
  const auto slots = AudioSlots(r, 4000);
  const std::vector<AudioSlot> expected = {
      // Source 6000-10000 is entirely past the 4000ms audio -> fully silent,
      // but still occupies its full 4000ms slot.
      AudioSlot{6000, 0, 0, 4000},
      // Source 0-3000 is fully available; slot starts at the cumulative full
      // duration (4000), not at where the copied audio happened to end.
      AudioSlot{0, 4000, 3000, 3000},
      // Source 3000-6000: audio only reaches 4000 -> copy 1000ms, 2000ms
      // silent.
      AudioSlot{3000, 7000, 1000, 3000},
  };
  EXPECT_EQ(slots, expected);
  // Slots tile the full edited timeline contiguously with no gap or overlap.
  ASSERT_FALSE(slots.empty());
  EXPECT_EQ(slots.back().edited_start_ms + slots.back().duration_ms,
            EditedDurationMs(r));
}

TEST(ClipPlaybackPlannerTest, AudioSlotsFullLengthAudioCopiesEveryRange) {
  // Audio at least as long as the video: every reordered slot copies its
  // whole range with no silence, still tiled by full durations in timeline
  // order.
  const auto r = Ranges({{6000, 8000}, {0, 2000}});
  const auto slots = AudioSlots(r, 10000);
  const std::vector<AudioSlot> expected = {
      AudioSlot{6000, 0, 2000, 2000},
      AudioSlot{0, 2000, 2000, 2000},
  };
  EXPECT_EQ(slots, expected);
  for (const AudioSlot& s : slots) {
    EXPECT_EQ(s.copy_duration_ms, s.duration_ms);
  }
}

// Why preview reporting must use the PLAYING slot (not
// ActiveIndexForSourceMs) once clips are reordered: a source position
// overshooting a slot's end into a removed gap resolves by source to the
// next SOURCE range, which after a reorder is an EARLIER timeline slot —
// snapping the reported playhead backward.
TEST(ClipPlaybackPlannerTest, ReorderGapOvershootResolvesToEarlierSlotBySource) {
  // Timeline [r0, r1, r2]; source order is r0, r2, r1 (middle two swapped).
  const auto r = Ranges({{0, 2301}, {3615, 5233}, {2301, 3600}});
  EXPECT_FALSE(IsSourceMonotonic(r));
  // Inside r2, the source resolves to slot 2 correctly.
  EXPECT_EQ(ActiveIndexForSourceMs(3000, r), 2);
  // Overshooting r2's end (3600) into the gap [3600, 3615) resolves to slot
  // 1 (earlier in the edited timeline) — the backward-snap the reporter must
  // avoid.
  EXPECT_EQ(ActiveIndexForSourceMs(3607, r), 1);
  // Reporting from the playing slot (2) instead clamps within that slot, so
  // the edited position climbs to the slot end and never jumps backward.
  EXPECT_EQ(EditedMsForSourceMs(3590, 2, r), 5208);
  EXPECT_EQ(EditedMsForSourceMs(3607, 2, r), 5218);
}

TEST(ClipPlaybackPlannerTest, ReportedEditedPositionResolvesFromSourceNotStaleIndex) {
  // The fix for "scrub sticks at the cut": the reported edited position uses
  // the range CONTAINING the source, so a stale playback index can't park it
  // at the cut. Source 2000 (before the cut) reports 2000 — even though the
  // stale later index would clamp it to the cut point (4000).
  const auto r = Ranges({{0, 4000}, {6000, 10000}});
  const int report_index = ActiveIndexForSourceMs(2000, r);
  EXPECT_EQ(report_index, 0);
  EXPECT_EQ(EditedMsForSourceMs(2000, report_index, r), 2000);
  EXPECT_EQ(EditedMsForSourceMs(2000, 1, r), 4000);
}

TEST(ClipPlaybackPlannerTest, IsAtEndDetectsTheCompletionParkSpot) {
  const auto r = Ranges({{0, 4000}, {6000, 10000}});
  // At/after the last kept range's end -> parked (so play() should restart).
  EXPECT_TRUE(IsAtEnd(10000, r));
  EXPECT_TRUE(IsAtEnd(9985, r, 17));
  // Comfortably inside -> not parked.
  EXPECT_FALSE(IsAtEnd(8000, r));
  EXPECT_FALSE(IsAtEnd(0, r));
  // No ranges -> this helper never reports "at end" (the no-cut path handles
  // it).
  EXPECT_FALSE(IsAtEnd(99999, {}));
}

}  // namespace
}  // namespace clingfy::capture::export_::clip_planner
