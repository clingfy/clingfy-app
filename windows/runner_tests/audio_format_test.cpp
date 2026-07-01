#include "Audio/audio_format.h"

#include <gtest/gtest.h>

namespace clingfy::audio {
namespace {

TEST(AudioFormatTest, ClampFloat32ToInt16Boundaries) {
  // The conversion scales by 32767 so the nominal [-1, 1] float range
  // maps onto [-32767, 32767]. -32768 is reserved for explicit
  // clip-below cases (see the ClipsAbove1AndBelowMinus1 test) — that
  // matches what every common float → int16 PCM pipeline does, since a
  // symmetric scale prevents asymmetric DC offset on the encoder side.
  EXPECT_EQ(ClampFloat32ToInt16(0.0f), 0);
  EXPECT_EQ(ClampFloat32ToInt16(1.0f), 32767);
  EXPECT_EQ(ClampFloat32ToInt16(-1.0f), -32767);
  EXPECT_EQ(ClampFloat32ToInt16(0.5f), 16384);
  EXPECT_EQ(ClampFloat32ToInt16(-0.5f), -16384);
}

TEST(AudioFormatTest, ClampFloat32ToInt16ClipsAbove1AndBelowMinus1) {
  // WASAPI float samples are nominally [-1, 1] but can exceed that when
  // gain stages combine — the clamp must hold the line so the encoder
  // never sees a wrapped value.
  EXPECT_EQ(ClampFloat32ToInt16(2.0f), 32767);
  EXPECT_EQ(ClampFloat32ToInt16(-2.0f), -32768);
  EXPECT_EQ(ClampFloat32ToInt16(1e9f), 32767);
}

TEST(AudioFormatTest, ClampFloat32ToInt16NanReturnsZero) {
  EXPECT_EQ(ClampFloat32ToInt16(std::nanf("0")), 0);
}

TEST(AudioFormatTest, IsPipelineCompatibleMatchesCanonicalShape) {
  AudioFormatSnapshot snap;
  snap.sample_rate_hz = 48000;
  snap.channel_count = 2;
  snap.bits_per_sample = 32;
  snap.sample_type = SampleType::kFloat32;
  EXPECT_TRUE(IsPipelineCompatible(snap));
}

TEST(AudioFormatTest, IsPipelineCompatibleRejectsNonPipelineShapes) {
  // Wrong rate.
  AudioFormatSnapshot snap{44100, 2, 32, SampleType::kFloat32};
  EXPECT_FALSE(IsPipelineCompatible(snap));

  // Mono.
  snap = {48000, 1, 32, SampleType::kFloat32};
  EXPECT_FALSE(IsPipelineCompatible(snap));

  // 16-bit PCM (some headsets default to this).
  snap = {48000, 2, 16, SampleType::kInt16};
  EXPECT_FALSE(IsPipelineCompatible(snap));

  // Unknown sample type.
  snap = {48000, 2, 32, SampleType::kUnknown};
  EXPECT_FALSE(IsPipelineCompatible(snap));
}

TEST(AudioFormatTest, FrameSizeBytesMatchesChannelsTimesSampleSize) {
  AudioFormatSnapshot snap{48000, 2, 32, SampleType::kFloat32};
  EXPECT_EQ(FrameSizeBytes(snap), 8u);  // 2 channels * 4 bytes
  snap = {48000, 1, 16, SampleType::kInt16};
  EXPECT_EQ(FrameSizeBytes(snap), 2u);
  snap = {0, 0, 0, SampleType::kUnknown};
  EXPECT_EQ(FrameSizeBytes(snap), 0u);
}

}  // namespace
}  // namespace clingfy::audio
