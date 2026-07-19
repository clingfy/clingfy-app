#include "preview/preview_engine.h"

#include <gtest/gtest.h>

namespace clingfy::preview {
namespace {

// Pins Open()'s orphan-reconcile decision (user-reported wedge, 2026-07-14):
// a Dart hot restart survives the native process, so the PreviewEngine kept
// its session alive with no Dart owner — and every subsequent previewOpen
// failed with "already has an active session" until a full app restart.
// A DIFFERENT-session Open while running must close the stale session and
// proceed (Dart is the single serialized driver — it only asks for a new
// session after the old owner is gone).
TEST(PreviewOpenReconcileTest, DifferentSessionWhileRunningReconciles) {
  EXPECT_TRUE(PreviewEngine::ShouldReconcileStaleSession(
      /*running=*/true, "rec_old_1_58af094a", "rec_new_2_33a6acea"));
}

// Same-session re-entry keeps the idempotent reply — never a close/reopen
// churn for a duplicate open of the live session.
TEST(PreviewOpenReconcileTest, SameSessionStaysIdempotent) {
  EXPECT_FALSE(PreviewEngine::ShouldReconcileStaleSession(
      /*running=*/true, "rec_same", "rec_same"));
}

// Nothing to close when the engine isn't running.
TEST(PreviewOpenReconcileTest, NotRunningNeverReconciles) {
  EXPECT_FALSE(PreviewEngine::ShouldReconcileStaleSession(
      /*running=*/false, "", "rec_new"));
  EXPECT_FALSE(PreviewEngine::ShouldReconcileStaleSession(
      /*running=*/false, "rec_old", "rec_new"));
}

// An empty incoming id is rejected by Open()'s own validation — the
// reconcile must not tear down a live session for a request that is going
// to fail anyway.
TEST(PreviewOpenReconcileTest, EmptyIncomingIdNeverReconciles) {
  EXPECT_FALSE(PreviewEngine::ShouldReconcileStaleSession(
      /*running=*/true, "rec_old", ""));
}

// Pins OnSystemResumed()'s decision: after a Modern Standby / suspend
// resume the engine emits `previewInvalidated` (Dart then rebuilds the
// preview in place) only when a session is actually running.
TEST(PreviewResumeInvalidateTest, RunningSessionIsInvalidatedOnResume) {
  EXPECT_TRUE(PreviewEngine::ShouldInvalidateOnSystemResume(
      /*running=*/true, "rec_1_58af094a"));
}

TEST(PreviewResumeInvalidateTest, NotRunningNeverInvalidates) {
  EXPECT_FALSE(PreviewEngine::ShouldInvalidateOnSystemResume(
      /*running=*/false, ""));
  EXPECT_FALSE(PreviewEngine::ShouldInvalidateOnSystemResume(
      /*running=*/false, "rec_leftover"));
}

// A running flag with no session id is a teardown transient — there is no
// session Dart could rebuild, so no event may be emitted.
TEST(PreviewResumeInvalidateTest, EmptySessionIdNeverInvalidates) {
  EXPECT_FALSE(PreviewEngine::ShouldInvalidateOnSystemResume(
      /*running=*/true, ""));
}

// Pins Play()'s restart-from-end decision (editing 4-5, macOS IsAtEnd
// parity): at (or within one frame of) the edited end, Play restarts from 0
// instead of rendering one final frame and immediately EOSing.
TEST(PreviewRestartFromEndTest, AtTheExactEndRestarts) {
  EXPECT_TRUE(PreviewEngine::ShouldRestartEditedPlaybackFromEnd(
      /*edited_pos_ms=*/12000, /*edited_duration_ms=*/12000));
}

TEST(PreviewRestartFromEndTest, WithinOneFrameOfTheEndRestarts) {
  // The pacer stamps the LAST kept frame's edited time, which can land up to
  // a frame short of the exact duration.
  EXPECT_TRUE(PreviewEngine::ShouldRestartEditedPlaybackFromEnd(
      /*edited_pos_ms=*/11967, /*edited_duration_ms=*/12000));
}

TEST(PreviewRestartFromEndTest, MidTimelineNeverRestarts) {
  EXPECT_FALSE(PreviewEngine::ShouldRestartEditedPlaybackFromEnd(
      /*edited_pos_ms=*/6000, /*edited_duration_ms=*/12000));
  EXPECT_FALSE(PreviewEngine::ShouldRestartEditedPlaybackFromEnd(
      /*edited_pos_ms=*/0, /*edited_duration_ms=*/12000));
}

TEST(PreviewRestartFromEndTest, NonPositiveDurationNeverRestarts) {
  // Nothing to play: a zero/negative duration must not loop Play at 0.
  EXPECT_FALSE(PreviewEngine::ShouldRestartEditedPlaybackFromEnd(
      /*edited_pos_ms=*/0, /*edited_duration_ms=*/0));
  EXPECT_FALSE(PreviewEngine::ShouldRestartEditedPlaybackFromEnd(
      /*edited_pos_ms=*/100, /*edited_duration_ms=*/-1));
}

}  // namespace
}  // namespace clingfy::preview
