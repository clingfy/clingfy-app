#include "preview/preview_engine.h"

#include <gtest/gtest.h>

#include <vector>

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

// Pins the aspect-matched shared-texture sizing (polish: the fixed 1280x720
// texture baked letterbox bars into the pixels, which doubled up with
// Flutter's AspectRatio bars on non-16:9 recordings — and parked the camera
// bubble's canvas corners inside the bars, off the export's auto canvas).
TEST(PreviewTextureSizeTest, UnknownHintsKeepTheHistoricalBudget) {
  const auto s = PreviewEngine::ComputePreviewTextureSize(0, 0);
  EXPECT_EQ(s.width, 1280);
  EXPECT_EQ(s.height, 720);
  const auto neg = PreviewEngine::ComputePreviewTextureSize(-1, 1080);
  EXPECT_EQ(neg.width, 1280);
  EXPECT_EQ(neg.height, 720);
}

TEST(PreviewTextureSizeTest, SixteenNineFillsTheBudgetExactly) {
  const auto s = PreviewEngine::ComputePreviewTextureSize(1920, 1080);
  EXPECT_EQ(s.width, 1280);
  EXPECT_EQ(s.height, 720);
}

TEST(PreviewTextureSizeTest, PortraitFitsHeightAndNarrowsWidth) {
  // 1080x1920 → height-bound: w = 720 * (1080/1920) = 405 → 404 even-aligned.
  const auto s = PreviewEngine::ComputePreviewTextureSize(1080, 1920);
  EXPECT_EQ(s.width, 404);
  EXPECT_EQ(s.height, 720);
}

TEST(PreviewTextureSizeTest, SquareIsHeightBound) {
  const auto s = PreviewEngine::ComputePreviewTextureSize(1000, 1000);
  EXPECT_EQ(s.width, 720);
  EXPECT_EQ(s.height, 720);
}

TEST(PreviewTextureSizeTest, UltrawideFitsWidthAndShortensHeight) {
  // 3440x1440 → width-bound: h = 1280 / (3440/1440) = 535.8 → 535 → 534 even.
  const auto s = PreviewEngine::ComputePreviewTextureSize(3440, 1440);
  EXPECT_EQ(s.width, 1280);
  EXPECT_EQ(s.height, 534);
}

TEST(PreviewTextureSizeTest, DegenerateHintsHitTheFloorNotZero) {
  const auto s = PreviewEngine::ComputePreviewTextureSize(10000, 1);
  EXPECT_EQ(s.width, 1280);
  EXPECT_EQ(s.height, 16);
}

TEST(PreviewRestartFromEndTest, NonPositiveDurationNeverRestarts) {
  // Nothing to play: a zero/negative duration must not loop Play at 0.
  EXPECT_FALSE(PreviewEngine::ShouldRestartEditedPlaybackFromEnd(
      /*edited_pos_ms=*/0, /*edited_duration_ms=*/0));
  EXPECT_FALSE(PreviewEngine::ShouldRestartEditedPlaybackFromEnd(
      /*edited_pos_ms=*/100, /*edited_duration_ms=*/-1));
}

// Pins the monotonic gap-seek target (user-reported lag, 2026-07-20: delete
// a middle segment → the pacer decode-crawled the whole deleted span while
// the audio master clock seeked across it instantly, leaving the video
// seconds behind the sound). The pacer seeks to the NEXT kept range's
// source_in when the remaining gap is large.
namespace clip = clingfy::capture::export_::clip_planner;

std::vector<clip::ClipKeptRange> DeleteMiddleRanges() {
  // Kept [0,6000) + [14000,20000): an 8s deleted middle.
  return {clip::ClipKeptRange{/*source_in_ms=*/0, /*source_out_ms=*/6000},
          clip::ClipKeptRange{/*source_in_ms=*/14000,
                              /*source_out_ms=*/20000}};
}

TEST(NextKeptSourceInAfterTest, GapFrameTargetsTheNextRangeStart) {
  const auto ranges = DeleteMiddleRanges();
  EXPECT_EQ(PreviewEngine::NextKeptSourceInMsAfter(6000, ranges), 14000);
  EXPECT_EQ(PreviewEngine::NextKeptSourceInMsAfter(9000, ranges), 14000);
  EXPECT_EQ(PreviewEngine::NextKeptSourceInMsAfter(13999, ranges), 14000);
}

