#include "Audio/microphone_level.h"

#include <gtest/gtest.h>

#include <chrono>
#include <cmath>
#include <limits>
#include <vector>

// The pre-recording microphone meter's decision table.
//
// Why this matters beyond a unit test: on Windows the quiet-mic warning could
// not fire at all until this shipped. Every consumer already existed — the
// Dart handler, the threshold, the meter icon and the
// `mic_input_too_low_warning` notice, none of them platform-gated — and only
// the native emitter was missing, so `_micInputLevelDbfs` sat at its initial
// -160.0 forever. A user recorded a full take into a microphone delivering
// nothing but a noise floor, exported it, and only discovered the silence on
// another machine. The numbers below are the ones that would have caught it.
namespace clingfy::audio {
namespace {

// Interleaved stereo buffer whose loudest sample is `peak`.
std::vector<float> BufferWithPeak(float peak, std::size_t frames = 480) {
  std::vector<float> samples(frames * 2, 0.0f);
  if (!samples.empty()) {
    samples[frames] = peak;      // somewhere in the middle, not the first slot
    samples[frames + 1] = -peak / 2.0f;
  }
  return samples;
}

TEST(MicrophoneLevelTest, FullScaleReadsZeroDbfsAndIsNotLow) {
  const auto buffer = BufferWithPeak(1.0f);
  const MicrophoneLevel level =
      ComputeMicrophoneLevel(buffer.data(), buffer.size());

  EXPECT_DOUBLE_EQ(level.linear, 1.0);
  EXPECT_NEAR(level.dbfs, 0.0, 0.001);
  EXPECT_FALSE(level.is_low);
}

TEST(MicrophoneLevelTest, NormalSpeechIsNotFlaggedLow) {
  // -12 dBFS: a comfortably recorded voice. Warning here would be noise.
  const auto buffer = BufferWithPeak(std::pow(10.0f, -12.0f / 20.0f));
  const MicrophoneLevel level =
      ComputeMicrophoneLevel(buffer.data(), buffer.size());

  EXPECT_NEAR(level.dbfs, -12.0, 0.01);
  EXPECT_FALSE(level.is_low);
}

TEST(MicrophoneLevelTest, TheRealWorldFailureIsFlaggedLow) {
  // -50 dBFS is what the reporting user's built-in array microphone actually
  // delivered, measured with ffmpeg on the capture bundle AND independently
  // outside the app. Speech was inaudible. This is the case the warning
  // exists for.
  const auto buffer = BufferWithPeak(std::pow(10.0f, -50.0f / 20.0f));
  const MicrophoneLevel level =
      ComputeMicrophoneLevel(buffer.data(), buffer.size());

  EXPECT_NEAR(level.dbfs, -50.0, 0.01);
  EXPECT_TRUE(level.is_low);
}

TEST(MicrophoneLevelTest, DigitalSilenceIsFlaggedLowToMatchMacOS) {
  // macOS's MicrophoneLevelSample.isLow is `dbfs < -32.0` with NO lower
  // bound, so a selected-but-dead microphone warns there. It must warn here
  // too, or the same hardware behaves differently per platform. "No mic
  // selected" is the UI's job (`_hasSelectedMicrophone`), not this threshold's.
  const std::vector<float> buffer(960, 0.0f);
  const MicrophoneLevel level =
      ComputeMicrophoneLevel(buffer.data(), buffer.size());

  EXPECT_DOUBLE_EQ(level.linear, 0.0);
  EXPECT_DOUBLE_EQ(level.dbfs, kMicLevelSilenceDbfs);
  EXPECT_TRUE(level.is_low);
}

TEST(MicrophoneLevelTest, ThresholdBoundaryMatchesMacOS) {
  const auto just_under = BufferWithPeak(std::pow(10.0f, -32.5f / 20.0f));
  const auto just_over = BufferWithPeak(std::pow(10.0f, -31.5f / 20.0f));

  EXPECT_TRUE(ComputeMicrophoneLevel(just_under.data(), just_under.size())
                  .is_low);
  EXPECT_FALSE(
      ComputeMicrophoneLevel(just_over.data(), just_over.size()).is_low);
}

TEST(MicrophoneLevelTest, PeakNotRmsSoAPauseDoesNotWarn) {
  // A buffer that is mostly silence with one loud syllable in it is a person
  // talking with a gap, not a quiet microphone. RMS over this reads ~-27 dB
  // lower than the peak and would warn about a perfectly good input every
  // time the user drew breath.
  std::vector<float> samples(9600, 0.0f);
  samples[42] = 0.5f;  // half scale, -6.02 dBFS
  const MicrophoneLevel level =
      ComputeMicrophoneLevel(samples.data(), samples.size());

  EXPECT_NEAR(level.dbfs, -6.02, 0.01);
  EXPECT_FALSE(level.is_low);
}

TEST(MicrophoneLevelTest, HotInputIsClampedRatherThanDrawnPastFull) {
  // WASAPI float samples can exceed [-1, 1]. The meter must pin, not overflow.
  const auto buffer = BufferWithPeak(2.5f);
  const MicrophoneLevel level =
      ComputeMicrophoneLevel(buffer.data(), buffer.size());

  EXPECT_DOUBLE_EQ(level.linear, 1.0);
  EXPECT_NEAR(level.dbfs, 0.0, 0.001);
  EXPECT_FALSE(level.is_low);
}

TEST(MicrophoneLevelTest, NegativePeaksCountAsLoudAsPositive) {
  std::vector<float> samples(480, 0.0f);
  samples[10] = -1.0f;
  const MicrophoneLevel level =
      ComputeMicrophoneLevel(samples.data(), samples.size());

  EXPECT_DOUBLE_EQ(level.linear, 1.0);
}

TEST(MicrophoneLevelTest, NaNDoesNotPoisonThePeak) {
  // Drivers emit NaN after a glitch. The peak comparison is written so NaN
  // falls out (every comparison with NaN is false), but that is a property of
  // HOW the loop is written, not of the type -- switching to RMS, or to a
  // max() with the NaN on the left, would propagate it through the buffer and
  // the meter would read NaN for a live microphone. This pins the behavior.
  std::vector<float> samples(480, 0.0f);
  samples[5] = std::numeric_limits<float>::quiet_NaN();
  samples[6] = 0.25f;  // -12 dBFS, the real peak
  const MicrophoneLevel level =
      ComputeMicrophoneLevel(samples.data(), samples.size());

  EXPECT_FALSE(std::isnan(level.linear));
  EXPECT_FALSE(std::isnan(level.dbfs));
  EXPECT_NEAR(level.dbfs, -12.04, 0.01);
}

TEST(MicrophoneLevelTest, EmptyOrNullBufferReportsSilenceNotAWarning) {
  // A capture client handing back an empty buffer is routine, not a fault.
  const MicrophoneLevel from_null = ComputeMicrophoneLevel(nullptr, 0);
  EXPECT_DOUBLE_EQ(from_null.dbfs, kMicLevelSilenceDbfs);
  EXPECT_FALSE(from_null.is_low);

  const std::vector<float> empty;
  const MicrophoneLevel from_empty = ComputeMicrophoneLevel(empty.data(), 0);
  EXPECT_FALSE(from_empty.is_low);
}

TEST(MicrophoneLevelTest, TheStopSentinelNeverWarns) {
  // Emitted when the monitor stops or the user deselects the microphone.
  // Warning then would fire on every launch and train the warning away.
  const MicrophoneLevel level = SilentMicrophoneLevel();

  EXPECT_DOUBLE_EQ(level.linear, 0.0);
  EXPECT_DOUBLE_EQ(level.dbfs, kMicLevelSilenceDbfs);
  EXPECT_FALSE(level.is_low);
}

// --- Cadence -----------------------------------------------------------
//
// The accumulator exists so this half is testable at all: the CI runner has
// no audio endpoint, so anything living inside the WASAPI monitor cannot be
// exercised. Driven here with an explicit clock.

using Clock = std::chrono::steady_clock;

// A tick short enough to be clearly inside one emit window.
constexpr auto kTick = std::chrono::milliseconds(10);

TEST(MicrophoneLevelAccumulatorTest, FirstReadingIsImmediate) {
  // The meter must come alive when the user picks a microphone, not a frame
  // later. With no deadline set yet, the first due-check emits.
  MicrophoneLevelAccumulator accumulator;
  const auto buffer = BufferWithPeak(0.5f);
  accumulator.Add(buffer.data(), buffer.size());

  const auto level = accumulator.TakeIfDue(Clock::time_point{});
  ASSERT_TRUE(level.has_value());
  EXPECT_NEAR(level->dbfs, -6.02, 0.01);
}

TEST(MicrophoneLevelAccumulatorTest, HoldsBackUntilTheIntervalElapses) {
  MicrophoneLevelAccumulator accumulator(std::chrono::milliseconds(100));
  const Clock::time_point start{};

  ASSERT_TRUE(accumulator.TakeIfDue(start).has_value());
  EXPECT_FALSE(accumulator.TakeIfDue(start + kTick).has_value());
  EXPECT_FALSE(accumulator.TakeIfDue(start + std::chrono::milliseconds(99))
                   .has_value());
  EXPECT_TRUE(accumulator.TakeIfDue(start + std::chrono::milliseconds(100))
                  .has_value());
}

TEST(MicrophoneLevelAccumulatorTest, ReportsTheWindowPeakNotTheLastBuffer) {
  // ~7 WASAPI packets land per 66 ms window. If only the last one counted,
  // the meter would miss most transients and sag between syllables.
  MicrophoneLevelAccumulator accumulator(std::chrono::milliseconds(100));
  const Clock::time_point start{};
  ASSERT_TRUE(accumulator.TakeIfDue(start).has_value());  // arm the schedule

  const auto quiet = BufferWithPeak(0.01f);
  const auto loud = BufferWithPeak(0.8f);
  accumulator.Add(quiet.data(), quiet.size());
  accumulator.Add(loud.data(), loud.size());
  accumulator.Add(quiet.data(), quiet.size());  // loud one is NOT last

  const auto level = accumulator.TakeIfDue(start + std::chrono::milliseconds(100));
  ASSERT_TRUE(level.has_value());
  EXPECT_NEAR(level->linear, 0.8, 0.001);
}

TEST(MicrophoneLevelAccumulatorTest, EachWindowStartsFromZero) {
  // Without the reset, one loud moment would pin the meter high forever.
  MicrophoneLevelAccumulator accumulator(std::chrono::milliseconds(100));
  const Clock::time_point start{};
  ASSERT_TRUE(accumulator.TakeIfDue(start).has_value());

  const auto loud = BufferWithPeak(0.9f);
  accumulator.Add(loud.data(), loud.size());
  ASSERT_TRUE(accumulator.TakeIfDue(start + std::chrono::milliseconds(100))
                  .has_value());

  const auto quiet = BufferWithPeak(0.001f);
  accumulator.Add(quiet.data(), quiet.size());
  const auto second =
      accumulator.TakeIfDue(start + std::chrono::milliseconds(200));
  ASSERT_TRUE(second.has_value());
  EXPECT_NEAR(second->linear, 0.001, 0.0001);
}

TEST(MicrophoneLevelAccumulatorTest, AWindowWithNoAudioReportsSilenceAndWarns) {
  // This is the whole point. A microphone that delivers nothing must not
  // freeze the meter at its last value -- it must fall to the floor and trip
  // the quiet-input warning, same as macOS.
  MicrophoneLevelAccumulator accumulator(std::chrono::milliseconds(100));
  const Clock::time_point start{};

  const auto loud = BufferWithPeak(0.9f);
  accumulator.Add(loud.data(), loud.size());
  ASSERT_TRUE(accumulator.TakeIfDue(start).has_value());

  const auto starved =
      accumulator.TakeIfDue(start + std::chrono::milliseconds(100));
  ASSERT_TRUE(starved.has_value());
  EXPECT_DOUBLE_EQ(starved->linear, 0.0);
  EXPECT_DOUBLE_EQ(starved->dbfs, kMicLevelSilenceDbfs);
  EXPECT_TRUE(starved->is_low);
}

TEST(MicrophoneLevelAccumulatorTest, AStallDoesNotFireABurstOfBackdatedEvents) {
  // Scheduling from the previous deadline would owe ~15 emits after a 1 s
  // stall and deliver them back to back, all carrying the same stale peak.
  // Scheduling from now drops the missed windows instead.
  MicrophoneLevelAccumulator accumulator(std::chrono::milliseconds(100));
  const Clock::time_point start{};
  ASSERT_TRUE(accumulator.TakeIfDue(start).has_value());

  const auto stalled = start + std::chrono::seconds(1);
  EXPECT_TRUE(accumulator.TakeIfDue(stalled).has_value());
  EXPECT_FALSE(accumulator.TakeIfDue(stalled).has_value());
  EXPECT_FALSE(
      accumulator.TakeIfDue(stalled + std::chrono::milliseconds(50))
          .has_value());
  EXPECT_TRUE(accumulator.TakeIfDue(stalled + std::chrono::milliseconds(100))
                  .has_value());
}

TEST(MicrophoneLevelAccumulatorTest, ResetMakesTheNextReadingImmediate) {
  // Switching device mid-session must not show the old device's peak, nor
  // wait out a window before the new one appears.
  MicrophoneLevelAccumulator accumulator(std::chrono::milliseconds(100));
  const Clock::time_point start{};
  const auto loud = BufferWithPeak(0.9f);
  accumulator.Add(loud.data(), loud.size());
  ASSERT_TRUE(accumulator.TakeIfDue(start).has_value());
  accumulator.Add(loud.data(), loud.size());

  accumulator.Reset();

  const auto level = accumulator.TakeIfDue(start + kTick);
  ASSERT_TRUE(level.has_value());
  EXPECT_DOUBLE_EQ(level->linear, 0.0);
}

TEST(MicrophoneLevelAccumulatorTest, DefaultIntervalMatchesMacOSFifteenHertz) {
  // macOS emits at 1.0/15.0 s. A different rate here means the same voice
  // animates the same meter at a different speed per platform.
  EXPECT_NEAR(
      std::chrono::duration<double>(kMicLevelEmitInterval).count(),
      1.0 / 15.0, 0.0005);

  MicrophoneLevelAccumulator accumulator;
  const Clock::time_point start{};
  ASSERT_TRUE(accumulator.TakeIfDue(start).has_value());
  EXPECT_FALSE(accumulator.TakeIfDue(start + std::chrono::milliseconds(60))
                   .has_value());
  EXPECT_TRUE(accumulator.TakeIfDue(start + std::chrono::milliseconds(67))
                  .has_value());
}

}  // namespace
}  // namespace clingfy::audio
