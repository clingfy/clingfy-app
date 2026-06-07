#include "Capture/Camera/camera_format.h"

#include <gtest/gtest.h>

namespace clingfy::capture {
namespace {

TEST(CameraFormatTest, KeepsNative1080p) {
  const auto d = ChooseCameraTargetResolution(1920, 1080);
  EXPECT_EQ(d.width, 1920u);
  EXPECT_EQ(d.height, 1080u);
}

TEST(CameraFormatTest, Keeps720p) {
  const auto d = ChooseCameraTargetResolution(1280, 720);
  EXPECT_EQ(d.width, 1280u);
  EXPECT_EQ(d.height, 720u);
}

TEST(CameraFormatTest, KeepsSmallNativeResolution) {
  const auto d = ChooseCameraTargetResolution(640, 480);
  EXPECT_EQ(d.width, 640u);
  EXPECT_EQ(d.height, 480u);
}

TEST(CameraFormatTest, Downscales4KToFitWithin1080p) {
  const auto d = ChooseCameraTargetResolution(3840, 2160);
  EXPECT_EQ(d.width, 1920u);
  EXPECT_EQ(d.height, 1080u);
}

TEST(CameraFormatTest, DownscalePreservesAspectAndCapsBothAxes) {
  // An ultrawide camera: cap the width at 1920, height scales below 1080.
  const auto d = ChooseCameraTargetResolution(3840, 1080);
  EXPECT_LE(d.width, 1920u);
  EXPECT_LE(d.height, 1080u);
  EXPECT_EQ(d.width, 1920u);  // width is the binding axis here.
  // even dimensions.
  EXPECT_EQ(d.width % 2u, 0u);
  EXPECT_EQ(d.height % 2u, 0u);
}

TEST(CameraFormatTest, FallsBackTo720pWhenNativeUnknown) {
  const auto d = ChooseCameraTargetResolution(0, 0);
  EXPECT_EQ(d.width, 1280u);
  EXPECT_EQ(d.height, 720u);
}

TEST(CameraFormatTest, ClampsOddNativeDimensionsToEven) {
  const auto d = ChooseCameraTargetResolution(641, 481);
  EXPECT_EQ(d.width, 640u);
  EXPECT_EQ(d.height, 480u);
}

TEST(CameraFormatTest, FpsPrefers30) {
  EXPECT_EQ(ChooseCameraFps(30, 1), 30u);
}

TEST(CameraFormatTest, FpsCapsHighRateAt30) {
  EXPECT_EQ(ChooseCameraFps(60, 1), 30u);
  EXPECT_EQ(ChooseCameraFps(120, 1), 30u);
}

TEST(CameraFormatTest, FpsKeepsSlowCameraNative) {
  EXPECT_EQ(ChooseCameraFps(15, 1), 15u);
  EXPECT_EQ(ChooseCameraFps(24, 1), 24u);
}

TEST(CameraFormatTest, FpsRoundsFractionalRate) {
  // 23.976 fps (24000/1001) rounds to 24.
  EXPECT_EQ(ChooseCameraFps(24000, 1001), 24u);
  // 29.97 fps (30000/1001) rounds to 30.
  EXPECT_EQ(ChooseCameraFps(30000, 1001), 30u);
}

TEST(CameraFormatTest, FpsFallsBackTo30WhenUnknown) {
  EXPECT_EQ(ChooseCameraFps(0, 0), 30u);
  EXPECT_EQ(ChooseCameraFps(30, 0), 30u);
  EXPECT_EQ(ChooseCameraFps(0, 1), 30u);
}

}  // namespace
}  // namespace clingfy::capture
