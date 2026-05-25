#include "Capture/recording_clock.h"

#include <gtest/gtest.h>

#include <cstdint>

namespace clingfy::capture {
namespace {

// A reasonably common QPC frequency on modern Windows boxes is 10 MHz; we
// fix it here so the conversion math is easy to follow in the test
// expectations.
constexpr std::int64_t kQpcFrequencyHz = 10'000'000;

TEST(RecordingClockTest, NoStartReturnsZero) {
  std::int64_t fake_now = 0;
  RecordingClock clock([&] { return fake_now; }, kQpcFrequencyHz);
  EXPECT_EQ(clock.ElapsedHns(), 0);
  EXPECT_FALSE(clock.started());
}

TEST(RecordingClockTest, ElapsedHnsAfterOneSecond) {
  std::int64_t fake_now = kQpcFrequencyHz * 5;  // Arbitrary base.
  RecordingClock clock([&] { return fake_now; }, kQpcFrequencyHz);
  clock.MarkStart();
  EXPECT_TRUE(clock.started());

  fake_now += kQpcFrequencyHz;  // Advance one second.
  EXPECT_EQ(clock.ElapsedHns(), 10'000'000)
      << "One second must round-trip to exactly 10_000_000 100-ns units — "
         "Media Foundation expects 100-ns sample timestamps.";
}

TEST(RecordingClockTest, ElapsedHnsAfterFractionalSecond) {
  std::int64_t fake_now = 0;
  RecordingClock clock([&] { return fake_now; }, kQpcFrequencyHz);
  clock.MarkStart();
  fake_now = kQpcFrequencyHz / 4;  // 0.25 seconds.
  EXPECT_EQ(clock.ElapsedHns(), 2'500'000);
}

TEST(RecordingClockTest, TicksToHnsForExternalTimestamp) {
  std::int64_t fake_now = 1'000;
  RecordingClock clock([&] { return fake_now; }, kQpcFrequencyHz);
  clock.MarkStart();
  EXPECT_EQ(clock.TicksToHns(1'000 + kQpcFrequencyHz / 2), 5'000'000)
      << "TicksToHns lets the capture callback hand its own QPC timestamp "
         "in without re-querying the clock.";
}

TEST(RecordingClockTest, NegativeDeltaReturnsZero) {
  std::int64_t fake_now = 1'000'000;
  RecordingClock clock([&] { return fake_now; }, kQpcFrequencyHz);
  clock.MarkStart();
  // Clock skew (or a stamp from before MarkStart) must not produce a
  // negative timestamp — MF will reject those and the encoder will fall over.
  EXPECT_EQ(clock.TicksToHns(500'000), 0);
}

TEST(RecordingClockTest, ZeroFrequencyReturnsZero) {
  std::int64_t fake_now = 0;
  RecordingClock clock([&] { return fake_now; }, /*qpc_frequency=*/0);
  clock.MarkStart();
  fake_now = 1'000'000;
  EXPECT_EQ(clock.ElapsedHns(), 0)
      << "A bogus frequency must not divide-by-zero; returning 0 lets the "
         "engine surface a structured RECORDING_ERROR instead of crashing.";
}

TEST(RecordingClockTest, RemarkStartRebases) {
  std::int64_t fake_now = 1'000;
  RecordingClock clock([&] { return fake_now; }, kQpcFrequencyHz);
  clock.MarkStart();
  fake_now += kQpcFrequencyHz * 10;  // 10s pass.
  EXPECT_EQ(clock.ElapsedHns(), 100'000'000);

  clock.MarkStart();  // Rebase.
  fake_now += kQpcFrequencyHz;  // 1s pass since rebase.
  EXPECT_EQ(clock.ElapsedHns(), 10'000'000);
}

TEST(RecordingClockTest, LargeElapsedDoesNotOverflow) {
  // Two-hour recording at the 10 MHz frequency exercises the seconds +
  // remainder split — `delta * 10_000_000` directly would overflow.
  std::int64_t fake_now = 0;
  RecordingClock clock([&] { return fake_now; }, kQpcFrequencyHz);
  clock.MarkStart();
  const std::int64_t two_hours_ticks = kQpcFrequencyHz * 60LL * 60LL * 2LL;
  fake_now = two_hours_ticks;
  EXPECT_EQ(clock.ElapsedHns(), 60LL * 60LL * 2LL * 10'000'000LL);
}

// === Phase 4: pause / resume "skip the gap" math ==========================
//
// A user pauses for X seconds in the middle of a recording, then
// resumes. The MP4 the engine produces should be (total wall time - X)
// long, NOT (total wall time) long with X seconds of frozen frame at
// the seam. That contract lives in RecordingClock::ElapsedHns
// subtracting `paused_hns_` from the raw QPC delta.

TEST(RecordingClockTest, PauseFreezesElapsedTime) {
  std::int64_t fake_now = 0;
  RecordingClock clock([&] { return fake_now; }, kQpcFrequencyHz);
  clock.MarkStart();
  fake_now = kQpcFrequencyHz;  // 1s recorded
  EXPECT_EQ(clock.ElapsedHns(), 10'000'000);
  clock.Pause();
  EXPECT_TRUE(clock.paused());

  // Wall-clock advances 5s while paused — but ElapsedHns must NOT.
  fake_now += kQpcFrequencyHz * 5;
  EXPECT_EQ(clock.ElapsedHns(), 10'000'000)
      << "While paused the encoder's notion of time must stay frozen — "
         "otherwise the MP4 would have 5s of duplicate-frame stall at "
         "the seam.";
}

TEST(RecordingClockTest, ResumePicksUpFromPauseInstant) {
  std::int64_t fake_now = 0;
  RecordingClock clock([&] { return fake_now; }, kQpcFrequencyHz);
  clock.MarkStart();
  fake_now = kQpcFrequencyHz;  // 1s recorded
  clock.Pause();
  fake_now += kQpcFrequencyHz * 5;  // 5s paused
  clock.Resume();
  EXPECT_FALSE(clock.paused());
  // First sample after resume: ElapsedHns reports 1s — the same place
  // the recording paused at.
  EXPECT_EQ(clock.ElapsedHns(), 10'000'000);
  // Another 2s of real recording.
  fake_now += kQpcFrequencyHz * 2;
  EXPECT_EQ(clock.ElapsedHns(), 30'000'000);
}

TEST(RecordingClockTest, MultiplePauseCyclesAccumulate) {
  std::int64_t fake_now = 0;
  RecordingClock clock([&] { return fake_now; }, kQpcFrequencyHz);
  clock.MarkStart();

  // Record 1s, pause 2s, record 1s, pause 3s, record 1s.
  fake_now += kQpcFrequencyHz;
  clock.Pause();
  fake_now += kQpcFrequencyHz * 2;
  clock.Resume();
  fake_now += kQpcFrequencyHz;
  clock.Pause();
  fake_now += kQpcFrequencyHz * 3;
  clock.Resume();
  fake_now += kQpcFrequencyHz;

  // Total recorded content is 3s; pauses (5s) should be subtracted.
  EXPECT_EQ(clock.ElapsedHns(), 30'000'000);
  EXPECT_EQ(clock.paused_hns(), 50'000'000)
      << "Both pause intervals should add to the cumulative counter.";
}

TEST(RecordingClockTest, IdempotentPauseAndResume) {
  std::int64_t fake_now = 0;
  RecordingClock clock([&] { return fake_now; }, kQpcFrequencyHz);
  clock.MarkStart();
  clock.Pause();
  clock.Pause();   // No-op.
  fake_now += kQpcFrequencyHz * 2;
  clock.Resume();
  clock.Resume();  // No-op.
  // Only the first Pause / first Resume took effect; 2s of pause time
  // should be accumulated, not 4.
  EXPECT_EQ(clock.paused_hns(), 20'000'000);
}

TEST(RecordingClockTest, ResumeWithoutPauseIsIgnored) {
  std::int64_t fake_now = 0;
  RecordingClock clock([&] { return fake_now; }, kQpcFrequencyHz);
  clock.MarkStart();
  clock.Resume();  // No-op.
  fake_now += kQpcFrequencyHz;
  EXPECT_EQ(clock.ElapsedHns(), 10'000'000);
  EXPECT_EQ(clock.paused_hns(), 0);
}

TEST(RecordingClockTest, MarkStartResetsPauseAccounting) {
  std::int64_t fake_now = 0;
  RecordingClock clock([&] { return fake_now; }, kQpcFrequencyHz);
  clock.MarkStart();
  clock.Pause();
  fake_now += kQpcFrequencyHz * 3;
  clock.Resume();
  EXPECT_EQ(clock.paused_hns(), 30'000'000);

  // Restart for a new recording — the pause counter should reset so
  // the second session doesn't inherit a five-second offset.
  clock.MarkStart();
  EXPECT_EQ(clock.paused_hns(), 0);
  EXPECT_FALSE(clock.paused());
}

}  // namespace
}  // namespace clingfy::capture
