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

// --- effect scale: export-canvas lengths resolved onto the preview texture ---

TEST(PreviewCameraEffectScaleTest, IsTheShortSideRatio) {
  // youtube169 @ p2160: export 3840x2160, preview texture 1280x720.
  EXPECT_NEAR(PreviewCameraEffectScale(720.0, 2160.0), 1.0 / 3.0, 1e-12);
  // reel916 @ p1080: export 1080x1920 (short 1080), preview 404x720 (short 404).
  EXPECT_NEAR(PreviewCameraEffectScale(404.0, 1080.0), 404.0 / 1080.0, 1e-12);
  // Same surface as the export => identity, which is what the export path gets.
  EXPECT_DOUBLE_EQ(PreviewCameraEffectScale(2160.0, 2160.0), 1.0);
}

TEST(PreviewCameraEffectScaleTest, UnknownReferenceFallsBackToIdentityNotZero) {
  // The export size is unknown until the first decoded frame. Falling back to 0
  // would erase the border and collapse the shadow for those frames; identity
  // reproduces the previous appearance until the real size lands. This is the
  // one place the camera scale deliberately differs from
  // core::NormalizeToShortSide, which soft-fails to 0.
  EXPECT_DOUBLE_EQ(PreviewCameraEffectScale(720.0, 0.0), 1.0);
  EXPECT_DOUBLE_EQ(PreviewCameraEffectScale(720.0, -2160.0), 1.0);
  EXPECT_DOUBLE_EQ(PreviewCameraEffectScale(0.0, 2160.0), 1.0);
  EXPECT_DOUBLE_EQ(PreviewCameraEffectScale(-1.0, 2160.0), 1.0);
}

TEST(PreviewCameraNeedsRebuildTest, ScaleOnlyChangeStillRebuilds) {
  // The regression this term exists for: the canvas is identical and nothing is
  // dirty, but the export size resolved a frame late. Without the scale term
  // the painter keeps its identity-scaled border for the whole session.
  EXPECT_TRUE(PreviewCameraNeedsRebuild(/*dirty=*/false, 1280, 720,
                                        /*effect_scale=*/1.0 / 3.0, 1280, 720,
                                        /*prepared_effect_scale=*/1.0,
                                        /*painter_ready=*/true));
}

TEST(PreviewCameraNeedsRebuildTest, SteadyStateDoesNotRebuild) {
  // painter_ready MUST be true here: it is the only EXPECT_FALSE in this
  // group, so passing false would invert the assertion and still compile.
  EXPECT_FALSE(PreviewCameraNeedsRebuild(false, 1280, 720, 1.0 / 3.0, 1280, 720,
                                         1.0 / 3.0, /*painter_ready=*/true));
}

TEST(PreviewCameraNeedsRebuildTest, DirtyOrCanvasChangeStillRebuilds) {
  EXPECT_TRUE(PreviewCameraNeedsRebuild(true, 1280, 720, 1.0, 1280, 720, 1.0,
                                        /*painter_ready=*/true));
  EXPECT_TRUE(PreviewCameraNeedsRebuild(false, 640, 720, 1.0, 1280, 720, 1.0,
                                        /*painter_ready=*/true));
  EXPECT_TRUE(PreviewCameraNeedsRebuild(false, 1280, 360, 1.0, 1280, 720, 1.0,
                                        /*painter_ready=*/true));
}

// The retry path, which no test could reach while the term lived at the call
// site. This is the exact post-failure state: the rebuild ran, the painter
// failed to build, and the prepared_* values were recorded anyway — so dirty is
// false, the canvas matches and the scale matches. Every other term reads
// false. Only painter_ready asks for the retry, and without it the camera
// silently never draws again for the rest of the session.
TEST(PreviewCameraNeedsRebuildTest, NotReadyRetriesAfterAFailedRebuild) {
  EXPECT_TRUE(PreviewCameraNeedsRebuild(/*dirty=*/false, 1280, 720,
                                        /*effect_scale=*/1.0 / 3.0, 1280, 720,
                                        /*prepared_effect_scale=*/1.0 / 3.0,
                                        /*painter_ready=*/false));
}

// The other side of the same term: once the painter IS ready and nothing else
// changed, the retry must stop. Otherwise the recovery path becomes an
// every-frame shadow bake — the rebuild branch does SetTarget round-trips, so
// re-entering it per frame is expensive, not merely redundant.
TEST(PreviewCameraNeedsRebuildTest, ReadySteadyStateStopsRetrying) {
  EXPECT_FALSE(PreviewCameraNeedsRebuild(/*dirty=*/false, 1280, 720,
                                         /*effect_scale=*/1.0, 1280, 720,
                                         /*prepared_effect_scale=*/1.0,
                                         /*painter_ready=*/true));
}

}  // namespace
}  // namespace clingfy::preview
