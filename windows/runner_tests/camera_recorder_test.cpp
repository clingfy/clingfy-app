#include "Capture/Camera/camera_recorder.h"

#include <gtest/gtest.h>

#include <cstdint>
#include <memory>

#include "Capture/recording_clock.h"

// CameraRecorder's device I/O needs a real camera, so it is smoke-tested by
// hand. What IS unit-testable — and is the heart of the sync contract — is the
// frame timestamp logic: rebasing pause-aware clock time to the first frame and
// keeping output timestamps strictly increasing. These tests pin that.
namespace clingfy::capture {
namespace {

constexpr std::int64_t kHns = 10'000'000;  // 100-ns units per second.

TEST(CameraRecorderTimestampTest, FirstFrameRebasesToZero) {
  std::int64_t first = -1;
  std::int64_t last = -1;
  // First frame arrives 150ms into the recording → file time 0.
  const std::int64_t t0 =
      CameraRecorder::NextSampleTimeHns(150 * kHns / 1000, first, last);
  EXPECT_EQ(t0, 0);
  EXPECT_EQ(first, 150 * kHns / 1000);
}

TEST(CameraRecorderTimestampTest, SubsequentFramesAreRelativeToFirst) {
  std::int64_t first = -1;
  std::int64_t last = -1;
  CameraRecorder::NextSampleTimeHns(150 * kHns / 1000, first, last);  // -> 0
  const std::int64_t t1 =
      CameraRecorder::NextSampleTimeHns(183 * kHns / 1000, first, last);
  EXPECT_EQ(t1, 33 * kHns / 1000);  // 183 - 150 = 33ms.
}

TEST(CameraRecorderTimestampTest, EnforcesStrictlyIncreasingTimestamps) {
  std::int64_t first = -1;
  std::int64_t last = -1;
  CameraRecorder::NextSampleTimeHns(1000, first, last);          // -> 0
  const std::int64_t a = CameraRecorder::NextSampleTimeHns(1500, first, last);
  const std::int64_t b = CameraRecorder::NextSampleTimeHns(1500, first, last);
  EXPECT_EQ(a, 500);
  EXPECT_EQ(b, 501) << "a tied input time must be bumped to stay monotonic";
}

// The camera stamps frames with its pause-aware RecordingClock. This proves the
// paused interval is excluded — feeding the resulting clock times through the
// rebase produces no wall-clock gap across a pause.
TEST(CameraRecorderTimestampTest, PauseResumeExcludesPausedTimeFromStamps) {
  // 1 tick == 1 hundred-ns so clock math is transparent.
  auto counter = std::make_shared<std::int64_t>(0);
  RecordingClock clock([counter]() { return *counter; },
                       /*qpc_frequency=*/kHns);
  clock.MarkStart();  // start at tick 0.

  std::int64_t first = -1;
  std::int64_t last = -1;

  // 100ms in, first frame.
  *counter = 100 * kHns / 1000;
  const std::int64_t f0 =
      CameraRecorder::NextSampleTimeHns(clock.ElapsedHns(), first, last);
  EXPECT_EQ(f0, 0);

  // Pause, let 500ms of wall-clock elapse while paused.
  clock.Pause();
  *counter = 600 * kHns / 1000;
  clock.Resume();

  // 100ms after resume → 200ms of RECORDING time total (the 500ms pause is
  // excluded), so 100ms past the first frame.
  *counter = 700 * kHns / 1000;
  const std::int64_t f1 =
      CameraRecorder::NextSampleTimeHns(clock.ElapsedHns(), first, last);
  EXPECT_EQ(f1, 100 * kHns / 1000)
      << "the 500ms pause must NOT appear as a gap in camera timestamps";
}

}  // namespace
}  // namespace clingfy::capture