TEST(NextKeptSourceInAfterTest, HeadTrimGapTargetsTheFirstRange) {
  // A head-trim leaves a leading gap — the seek helps there too.
  std::vector<clip::ClipKeptRange> ranges{
      clip::ClipKeptRange{/*source_in_ms=*/5000, /*source_out_ms=*/10000}};
  EXPECT_EQ(PreviewEngine::NextKeptSourceInMsAfter(0, ranges), 5000);
  EXPECT_EQ(PreviewEngine::NextKeptSourceInMsAfter(4999, ranges), 5000);
}

TEST(NextKeptSourceInAfterTest, NothingAfterTheLastRangeReturnsMinusOne) {
  const auto ranges = DeleteMiddleRanges();
  // Inside/after the last kept window: no later kept start — the pacer
  // crawls to EOS (the playback-complete path), never seeks.
  EXPECT_EQ(PreviewEngine::NextKeptSourceInMsAfter(14000, ranges), -1);
  EXPECT_EQ(PreviewEngine::NextKeptSourceInMsAfter(19000, ranges), -1);
  EXPECT_EQ(PreviewEngine::NextKeptSourceInMsAfter(25000, ranges), -1);
}

// ---- Edited-pacer chase policy -------------------------------------------
//
// The audio renderer is the master clock, but the preview's SOFTWARE video
// decode has almost no headroom (~1.0-1.7x realtime), so "discard every
// frame behind the sound" froze the picture outright (user-reported
// 2026-07-20). These pin the replacement policy, including the two corners
// the review caught in the first cut: seeking into the tail (the edited end
// maps one-past-the-last-kept-frame -> every remaining frame floored out)
// and back-to-back chase seeks starving the picture during keyframe lead-in
// decode.

using Chase = PreviewEngine::PacerChaseInput;
using ChaseAction = PreviewEngine::PacerChaseAction;

Chase InSync() {
  Chase c;
  c.frame_edited_ms = 5000;
  c.audio_edited_ms = 5000;
  c.edited_duration_ms = 60000;
  return c;
}

TEST(PacerChasePolicyTest, InSyncFrameEmits) {
  const auto d = PreviewEngine::DecidePacerChase(InSync());
  EXPECT_EQ(d.action, ChaseAction::kEmit);
  EXPECT_EQ(d.next_stale_streak, 0);
}

TEST(PacerChasePolicyTest, NoAudioSessionAlwaysEmits) {
  // Free-run (pre-audio behavior): a silent session must be unaffected by
  // every rule below, however far "behind" its position looks.
  Chase c = InSync();
  c.audio_edited_ms = -1;
  c.frame_edited_ms = 0;
  c.stale_streak = 5;
  const auto d = PreviewEngine::DecidePacerChase(c);
  EXPECT_EQ(d.action, ChaseAction::kEmit);
  EXPECT_EQ(d.next_stale_streak, 0);
}

TEST(PacerChasePolicyTest, SlightlyBehindStillCountsAsInSync) {
  Chase c = InSync();
  c.frame_edited_ms = 5000 - PreviewEngine::kAudioChaseSlackMs;
  EXPECT_EQ(PreviewEngine::DecidePacerChase(c).action, ChaseAction::kEmit);
}

TEST(PacerChasePolicyTest, StaleFrameDiscardsUntilTheDecimationTick) {
  // A modest trail (under the chase-seek deficit): discard, discard, ...
  // then emit the Nth so the picture never stops advancing.
  Chase c = InSync();
  c.frame_edited_ms = 4000;  // 1s behind — stale, but no seek
  int streak = 0;
  for (int i = 1; i < PreviewEngine::kStaleEmitEvery; ++i) {
    c.stale_streak = streak;
    const auto d = PreviewEngine::DecidePacerChase(c);
    EXPECT_EQ(d.action, ChaseAction::kDiscard) << "iteration " << i;
    EXPECT_EQ(d.next_stale_streak, i);
    streak = d.next_stale_streak;
  }
  c.stale_streak = streak;
  const auto d = PreviewEngine::DecidePacerChase(c);
  EXPECT_EQ(d.action, ChaseAction::kEmit);
  EXPECT_EQ(d.next_stale_streak, 0) << "the streak restarts after an emit";
}

