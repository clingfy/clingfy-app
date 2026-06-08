#include "Capture/Camera/live_camera_texture.h"

#include <gtest/gtest.h>

#include <cstdint>
#include <vector>

// The LiveCameraTexture registrar path needs a real Flutter texture registrar,
// so it's smoke-tested. The pure, testable part is the BGRA->RGBA swizzle that
// feeds Flutter's pixel buffer (Flutter wants RGBA; camera frames are BGRA).
namespace clingfy::capture {
namespace {

TEST(LiveCameraTextureTest, SwizzleSwapsRedAndBlueKeepsAlpha) {
  // One pixel, BGRA = (B=10, G=20, R=30, A=40) -> RGBA = (30, 20, 10, 40).
  std::vector<std::uint8_t> bgra = {10, 20, 30, 40};
  std::vector<std::uint8_t> rgba(4, 0);
  LiveCameraTexture::SwizzleBgraToRgba(bgra.data(), 1, 1, rgba.data());
  EXPECT_EQ(rgba[0], 30);  // R
  EXPECT_EQ(rgba[1], 20);  // G
  EXPECT_EQ(rgba[2], 10);  // B
  EXPECT_EQ(rgba[3], 40);  // A
}

TEST(LiveCameraTextureTest, SwizzleHandlesMultiplePixels) {
  // 2 pixels.
  std::vector<std::uint8_t> bgra = {1, 2, 3, 255, 9, 8, 7, 100};
  std::vector<std::uint8_t> rgba(8, 0);
  LiveCameraTexture::SwizzleBgraToRgba(bgra.data(), 2, 1, rgba.data());
  EXPECT_EQ(rgba[0], 3);    // px0 R
  EXPECT_EQ(rgba[2], 1);    // px0 B
  EXPECT_EQ(rgba[3], 255);  // px0 A
  EXPECT_EQ(rgba[4], 7);    // px1 R
  EXPECT_EQ(rgba[6], 9);    // px1 B
  EXPECT_EQ(rgba[7], 100);  // px1 A
}

TEST(LiveCameraTextureTest, SwizzleRejectsBadArgsWithoutCrashing) {
  std::vector<std::uint8_t> buf(4, 0);
  // null / non-positive dims: no-op, no crash.
  LiveCameraTexture::SwizzleBgraToRgba(nullptr, 1, 1, buf.data());
  LiveCameraTexture::SwizzleBgraToRgba(buf.data(), 1, 1, nullptr);
  LiveCameraTexture::SwizzleBgraToRgba(buf.data(), 0, 1, buf.data());
  SUCCEED();
}

}  // namespace
}  // namespace clingfy::capture
