#include "Encoding/mf_encoder_config.h"

#include <gtest/gtest.h>

namespace clingfy::encoding {
namespace {

EncoderConfig ValidConfig() {
  EncoderConfig c;
  c.output_path = "C:\\Temp\\out.mp4";
  c.width = 1920;
  c.height = 1080;
  c.fps = 30;
  c.avg_bitrate_bps = 8'000'000;
  return c;
}

TEST(MfEncoderConfigTest, ValidConfigPasses) {
  EXPECT_FALSE(ValidConfig().Validate().has_value());
}

TEST(MfEncoderConfigTest, EmptyOutputPathRejected) {
  auto c = ValidConfig();
  c.output_path.clear();
  ASSERT_TRUE(c.Validate().has_value());
  EXPECT_NE(c.Validate()->find("output_path"), std::string::npos);
}

TEST(MfEncoderConfigTest, ZeroDimensionsRejected) {
  auto c = ValidConfig();
  c.width = 0;
  ASSERT_TRUE(c.Validate().has_value());

  c = ValidConfig();
  c.height = 0;
  ASSERT_TRUE(c.Validate().has_value());
}

TEST(MfEncoderConfigTest, OddDimensionsRejected) {
  // H.264 needs even dimensions — the engine rounds up before populating
  // the config, but the guard catches a missed clamp.
  auto c = ValidConfig();
  c.width = 1919;
  ASSERT_TRUE(c.Validate().has_value());
  EXPECT_NE(c.Validate()->find("even"), std::string::npos);

  c = ValidConfig();
  c.height = 1081;
  ASSERT_TRUE(c.Validate().has_value());
}

TEST(MfEncoderConfigTest, FpsBoundariesEnforced) {
  auto c = ValidConfig();
  c.fps = 0;
  ASSERT_TRUE(c.Validate().has_value());

  c = ValidConfig();
  c.fps = 241;  // Above the 240 ceiling.
  ASSERT_TRUE(c.Validate().has_value());

  c = ValidConfig();
  c.fps = 60;
  EXPECT_FALSE(c.Validate().has_value());
}

TEST(MfEncoderConfigTest, ZeroBitrateRejected) {
  auto c = ValidConfig();
  c.avg_bitrate_bps = 0;
  ASSERT_TRUE(c.Validate().has_value());
}

// --- keyframe spacing (issue #294) ------------------------------------------

TEST(KeyframeIntervalTest, TwoSecondsAtTheRecordersRealFrameRates) {
  // 2 s is the whole point: it is the upper bound a seek's keyframe lead-in
  // pays, and it matches what the macOS export already picks so a file from
  // either platform seeks the same way.
  EXPECT_EQ(ResolveKeyframeIntervalFrames(30), 60u);
  EXPECT_EQ(ResolveKeyframeIntervalFrames(60), 120u);
  EXPECT_EQ(ResolveKeyframeIntervalFrames(120), 240u);
}

TEST(KeyframeIntervalTest, LowFrameRatesAreFlooredAtThirty) {
  // A timelapse has no seek pressure to justify paying for keyframes every
  // few frames, so the floor keeps the GOP from collapsing. macOS floors the
  // same way, for the same reason.
  EXPECT_EQ(ResolveKeyframeIntervalFrames(1), 60u);
  EXPECT_EQ(ResolveKeyframeIntervalFrames(15), 60u);
  EXPECT_EQ(ResolveKeyframeIntervalFrames(29), 60u);
}

TEST(KeyframeIntervalTest, ZeroFpsLeavesTheChoiceToTheEncoder) {
  // The pre-#294 behaviour, and the only sane answer for a malformed config:
  // pinning something derived from a zero frame rate would be worse than not
  // pinning at all. The encoder sites skip the attribute entirely on 0.
  EXPECT_EQ(ResolveKeyframeIntervalFrames(0), 0u);
}

TEST(MfEncoderConfigTest, ZeroKeyframeIntervalIsLegalAndMeansEncoderChoice) {
  auto c = ValidConfig();
  c.keyframe_interval_frames = 0;
  EXPECT_FALSE(c.Validate().has_value());
}

TEST(MfEncoderConfigTest, AWildKeyframeIntervalIsRejected) {
  // Catches the realistic mistake: passing milliseconds (or microseconds)
  // where frames are expected. 2000 "ms" would silently become a 66-second
  // GOP at 30 fps and quietly undo the entire point of the fix.
  auto c = ValidConfig();
  c.keyframe_interval_frames = 200'000;
  ASSERT_TRUE(c.Validate().has_value());
  c.keyframe_interval_frames = 3600;  // the boundary itself stays legal
  EXPECT_FALSE(c.Validate().has_value());
}

}  // namespace
}  // namespace clingfy::encoding