TEST(PacerChasePolicyTest, LargeDeficitSeeksToTheAudioClock) {
  Chase c = InSync();
  c.audio_edited_ms = 20000;
  c.frame_edited_ms = 10000;  // 10s behind
  const auto d = PreviewEngine::DecidePacerChase(c);
  EXPECT_EQ(d.action, ChaseAction::kSeekToAudio);
  EXPECT_EQ(d.seek_target_edited_ms, 20000);
}

TEST(PacerChasePolicyTest, ChaseSeekRespectsTheCooldown) {
  Chase c = InSync();
  c.audio_edited_ms = 20000;
  c.frame_edited_ms = 10000;
  c.ms_since_chase_seek = PreviewEngine::kChaseSeekCooldownMs - 1;
  const auto d = PreviewEngine::DecidePacerChase(c);
  EXPECT_NE(d.action, ChaseAction::kSeekToAudio)
      << "back-to-back seeks would storm keyframe lead-in decodes";
  EXPECT_EQ(d.action, ChaseAction::kDiscard);  // decimation carries it

  c.ms_since_chase_seek = PreviewEngine::kChaseSeekCooldownMs;
  EXPECT_EQ(PreviewEngine::DecidePacerChase(c).action,
            ChaseAction::kSeekToAudio);
}

TEST(PacerChasePolicyTest, NeverSeeksIntoTheTail) {
  // THE REGRESSION: SourceMsForEditedMs(edited_duration) returns
  // ranges.back().source_out_ms — one past the last kept frame. Seeking
  // there sets the lead-in floor above every remaining frame, so the
  // picture freezes for the rest of playback and the playhead never
  // reaches the end. Near the end we decimate instead.
  Chase c;
  c.edited_duration_ms = 12000;
  c.audio_edited_ms = 12000;  // sound has reached the end
  c.frame_edited_ms = 4000;   // video 8s behind
  EXPECT_NE(PreviewEngine::DecidePacerChase(c).action,
            ChaseAction::kSeekToAudio);

  // Just inside the guard — still no seek.
  c.audio_edited_ms = 12000 - PreviewEngine::kChaseSeekEndGuardMs;
  EXPECT_NE(PreviewEngine::DecidePacerChase(c).action,
            ChaseAction::kSeekToAudio);

  // Comfortably clear of the tail — seek allowed again.
  c.audio_edited_ms = 12000 - PreviewEngine::kChaseSeekEndGuardMs - 1;
  EXPECT_EQ(PreviewEngine::DecidePacerChase(c).action,
            ChaseAction::kSeekToAudio);
}

TEST(PacerChasePolicyTest, UnknownDurationNeverSeeks) {
  // No duration = no way to know where the tail is; decimate only.
  Chase c = InSync();
  c.edited_duration_ms = 0;
  c.audio_edited_ms = 20000;
  c.frame_edited_ms = 10000;
  EXPECT_NE(PreviewEngine::DecidePacerChase(c).action,
            ChaseAction::kSeekToAudio);
}

TEST(PacerChasePolicyTest, PostSeekFrameEmitsUnconditionally) {
  // THE OTHER REGRESSION: after a chase seek the reader decodes a keyframe
  // lead-in (~GOP, seconds at these decode rates) during which audio keeps
  // advancing — so the frame we sought to arrives "stale" and, without
  // this rule, immediately triggered ANOTHER seek. Seek, decode, discard,
  // seek: the picture never advanced at all.
  Chase c = InSync();
  c.awaiting_chase_frame = true;
  c.audio_edited_ms = 30000;
  c.frame_edited_ms = 20000;   // 10s "behind" purely from lead-in decode
  c.ms_since_chase_seek = PreviewEngine::kChaseSeekCooldownMs + 1;
  const auto d = PreviewEngine::DecidePacerChase(c);
  EXPECT_EQ(d.action, ChaseAction::kEmit);
  EXPECT_EQ(d.next_stale_streak, 0);
}

