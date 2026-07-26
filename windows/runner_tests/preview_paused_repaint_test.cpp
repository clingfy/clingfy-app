#include "preview/preview_engine.h"

#include <gtest/gtest.h>

namespace clingfy::preview {
namespace {

// Readability aliases for the two booleans the policy takes.
constexpr bool kPlaying = true;
constexpr bool kNotPlaying = false;
constexpr bool kHasFrame = true;
constexpr bool kNoFrame = false;

TEST(PausedRepaintTest, PlayingDefersToTheNextNaturalFrame) {
  // A grade change during playback is already picked up by the next composited
  // frame. Repainting on top of that is duplicate work.
  EXPECT_EQ(DecidePausedRepaint(kPlaying, kHasFrame),
            PausedRepaintAction::kSkipPlaying);
}

TEST(PausedRepaintTest, PlayingSkipsEvenBeforeTheFirstFrame) {
  EXPECT_EQ(DecidePausedRepaint(kPlaying, kNoFrame),
            PausedRepaintAction::kSkipPlaying);
}

// The regression. Pausing (or reaching the end of) the preview and then moving a
// color slider used to do nothing visible: the code tried to manufacture a frame
// by seeking +/-1ms, which forces a decode and produces nothing at all at
// end-of-stream, where the target lands past the end. The retained frame is
// still on screen, so re-compositing it is both cheaper and EOS-safe.
TEST(PausedRepaintTest, PausedWithAFrameRecompositesInsteadOfSeeking) {
  EXPECT_EQ(DecidePausedRepaint(kNotPlaying, kHasFrame),
            PausedRepaintAction::kRepaintRetained);
  EXPECT_NE(DecidePausedRepaint(kNotPlaying, kHasFrame),
            PausedRepaintAction::kNudgeSeek);
}

// Nothing composed yet: there is no retained frame to re-light, so the seek
// nudge stays as the cold-start fallback rather than silently doing nothing.
TEST(PausedRepaintTest, PausedWithoutAFrameFallsBackToTheSeekNudge) {
  EXPECT_EQ(DecidePausedRepaint(kNotPlaying, kNoFrame),
            PausedRepaintAction::kNudgeSeek);
}

// The policy is a pure function of the two inputs — no hidden state, so a drag
// that fires many settings changes resolves identically every time.
TEST(PausedRepaintTest, IsStableAcrossRepeatedCalls) {
  for (int i = 0; i < 100; ++i) {
    EXPECT_EQ(DecidePausedRepaint(kNotPlaying, kHasFrame),
              PausedRepaintAction::kRepaintRetained);
  }
}

}  // namespace
}  // namespace clingfy::preview
