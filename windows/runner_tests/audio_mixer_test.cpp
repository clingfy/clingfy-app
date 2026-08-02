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

// Audio-separation D3: the sidecar tee's per-source render must cover
// EXACTLY the mixed span — source samples where the source contributed,
// silence everywhere else — so sidecar timelines can never slip against
// the premixed track.

TEST(RenderSourceInt16Test, NullSourceRendersSilenceOverTheFullSpan) {
  std::vector<std::int16_t> out;
  AudioMixer::RenderSourceInt16(nullptr, /*frame_count=*/4, out);
  ASSERT_EQ(out.size(), 8u);
  for (auto sample : out) {
    EXPECT_EQ(sample, 0);
  }
}

TEST(RenderSourceInt16Test, SourceSamplesConvertWithTheMixersClamp) {
  auto src = MakeStereoPacket(2, 0.5f);
  std::vector<std::int16_t> out;
  AudioMixer::RenderSourceInt16(&src, /*frame_count=*/2, out);
  ASSERT_EQ(out.size(), 4u);
  for (auto sample : out) {
    EXPECT_EQ(sample, 16384);  // same 0.5 → 16384 as the Mix tests above
  }
}

TEST(RenderSourceInt16Test, ShorterSourcePadsTheTailWithSilence) {
  // Mixed span = 4 frames (the other source was longer); this source only
  // contributed 2. Its sidecar still advances 4 frames.
  auto src = MakeStereoPacket(2, 0.5f);
  std::vector<std::int16_t> out;
  AudioMixer::RenderSourceInt16(&src, /*frame_count=*/4, out);
  ASSERT_EQ(out.size(), 8u);
  for (std::uint32_t i = 0; i < 4; ++i) {
    for (std::uint32_t ch = 0; ch < 2; ++ch) {
      EXPECT_EQ(out[i * 2 + ch], i < 2 ? 16384 : 0);
    }
  }
}

TEST(RenderSourceInt16Test, SilentFlagRendersZeroesRegardlessOfBuffer) {
  auto src = MakeStereoPacket(3, 0.9f);
  src.silent = true;
  std::vector<std::int16_t> out;
  AudioMixer::RenderSourceInt16(&src, /*frame_count=*/3, out);
  ASSERT_EQ(out.size(), 6u);
  for (auto sample : out) {
    EXPECT_EQ(sample, 0);
  }
}

TEST(RenderSourceInt16Test, OutOfRangeSamplesClampToInt16) {
  auto src = MakeStereoPacket(1, 1.7f);
  std::vector<std::int16_t> out;
  AudioMixer::RenderSourceInt16(&src, /*frame_count=*/1, out);
  ASSERT_EQ(out.size(), 2u);
  for (auto sample : out) {
    EXPECT_EQ(sample, 32767);
  }
}

// Audio-separation D4: blocking-source policy. Mic blocks while alive
// (loopback drains non-blocking); a dead mic hands the blocking role to
// loopback; both dead → exit. Pins the mid-record death transitions the
// engine's mixer loop relies on to never wedge.

TEST(ChooseMixerBlockSourceTest, MicBlocksWhileAlive) {
  EXPECT_EQ(ChooseMixerBlockSource(true, true), MixerBlockSource::kMic);
  EXPECT_EQ(ChooseMixerBlockSource(true, false), MixerBlockSource::kMic);
}

TEST(ChooseMixerBlockSourceTest, LoopbackTakesOverWhenTheMicDies) {
  EXPECT_EQ(ChooseMixerBlockSource(false, true),
            MixerBlockSource::kLoopback);
}

TEST(ChooseMixerBlockSourceTest, BothDeadExitsTheLoop) {
  EXPECT_EQ(ChooseMixerBlockSource(false, false), MixerBlockSource::kNone);
}


// ---------------------------------------------------------------------------
// Synthetic-timeline behaviour under injected silence.
//
// With no microphone the mixer feeds SYNTHESISED silence whenever loopback is
// idle, so the encoder keeps receiving audio and video never stalls. Mix()
// timestamps from an accumulated frame count, not from device clocks, so those
// silence packets must advance the timeline exactly like real ones — otherwise
// audio drifts against video for the whole recording.
// ---------------------------------------------------------------------------

TEST(AudioMixerTimelineTest, SilenceAdvancesTheTimelineLikeRealAudio) {
  AudioMixer with_silence;
  AudioMixer with_audio;

  AudioPacket silent = MakeStereoPacket(960, 0.0f);
  silent.silent = true;
  const AudioPacket loud = MakeStereoPacket(960, 0.25f);

  // Same frame counts through both mixers, one silent and one not.
  for (int i = 0; i < 4; ++i) {
    const auto a = with_silence.Mix(nullptr, &silent);
    const auto b = with_audio.Mix(nullptr, &loud);
    EXPECT_EQ(a.frame_count, b.frame_count) << "iteration " << i;
    EXPECT_EQ(a.timestamp_hns, b.timestamp_hns)
        << "silence must not advance the timeline differently — iteration " << i;
  }
}

// A silent packet still has to produce a real, full-length buffer: the encoder
// and both sidecar tees consume `frame_count` samples from it.
TEST(AudioMixerTimelineTest, SilentPacketYieldsAFullSilentBuffer) {
  AudioMixer mixer;
  AudioPacket silent = MakeStereoPacket(960, 0.0f);
  silent.silent = true;

  const auto mixed = mixer.Mix(nullptr, &silent);
  EXPECT_EQ(mixed.frame_count, 960u);
  EXPECT_EQ(mixed.samples.size(),
            static_cast<std::size_t>(960) * kPipelineChannelCount);
  for (const auto sample : mixed.samples) {
    EXPECT_EQ(sample, 0) << "a silent packet must mix to actual silence";
  }
}

// The timeline is monotonic and gapless across a mix of real and injected
// packets — which is exactly the sequence a recording produces when the user
// plays audio intermittently.
TEST(AudioMixerTimelineTest, TimelineIsGaplessAcrossAlternatingSilence) {
  AudioMixer mixer;
  AudioPacket silent = MakeStereoPacket(960, 0.0f);
  silent.silent = true;
  const AudioPacket loud = MakeStereoPacket(960, 0.5f);

  std::int64_t previous = -1;
  std::int64_t expected_frames = 0;
  for (int i = 0; i < 6; ++i) {
    const auto mixed = mixer.Mix(nullptr, (i % 2 == 0) ? &loud : &silent);
    EXPECT_GT(mixed.timestamp_hns, previous) << "iteration " << i;
    previous = mixed.timestamp_hns;
    // Timestamp must equal the frames emitted BEFORE this packet.
    const std::int64_t want =
        expected_frames * 10'000'000 / kPipelineSampleRateHz;
    EXPECT_EQ(mixed.timestamp_hns, want) << "iteration " << i;
    expected_frames += mixed.frame_count;
  }
}

}  // namespace
}  // namespace clingfy::audio