TEST(PacerChasePolicyTest, ReorderBranchDecimatesInsteadOfSeeking) {
  // Reorder playback can't reposition (the range cursor would need
  // re-priming), so the same deficit decimates.
  Chase c = InSync();
  c.allow_chase_seek = false;
  c.audio_edited_ms = 20000;
  c.frame_edited_ms = 10000;
  const auto d = PreviewEngine::DecidePacerChase(c);
  EXPECT_EQ(d.action, ChaseAction::kDiscard);
  EXPECT_EQ(d.next_stale_streak, 1);

  c.stale_streak = PreviewEngine::kStaleEmitEvery - 1;
  EXPECT_EQ(PreviewEngine::DecidePacerChase(c).action, ChaseAction::kEmit);
}

TEST(PacerChasePolicyTest, PictureAlwaysAdvancesUnderAnyDeficit) {
  // The load-bearing property: whatever the trail, a bounded number of
  // consecutive decisions must produce an emit — never an unbounded
  // discard run (that IS the reported freeze).
  for (const std::int64_t deficit : {100, 1500, 5000, 60000, 600000}) {
    Chase c;
    c.edited_duration_ms = 1'000'000;  // far from the tail
    c.audio_edited_ms = 700000;
    c.frame_edited_ms = 700000 - deficit;
    c.allow_chase_seek = false;  // worst case: no reposition available
    int emits = 0;
    for (int i = 0; i < PreviewEngine::kStaleEmitEvery; ++i) {
      const auto d = PreviewEngine::DecidePacerChase(c);
      if (d.action == ChaseAction::kEmit) ++emits;
      c.stale_streak = d.next_stale_streak;
    }
    EXPECT_GE(emits, 1) << "deficit " << deficit << "ms produced no frame";
  }
}

TEST(NextKeptSourceInAfterTest, PicksTheNearestStartRegardlessOfOrder) {
  // Defensive: the helper min-scans, so an unsorted list (reorder input
  // never reaches it, but nothing enforces that here) still resolves to
  // the nearest following start.
  std::vector<clip::ClipKeptRange> ranges{
      clip::ClipKeptRange{/*source_in_ms=*/14000, /*source_out_ms=*/20000},
      clip::ClipKeptRange{/*source_in_ms=*/8000, /*source_out_ms=*/9000},
      clip::ClipKeptRange{/*source_in_ms=*/0, /*source_out_ms=*/6000}};
  EXPECT_EQ(PreviewEngine::NextKeptSourceInMsAfter(6500, ranges), 8000);
}

// ---------------------------------------------------------------------------
// Pacer stall watchdog.
//
// WHY THIS EXISTS: a dev build burned ~0.7 of a core for 35 hours with a
// preview open that rendered 625 frames in that time, and the release log said
// nothing — the per-window pacer line is Debug, which release builds drop, so
// Task Manager was the only evidence. The condition ("playing, emitting
// nothing") is nameable, so it is now reported at Info.
//
// The rate limiting is the whole design. Reporting every window would be the
// 2s-line problem again; reporting once would lose a 34-hour stall's duration.
// ---------------------------------------------------------------------------

using Stall = PreviewEngine::PacerStallInput;
using StallReport = PreviewEngine::PacerStallReport;

// Runs `windows` consecutive frameless windows, returning every report emitted.
std::vector<StallReport> RunStalledWindows(int windows) {
  std::vector<StallReport> reports;
  Stall s;
  for (int i = 0; i < windows; ++i) {
    const auto d = PreviewEngine::DecidePacerStallReport(s);
    if (d.report != StallReport::kNone) reports.push_back(d.report);
    s.stalled_windows = d.next_stalled_windows;
    s.stall_reported = d.next_stall_reported;
  }
  return reports;
}

TEST(PacerStallWatchdogTest, RenderingNormallyNeverReports) {
  Stall s;
  for (int i = 0; i < 100; ++i) {
    s.rendered_in_window = 1;
    const auto d = PreviewEngine::DecidePacerStallReport(s);
    EXPECT_EQ(d.report, StallReport::kNone);
    EXPECT_EQ(d.next_stalled_windows, 0);
    s.stalled_windows = d.next_stalled_windows;
    s.stall_reported = d.next_stall_reported;
  }
}

