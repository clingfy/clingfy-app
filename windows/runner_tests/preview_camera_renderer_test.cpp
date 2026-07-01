#include "Preview/preview_camera_renderer.h"

#include <gtest/gtest.h>

namespace clingfy::preview {
namespace {

constexpr std::int64_t kThresh = kPreviewCameraSeekThresholdHns;  // 1s in hns

// --- cold start (no held frame yet) ---

TEST(PreviewCameraSeekTest, ColdStartNearZeroDoesNotSeek) {
  // Opening at/near the camera start: decode from the file start (cheap), no seek.
  EXPECT_FALSE(PreviewCameraShouldSeek(0, -1, false));
  EXPECT_FALSE(PreviewCameraShouldSeek(kThresh, -1, false));
}

TEST(PreviewCameraSeekTest, ColdStartFarInSeeks) {
  // Opening the preview already scrubbed deep into the clip → seek.
  EXPECT_TRUE(PreviewCameraShouldSeek(kThresh + 1, -1, false));
  EXPECT_TRUE(PreviewCameraShouldSeek(60'000'000, -1, false));  // 6s in
}

// --- normal playback (held frame present) ---

TEST(PreviewCameraSeekTest, SmallForwardStepPullsForward) {
  // 33 ms (one ~30fps frame) ahead of the held frame → pull, don't seek.
  EXPECT_FALSE(PreviewCameraShouldSeek(330'000 + 100'000, 100'000, true));
}

TEST(PreviewCameraSeekTest, BackwardJumpSeeks) {
  // Any backward move (scrub left) → seek; can't rewind a forward-only reader.
  EXPECT_TRUE(PreviewCameraShouldSeek(50'000, 5'000'000, true));
}

TEST(PreviewCameraSeekTest, LargeForwardJumpSeeks) {
  // Scrub forward beyond the threshold → seek instead of decoding every frame.
  EXPECT_TRUE(PreviewCameraShouldSeek(5'000'000 + kThresh + 1, 5'000'000, true));
}

TEST(PreviewCameraSeekTest, ForwardJustUnderThresholdPullsForward) {
  EXPECT_FALSE(
      PreviewCameraShouldSeek(5'000'000 + kThresh, 5'000'000, true));
}

}  // namespace
}  // namespace clingfy::preview
