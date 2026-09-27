#include "Audio/microphone_level_monitor.h"

#include <gtest/gtest.h>

#include <cstddef>
#include <optional>
#include <string>
#include <vector>

// The monitor's POLICY and its idle lifecycle.
//
// What is deliberately not here: anything that needs a live WASAPI endpoint.
// The CI runner has no microphone, and a test that opens the default input
// would pass or fail depending on the machine. The capture-driven half is
// covered by `MicrophoneLevelAccumulatorTest` (the cadence, with a fake
// clock) and by on-device QA; what is left -- when to run at all -- is pure
// and belongs here.
namespace clingfy::audio {
namespace {

TEST(ShouldMonitorMicrophoneLevelTest, RunsWhenAMicrophoneIsSelectedAndIdle) {
  EXPECT_TRUE(ShouldMonitorMicrophoneLevel(std::optional<std::string>("mic-1"),
                                           /*recording=*/false));
}

TEST(ShouldMonitorMicrophoneLevelTest, StaysOffWithNoSelection) {
  // The default state at launch. Running here would open the default input
  // -- lighting the OS microphone-in-use indicator for a user who never
  // asked to record audio.
  EXPECT_FALSE(
      ShouldMonitorMicrophoneLevel(std::nullopt, /*recording=*/false));
}

TEST(ShouldMonitorMicrophoneLevelTest, TreatsAnEmptyIdAsNoSelection) {
  // `ReadOptionalString` maps "" to nullopt, but selection state can still
  // hold an empty string, and an empty device id means "default endpoint" to
  // WASAPI -- so this must be rejected here or clearing the selection would
  // silently meter the default microphone instead.
  EXPECT_FALSE(ShouldMonitorMicrophoneLevel(std::optional<std::string>(""),
                                            /*recording=*/false));
}

TEST(ShouldMonitorMicrophoneLevelTest, StaysOffWhileRecording) {
  EXPECT_FALSE(ShouldMonitorMicrophoneLevel(std::optional<std::string>("mic-1"),
                                            /*recording=*/true));
}

TEST(ShouldMonitorMicrophoneLevelTest, RecordingBeatsASelection) {
  // Ordering-independence: the reconcile is asynchronous and a device change
  // can land after a recording has started. Recording has to dominate, or a
  // late reconcile would open a second client on the endpoint mid-take.
  for (const char* id : {"mic-1", "mic-2", ""}) {
    EXPECT_FALSE(ShouldMonitorMicrophoneLevel(std::optional<std::string>(id),
                                              /*recording=*/true))
        << "id=" << id;
  }
}

// --- Idle lifecycle ----------------------------------------------------

class MicrophoneLevelMonitorTest : public ::testing::Test {
 protected:
  void SetUp() override {
    MicrophoneLevelMonitor::Instance().SetEmitterForTesting(
        [this](const MicrophoneLevel& level) { emitted_.push_back(level); });
  }

  void TearDown() override {
    MicrophoneLevelMonitor::Instance().Stop(/*emit_silence=*/false);
    MicrophoneLevelMonitor::Instance().SetEmitterForTesting(nullptr);
  }

