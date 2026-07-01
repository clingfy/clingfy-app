#include "Capture/Camera/camera_preview_support.h"

#include <gtest/gtest.h>

#include <cstdint>
#include <vector>

namespace clingfy::capture {
namespace {

// ---- ComputePreviewSize ----------------------------------------------------

TEST(CameraPreviewSupportTest, PreviewSizeKeepsSmallSourceUnscaled) {
  const auto s = ComputePreviewSize(320, 240, 384);
  EXPECT_EQ(s.width, 320);
  EXPECT_EQ(s.height, 240);
}

TEST(CameraPreviewSupportTest, PreviewSizeDownscalesPreservingAspect) {
  const auto s = ComputePreviewSize(1280, 720, 384);
  EXPECT_EQ(s.width, 384);
  EXPECT_EQ(s.height, 216);  // 720 * 384/1280 = 216
}

TEST(CameraPreviewSupportTest, PreviewSizeRejectsBadInput) {
  EXPECT_EQ(ComputePreviewSize(0, 100, 384).width, 0);
  EXPECT_EQ(ComputePreviewSize(100, 0, 384).height, 0);
  EXPECT_EQ(ComputePreviewSize(100, 100, 0).width, 0);
}

// ---- ConvertToBgra ---------------------------------------------------------

TEST(CameraPreviewSupportTest, Nv12BlackConvertsToBlack) {
  // 2x2 NV12: Y plane all 16 (black luma), UV all 128 (neutral chroma).
  std::vector<std::uint8_t> nv12 = {16, 16, 16, 16, /*UV*/ 128, 128};
  std::vector<std::uint8_t> bgra(2 * 2 * 4, 0xAB);
  ASSERT_TRUE(ConvertToBgra(CameraPixelFormat::kNv12, nv12.data(), 2, 2,
                            /*src_stride=*/2, bgra.data(), 2, 2));
  for (int i = 0; i < 4; ++i) {
    EXPECT_LE(bgra[i * 4 + 0], 2);  // B ~0
    EXPECT_LE(bgra[i * 4 + 1], 2);  // G ~0
    EXPECT_LE(bgra[i * 4 + 2], 2);  // R ~0
    EXPECT_EQ(bgra[i * 4 + 3], 255);
  }
}

TEST(CameraPreviewSupportTest, Nv12WhiteConvertsToWhite) {
  // Y = 235 (white luma), UV neutral.
  std::vector<std::uint8_t> nv12 = {235, 235, 235, 235, 128, 128};
  std::vector<std::uint8_t> bgra(2 * 2 * 4, 0);
  ASSERT_TRUE(ConvertToBgra(CameraPixelFormat::kNv12, nv12.data(), 2, 2, 2,
                            bgra.data(), 2, 2));
  for (int i = 0; i < 4; ++i) {
    EXPECT_GE(bgra[i * 4 + 0], 250);
    EXPECT_GE(bgra[i * 4 + 1], 250);
    EXPECT_GE(bgra[i * 4 + 2], 250);
    EXPECT_EQ(bgra[i * 4 + 3], 255);
  }
}

TEST(CameraPreviewSupportTest, Bgra32PassthroughForcesOpaqueAlpha) {
  // 1x1 BGRA with a transparent alpha — output must be opaque, channels kept.
  std::vector<std::uint8_t> src = {10, 20, 30, 40};
  std::vector<std::uint8_t> dst(4, 0);
  ASSERT_TRUE(ConvertToBgra(CameraPixelFormat::kBgra32, src.data(), 1, 1,
                            /*src_stride=*/4, dst.data(), 1, 1));
  EXPECT_EQ(dst[0], 10);
  EXPECT_EQ(dst[1], 20);
  EXPECT_EQ(dst[2], 30);
  EXPECT_EQ(dst[3], 255);
}

TEST(CameraPreviewSupportTest, Bgra32DownscalePicksNearest) {
  // 2x1 BGRA: left red-ish, right blue-ish. Downscale to 1x1 -> nearest (left).
  std::vector<std::uint8_t> src = {1, 2, 3, 255, 9, 9, 9, 255};
  std::vector<std::uint8_t> dst(4, 0);
  ASSERT_TRUE(ConvertToBgra(CameraPixelFormat::kBgra32, src.data(), 2, 1,
                            /*src_stride=*/8, dst.data(), 1, 1));
  EXPECT_EQ(dst[0], 1);
  EXPECT_EQ(dst[1], 2);
  EXPECT_EQ(dst[2], 3);
}

TEST(CameraPreviewSupportTest, ConvertRejectsBadArgs) {
  std::vector<std::uint8_t> buf(16, 0);
  EXPECT_FALSE(ConvertToBgra(CameraPixelFormat::kNv12, nullptr, 2, 2, 2,
                             buf.data(), 2, 2));
  EXPECT_FALSE(ConvertToBgra(CameraPixelFormat::kNv12, buf.data(), 0, 2, 2,
                             buf.data(), 2, 2));
  EXPECT_FALSE(ConvertToBgra(CameraPixelFormat::kNv12, buf.data(), 2, 2, 2,
                             buf.data(), 2, 0));
}

}  // namespace
}  // namespace clingfy::capture
