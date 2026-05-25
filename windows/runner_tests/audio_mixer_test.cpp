#include "Audio/audio_mixer.h"

#include <gtest/gtest.h>

#include <vector>

#include "Audio/audio_format.h"

namespace clingfy::audio {
namespace {

AudioPacket MakeStereoPacket(std::uint32_t frames, float value) {
  AudioPacket packet;
  packet.frame_count = frames;
  packet.samples.assign(static_cast<std::size_t>(frames) * 2, value);
  return packet;
}

TEST(AudioMixerTest, BothNullReturnsEmpty) {
  AudioMixer mixer;
  auto out = mixer.Mix(nullptr, nullptr);
  EXPECT_EQ(out.frame_count, 0u);
  EXPECT_TRUE(out.samples.empty());
}

TEST(AudioMixerTest, MicOnlyPassesThrough) {
  AudioMixer mixer;
  auto mic = MakeStereoPacket(2, 0.5f);
  auto out = mixer.Mix(&mic, nullptr);
  ASSERT_EQ(out.frame_count, 2u);
  ASSERT_EQ(out.samples.size(), 4u);
  for (auto sample : out.samples) {
    EXPECT_EQ(sample, 16384);  // 0.5 * 32767 ≈ 16384 after lround
  }
}

TEST(AudioMixerTest, LoopbackOnlyPassesThrough) {
  AudioMixer mixer;
  auto lb = MakeStereoPacket(2, -0.5f);
  auto out = mixer.Mix(nullptr, &lb);
  ASSERT_EQ(out.frame_count, 2u);
  for (auto sample : out.samples) {
    EXPECT_EQ(sample, -16384);
  }
}

TEST(AudioMixerTest, BothPresentSumsAndClamps) {
  AudioMixer mixer;
  auto mic = MakeStereoPacket(2, 0.3f);
  auto lb = MakeStereoPacket(2, 0.4f);
  auto out = mixer.Mix(&mic, &lb);
  ASSERT_EQ(out.frame_count, 2u);
  // 0.3 + 0.4 = 0.7 → 0.7 * 32767 = 22936.9 → 22937 with lround
  for (auto sample : out.samples) {
    EXPECT_EQ(sample, 22937);
  }
}

TEST(AudioMixerTest, BothPresentClipsToInt16Limit) {
  AudioMixer mixer;
  auto mic = MakeStereoPacket(2, 0.8f);
  auto lb = MakeStereoPacket(2, 0.8f);
  auto out = mixer.Mix(&mic, &lb);
  ASSERT_EQ(out.frame_count, 2u);
  // 0.8 + 0.8 = 1.6 → clipped to 32767.
  for (auto sample : out.samples) {
    EXPECT_EQ(sample, 32767);
  }
}

TEST(AudioMixerTest, SilentPacketContributesZeroes) {
  AudioMixer mixer;
  auto mic = MakeStereoPacket(2, 0.4f);
  mic.silent = true;  // Producer flagged the buffer as silent.
  auto lb = MakeStereoPacket(2, 0.4f);
  auto out = mixer.Mix(&mic, &lb);
  ASSERT_EQ(out.frame_count, 2u);
  // Silent mic contributes 0.0 regardless of buffer contents; only the
  // loopback signal makes it through.
  for (auto sample : out.samples) {
    EXPECT_EQ(sample, 13107);  // 0.4 * 32767 ≈ 13107
  }
}

TEST(AudioMixerTest, MismatchedLengthsPadShorterStreamWithSilence) {
  AudioMixer mixer;
  auto mic = MakeStereoPacket(4, 0.5f);
  auto lb = MakeStereoPacket(2, 0.5f);
  auto out = mixer.Mix(&mic, &lb);
  // Output covers the longer (mic) — first 2 frames mix both, next 2
  // frames pass the mic alone.
  ASSERT_EQ(out.frame_count, 4u);
  for (std::uint32_t i = 0; i < 4; ++i) {
    for (std::uint32_t ch = 0; ch < 2; ++ch) {
      const auto sample = out.samples[i * 2 + ch];
      if (i < 2) {
        EXPECT_EQ(sample, 32767);  // 0.5 + 0.5 = 1.0 → clamped
      } else {
        EXPECT_EQ(sample, 16384);  // mic-only 0.5
      }
    }
  }
}

TEST(AudioMixerTest, TimestampsAdvanceMonotonically) {
  AudioMixer mixer;
  auto packet = MakeStereoPacket(48, 0.0f);  // 48 samples @ 48 kHz = 1 ms

  auto first = mixer.Mix(&packet, nullptr);
  auto second = mixer.Mix(&packet, nullptr);
  auto third = mixer.Mix(&packet, nullptr);
  EXPECT_EQ(first.timestamp_hns, 0);
  EXPECT_EQ(second.timestamp_hns, 10000);   // 1 ms = 10000 hns
  EXPECT_EQ(third.timestamp_hns, 20000);
}

TEST(AudioMixerTest, SumStereoFloat32SilentInputsProduceZero) {
  std::vector<std::int16_t> out;
  AudioMixer::SumStereoFloat32(nullptr, nullptr, /*frame_count=*/3, out);
  ASSERT_EQ(out.size(), 6u);
  for (auto sample : out) {
    EXPECT_EQ(sample, 0);
  }
}

}  // namespace
}  // namespace clingfy::audio