  std::vector<MicrophoneLevel> emitted_;
};

TEST_F(MicrophoneLevelMonitorTest, ApplyWithNoSelectionLeavesItStopped) {
  MicrophoneLevelMonitor::Instance().Apply(std::nullopt, /*recording=*/false);

  EXPECT_FALSE(MicrophoneLevelMonitor::Instance().running());
  EXPECT_TRUE(MicrophoneLevelMonitor::Instance().device_id().empty());
}

TEST_F(MicrophoneLevelMonitorTest, StoppingAnIdleMonitorEmitsNothing) {
  // Called on every launch and on every recording teardown. If it pushed a
  // reading, the meter would twitch to zero at moments nothing happened, and
  // Dart would rebuild for it.
  MicrophoneLevelMonitor::Instance().Stop(/*emit_silence=*/true);
  MicrophoneLevelMonitor::Instance().Apply(std::nullopt, /*recording=*/false);

  EXPECT_TRUE(emitted_.empty());
}

TEST_F(MicrophoneLevelMonitorTest, ApplyWhileRecordingDoesNotOpenAnEndpoint) {
  MicrophoneLevelMonitor::Instance().Apply(std::optional<std::string>("mic-1"),
                                           /*recording=*/true);

  EXPECT_FALSE(MicrophoneLevelMonitor::Instance().running());
}

TEST_F(MicrophoneLevelMonitorTest, StopIsIdempotent) {
  for (int i = 0; i < 3; ++i) {
    MicrophoneLevelMonitor::Instance().Stop(/*emit_silence=*/true);
  }
  EXPECT_FALSE(MicrophoneLevelMonitor::Instance().running());
  EXPECT_TRUE(emitted_.empty());
}

TEST_F(MicrophoneLevelMonitorTest, StartThenStopTearsDownCleanlyAndZeroesTheMeter) {
  // Runs both ways on purpose, because the outcome of Start depends on the
  // machine and the assertions below do not.
  //
  // A device id that resolves to nothing does NOT fail: `OpenDevice` falls
  // back to the default capture endpoint on an unresolvable or UNPLUGGED id
  // (wasapi_audio_capture.cpp, the comment above the GetDevice call). That is
  // the right behavior to inherit here rather than special-case -- the meter
  // should read whatever the recording would actually capture, and the
  // recording takes the same fallback. So on a box with a microphone this
  // starts; on the CI runner, with no endpoint at all, it does not.
  MicrophoneLevelMonitor::Instance().Apply(
      std::optional<std::string>("{not-a-real-endpoint-id}"),
      /*recording=*/false);
  const bool opened = MicrophoneLevelMonitor::Instance().running();

  MicrophoneLevelMonitor::Instance().Stop(/*emit_silence=*/true);

  EXPECT_FALSE(MicrophoneLevelMonitor::Instance().running());
  EXPECT_TRUE(MicrophoneLevelMonitor::Instance().device_id().empty());

  // Either way the meter must end at the floor without claiming the input is
  // too quiet: stopping is not a quiet microphone, and a failure to open is
  // not a reading at all.
  ASSERT_FALSE(emitted_.empty());
  EXPECT_DOUBLE_EQ(emitted_.back().linear, 0.0);
  EXPECT_DOUBLE_EQ(emitted_.back().dbfs, kMicLevelSilenceDbfs);
  EXPECT_FALSE(emitted_.back().is_low);

  if (!opened) {
    // No endpoint: exactly one reading, from the failed open. Nothing should
    // have been sampled, and Stop on a monitor that never ran adds nothing.
    EXPECT_EQ(emitted_.size(), 1u);
  }
}

TEST_F(MicrophoneLevelMonitorTest, ReapplyingTheSameDeviceDoesNotRestartIt) {
  // The UI re-sends `setAudioSource` freely. Tearing the endpoint down and
  // reopening it on each one would drop the meter to zero every time and,
  // on Realtek-class drivers, audibly click the input.
  MicrophoneLevelMonitor::Instance().Apply(std::optional<std::string>("mic-x"),
                                           /*recording=*/false);
  if (!MicrophoneLevelMonitor::Instance().running()) {
    GTEST_SKIP() << "no capture endpoint on this machine";
  }
  const std::size_t after_first = emitted_.size();

  for (int i = 0; i < 3; ++i) {
    MicrophoneLevelMonitor::Instance().Apply(
        std::optional<std::string>("mic-x"), /*recording=*/false);
  }

  EXPECT_TRUE(MicrophoneLevelMonitor::Instance().running());
  EXPECT_EQ(MicrophoneLevelMonitor::Instance().device_id(), "mic-x");
  // A restart would have pushed a silence through Stop's emit path.
  EXPECT_GE(emitted_.size(), after_first);
}

}  // namespace
}  // namespace clingfy::audio
