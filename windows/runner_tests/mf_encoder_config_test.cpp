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

// --- codec selection ---------------------------------------------------------

TEST(VideoCodecTest, ParsesTheDartWireValues) {
  EXPECT_EQ(ParseVideoCodec("hevc"), VideoCodec::kHevc);
  EXPECT_EQ(ParseVideoCodec("h264"), VideoCodec::kH264);
}

TEST(VideoCodecTest, UnknownAndEmptyFallBackToH264) {
  // Every Windows export produced H.264 before codec selection existed, so an
  // absent or garbled key must keep producing exactly that.
  EXPECT_EQ(ParseVideoCodec(""), VideoCodec::kH264);
  EXPECT_EQ(ParseVideoCodec("av1"), VideoCodec::kH264);
  EXPECT_EQ(ParseVideoCodec("HEVC"), VideoCodec::kH264);  // wire value is lower
}

TEST(VideoCodecTest, H264IsNeverReportedAsADowngrade) {
  // A user who asked for H.264 and got H.264 has nothing to be told about.
  bool downgraded = true;
  EXPECT_EQ(ResolveVideoCodec(VideoCodec::kH264, &downgraded),
            VideoCodec::kH264);
  EXPECT_FALSE(downgraded);
}

TEST(VideoCodecTest, AnHevcRequestEitherLandsOrIsReportedAsDowngraded) {
  // This machine may or may not have an HEVC encoder, and CI agents differ —
  // so assert the INVARIANT that ties the two outputs together rather than a
  // fixed answer. The bug this guards is returning H.264 with downgraded
  // still false, which is precisely the silent fallback being fixed.
  bool downgraded = false;
  const VideoCodec got = ResolveVideoCodec(VideoCodec::kHevc, &downgraded);
  if (got == VideoCodec::kHevc) {
    EXPECT_FALSE(downgraded);
    EXPECT_TRUE(IsHevcEncoderAvailable());
  } else {
    EXPECT_EQ(got, VideoCodec::kH264);
    EXPECT_TRUE(downgraded);
    EXPECT_FALSE(IsHevcEncoderAvailable());
  }
}

TEST(VideoCodecTest, TheOutParamIsOptional) {
  // export_passthrough calls this purely to decide whether to defeat the
  // byte-copy, and has no use for the flag.
  EXPECT_NO_FATAL_FAILURE(
      (void)ResolveVideoCodec(VideoCodec::kHevc, nullptr));
}

TEST(VideoCodecTest, TheAvailabilityProbeIsStable) {
  // It is cached behind a function-local static; a probe that flipped between
  // calls would make the byte-copy decision and the encoder's decision
  // disagree within a single export.
  EXPECT_EQ(IsHevcEncoderAvailable(), IsHevcEncoderAvailable());
}

}  // namespace
}  // namespace clingfy::encoding
