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

}  // namespace
}  // namespace clingfy::encoding
