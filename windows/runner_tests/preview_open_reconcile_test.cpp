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

}  // namespace
}  // namespace clingfy::preview
