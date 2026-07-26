#include "Capture/Background/background_image_cache.h"

#include <gtest/gtest.h>

namespace clingfy::capture::background {
namespace {

using export_::SizeF;

// A background fills the canvas like a wallpaper: scaled to COVER, centred,
// overflow cropped. That is deliberately NOT how the video is placed (fit /
// letterboxed inside the padded content rect), so these cases pin the
// difference.

TEST(BackgroundCoverTest, WiderImageCropsHorizontallyAndKeepsFullHeight) {
  // 4000x2000 (2:1) into 1280x720 (16:9). The image is relatively wider, so
  // height is the binding axis: full height visible, width cropped.
  const auto src = ComputeCoverSourceRect(SizeF{4000.0, 2000.0},
                                          SizeF{1280.0, 720.0});
  EXPECT_DOUBLE_EQ(src.y, 0.0);
  EXPECT_DOUBLE_EQ(src.height, 2000.0);
  EXPECT_LT(src.width, 4000.0);
  // Centred: equal crop either side.
  EXPECT_DOUBLE_EQ(src.x, (4000.0 - src.width) * 0.5);
}

TEST(BackgroundCoverTest, TallerImageCropsVerticallyAndKeepsFullWidth) {
  // 1000x4000 into 1280x720: width is the binding axis.
  const auto src = ComputeCoverSourceRect(SizeF{1000.0, 4000.0},
                                          SizeF{1280.0, 720.0});
  EXPECT_DOUBLE_EQ(src.x, 0.0);
  EXPECT_DOUBLE_EQ(src.width, 1000.0);
  EXPECT_LT(src.height, 4000.0);
  EXPECT_DOUBLE_EQ(src.y, (4000.0 - src.height) * 0.5);
}

TEST(BackgroundCoverTest, MatchingAspectUsesTheWholeImage) {
  const auto src = ComputeCoverSourceRect(SizeF{1920.0, 1080.0},
                                          SizeF{1280.0, 720.0});
  EXPECT_DOUBLE_EQ(src.x, 0.0);
  EXPECT_DOUBLE_EQ(src.y, 0.0);
  EXPECT_DOUBLE_EQ(src.width, 1920.0);
  EXPECT_DOUBLE_EQ(src.height, 1080.0);
}

// Cover must never leave a gap: the visible source, scaled up, always covers
// the canvas on both axes. This is the property that distinguishes it from fit.
TEST(BackgroundCoverTest, NeverLeavesAGapOnEitherAxis) {
  const SizeF canvas{1280.0, 720.0};
  const SizeF images[] = {{4000.0, 2000.0}, {1000.0, 4000.0},
                          {100.0, 100.0},   {5000.0, 10.0},
                          {10.0, 5000.0}};
  for (const auto& img : images) {
    const auto src = ComputeCoverSourceRect(img, canvas);
    ASSERT_GT(src.width, 0.0);
    ASSERT_GT(src.height, 0.0);
    // The visible window has (at least) the canvas aspect, so scaling it to the
    // canvas fills both axes.
    const double src_aspect = src.width / src.height;
    const double canvas_aspect = canvas.width / canvas.height;
    EXPECT_NEAR(src_aspect, canvas_aspect, 1e-6)
        << "visible source must match canvas aspect, else it gaps or distorts";
    // And it stays inside the image.
    EXPECT_GE(src.x, -1e-9);
    EXPECT_GE(src.y, -1e-9);
    EXPECT_LE(src.x + src.width, img.width + 1e-9);
    EXPECT_LE(src.y + src.height, img.height + 1e-9);
  }
}

// A caller that skipped validation must still draw something rather than
// nothing — a degenerate rect would make the background silently vanish.
TEST(BackgroundCoverTest, DegenerateInputsFallBackToTheFullImage) {
  const auto zero_canvas =
      ComputeCoverSourceRect(SizeF{100.0, 50.0}, SizeF{0.0, 0.0});
  EXPECT_DOUBLE_EQ(zero_canvas.width, 100.0);
  EXPECT_DOUBLE_EQ(zero_canvas.height, 50.0);

  const auto zero_image =
      ComputeCoverSourceRect(SizeF{0.0, 0.0}, SizeF{1280.0, 720.0});
  EXPECT_DOUBLE_EQ(zero_image.width, 0.0);

  const auto negative =
      ComputeCoverSourceRect(SizeF{-10.0, -10.0}, SizeF{1280.0, 720.0});
  EXPECT_DOUBLE_EQ(negative.x, 0.0);
  EXPECT_DOUBLE_EQ(negative.y, 0.0);
}

// The cache is keyed on (path, last-write-time). An empty path clears it, which
// is how "user removed the background" reaches the renderer.
TEST(BackgroundImageCacheTest, EmptyPathClearsAndReturnsNull) {
  BackgroundImageCache cache;
  EXPECT_EQ(cache.Get(nullptr, L""), nullptr);
  EXPECT_EQ(cache.decode_count(), 0)
      << "an empty path must not attempt a decode";
}

// A missing file must not be retried on every frame — the null result is cached
// too. Without this, a deleted background would hammer the disk at playback rate.
TEST(BackgroundImageCacheTest, MissingFileDecodesOnceNotPerCall) {
  BackgroundImageCache cache;
  const std::wstring missing = L"X:\\definitely\\not\\here\\bg.png";
  EXPECT_EQ(cache.Get(nullptr, missing), nullptr);
  const std::int64_t after_first = cache.decode_count();
  EXPECT_EQ(cache.Get(nullptr, missing), nullptr);
  EXPECT_EQ(cache.Get(nullptr, missing), nullptr);
  EXPECT_EQ(cache.decode_count(), after_first)
      << "a missing file must be cached as null, not re-decoded every frame";
}

TEST(BackgroundImageCacheTest, ResetClearsSoDeviceLossCannotReuseAStaleBitmap) {
  BackgroundImageCache cache;
  const std::wstring missing = L"X:\\definitely\\not\\here\\bg.png";
  cache.Get(nullptr, missing);
  const std::int64_t before = cache.decode_count();
  cache.Reset();
  // After a reset the next Get must go back through decode rather than hand
  // back a bitmap that belonged to the destroyed device context.
  cache.Get(nullptr, missing);
  EXPECT_GT(cache.decode_count(), before);
}

TEST(BackgroundImageCacheTest, WriteTimeOfMissingFileIsZero) {
  EXPECT_EQ(FileWriteTime(L""), 0);
  EXPECT_EQ(FileWriteTime(L"X:\\definitely\\not\\here\\bg.png"), 0);
}

}  // namespace
}  // namespace clingfy::capture::background