// A pause, a seek, or a slow decode can legitimately produce a frameless
// window. Reporting those would train the reader to ignore the line.
TEST(PacerStallWatchdogTest, ShortGapsAreSilent) {
  EXPECT_TRUE(RunStalledWindows(PreviewEngine::kPacerStallOnsetWindows - 1)
                  .empty());
}

TEST(PacerStallWatchdogTest, ReportsOnceAtTheOnsetThreshold) {
  const auto reports =
      RunStalledWindows(PreviewEngine::kPacerStallOnsetWindows);
  ASSERT_EQ(reports.size(), 1u);
  EXPECT_EQ(reports[0], StallReport::kStalled);
}

// THE 35-HOUR CASE. It must keep saying so — a single line at onset would be
// indistinguishable from a stall that ended a second later — but at a cadence
// that stays readable, not once per window.
TEST(PacerStallWatchdogTest, LongStallRepeatsOnACappedCadence) {
  const int windows = PreviewEngine::kPacerStallOnsetWindows +
                      PreviewEngine::kPacerStallRepeatWindows * 3;
  const auto reports = RunStalledWindows(windows);
  EXPECT_EQ(reports.size(), 4u)  // onset + 3 repeats
      << "expected onset plus one report per repeat interval, got "
      << reports.size();
  for (const auto report : reports) EXPECT_EQ(report, StallReport::kStalled);
}

TEST(PacerStallWatchdogTest, RecoveryIsReportedAfterAReportedStall) {
  Stall s;
  for (int i = 0; i < PreviewEngine::kPacerStallOnsetWindows; ++i) {
    const auto d = PreviewEngine::DecidePacerStallReport(s);
    s.stalled_windows = d.next_stalled_windows;
    s.stall_reported = d.next_stall_reported;
  }
  ASSERT_TRUE(s.stall_reported);

  s.rendered_in_window = 1;
  const auto d = PreviewEngine::DecidePacerStallReport(s);
  EXPECT_EQ(d.report, StallReport::kRecovered);
  EXPECT_EQ(d.next_stalled_windows, 0);
  EXPECT_FALSE(d.next_stall_reported);
}

// Recovery from a stall nobody was told about is not news.
TEST(PacerStallWatchdogTest, RecoveryIsSilentWhenTheStallWasNeverReported) {
  Stall s;
  s.stalled_windows = PreviewEngine::kPacerStallOnsetWindows - 1;
  s.stall_reported = false;
  s.rendered_in_window = 1;
  const auto d = PreviewEngine::DecidePacerStallReport(s);
  EXPECT_EQ(d.report, StallReport::kNone);
  EXPECT_EQ(d.next_stalled_windows, 0);
}

// A stall that resumes and stalls again is two events, and the second must be
// announced on its own merits rather than suppressed by the first's flag.
TEST(PacerStallWatchdogTest, ASecondStallReportsAgain) {
  Stall s;
  for (int i = 0; i < PreviewEngine::kPacerStallOnsetWindows; ++i) {
    const auto d = PreviewEngine::DecidePacerStallReport(s);
    s.stalled_windows = d.next_stalled_windows;
    s.stall_reported = d.next_stall_reported;
  }
  s.rendered_in_window = 1;
  const auto recovered = PreviewEngine::DecidePacerStallReport(s);
  ASSERT_EQ(recovered.report, StallReport::kRecovered);
  s.stalled_windows = recovered.next_stalled_windows;
  s.stall_reported = recovered.next_stall_reported;
  s.rendered_in_window = 0;

  std::vector<StallReport> second;
  for (int i = 0; i < PreviewEngine::kPacerStallOnsetWindows; ++i) {
    const auto d = PreviewEngine::DecidePacerStallReport(s);
    if (d.report != StallReport::kNone) second.push_back(d.report);
    s.stalled_windows = d.next_stalled_windows;
    s.stall_reported = d.next_stall_reported;
  }
  ASSERT_EQ(second.size(), 1u);
  EXPECT_EQ(second[0], StallReport::kStalled);
}

}  // namespace
}  // namespace clingfy::preview
