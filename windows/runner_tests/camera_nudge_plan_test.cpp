#include "preview/preview_engine.h"

#include <gtest/gtest.h>

#include <cstdint>

namespace clingfy::preview {
namespace {

// Phase 9.7: ResolveCameraNudgeTarget bounds the paused-preview camera nudge
// to 1ms around an anchor. The regression it guards against: computing
// `current - 1` on every call let a 60Hz bubble drag walk the playhead
// backward ~1ms per camera edit, visibly rewinding the held frame and the
// Dart timeline scrubber.

TEST(CameraNudgePlanTest, FirstNudgeAnchorsAtCurrentAndStepsBack) {
  const auto plan = ResolveCameraNudgeTarget(/*current_ms=*/500,
                                             /*previous_anchor_ms=*/-1);
  EXPECT_EQ(plan.anchor_ms, 500);
  EXPECT_EQ(plan.target_ms, 499);
}

TEST(CameraNudgePlanTest, FirstNudgeAtZeroStepsForwardNotNegative) {
  const auto plan = ResolveCameraNudgeTarget(0, -1);
  EXPECT_EQ(plan.anchor_ms, 0);
  EXPECT_EQ(plan.target_ms, 1);
}

TEST(CameraNudgePlanTest, RepeatedNudgesAlternateWithoutDrift) {
  // Simulate a long drag: every call reads back the previous target (WinRT
  // Position reflects the pending seek). The position must stay within 1ms
  // of the original 500 no matter how many edits arrive.
  std::int64_t anchor = -1;
  std::int64_t position = 500;
  for (int i = 0; i < 300; ++i) {
    const auto plan = ResolveCameraNudgeTarget(position, anchor);
    anchor = plan.anchor_ms;
    EXPECT_NE(plan.target_ms, position);  // never coalescable
    position = plan.target_ms;
    EXPECT_GE(position, 499);
    EXPECT_LE(position, 500);
  }
  EXPECT_EQ(anchor, 500);
}

TEST(CameraNudgePlanTest, AlternationReturnsToAnchorFromNeighbor) {
  const auto away = ResolveCameraNudgeTarget(500, 500);
  EXPECT_EQ(away.anchor_ms, 500);
  EXPECT_EQ(away.target_ms, 499);
  const auto back = ResolveCameraNudgeTarget(499, 500);
  EXPECT_EQ(back.anchor_ms, 500);
  EXPECT_EQ(back.target_ms, 500);
}

TEST(CameraNudgePlanTest, ExternalSeekReAnchors) {
  // User scrubbed to 2000 while the old anchor was 500: the nudge must
  // follow the user, not drag the playhead back to the stale anchor.
  const auto plan = ResolveCameraNudgeTarget(2000, 500);
  EXPECT_EQ(plan.anchor_ms, 2000);
  EXPECT_EQ(plan.target_ms, 1999);
}

TEST(CameraNudgePlanTest, ZeroAnchorAlternatesAgainstOne) {
  const auto away = ResolveCameraNudgeTarget(0, 0);
  EXPECT_EQ(away.anchor_ms, 0);
  EXPECT_EQ(away.target_ms, 1);
  const auto back = ResolveCameraNudgeTarget(1, 0);
  EXPECT_EQ(back.anchor_ms, 0);
  EXPECT_EQ(back.target_ms, 0);
}

}  // namespace
}  // namespace clingfy::preview
