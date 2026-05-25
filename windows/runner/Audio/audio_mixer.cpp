#include "Audio/audio_mixer.h"

#include <algorithm>

#include "Audio/audio_format.h"

namespace clingfy::audio {

namespace {

constexpr std::int64_t kHundredNanosPerSecond = 10'000'000;

std::int64_t SamplesToHns(std::int64_t samples) {
  // 48 kHz pinned: 1 sample = 10_000_000 / 48000 hns.
  return (samples * kHundredNanosPerSecond) /
         static_cast<std::int64_t>(kPipelineSampleRateHz);
}

}  // namespace

void AudioMixer::SumStereoFloat32(const float* mic,
                                   const float* loopback,
                                   std::uint32_t frame_count,
                                   std::vector<std::int16_t>& out) {
  // Stereo, so two int16 samples per frame.
  out.resize(static_cast<std::size_t>(frame_count) *
             static_cast<std::size_t>(kPipelineChannelCount));
  for (std::uint32_t frame = 0; frame < frame_count; ++frame) {
    for (std::uint32_t channel = 0; channel < kPipelineChannelCount;
         ++channel) {
      const std::size_t idx =
          static_cast<std::size_t>(frame) * kPipelineChannelCount + channel;
      const float mic_sample = mic != nullptr ? mic[idx] : 0.0f;
      const float lb_sample = loopback != nullptr ? loopback[idx] : 0.0f;
      out[idx] = ClampFloat32ToInt16(mic_sample + lb_sample);
    }
  }
}

MixedPacket AudioMixer::Mix(const AudioPacket* mic,
                             const AudioPacket* loopback) {
  MixedPacket out;
  if (mic == nullptr && loopback == nullptr) {
    return out;
  }

  // Pick the longer of the two packets so neither stream ever has its
  // tail truncated. The shorter stream contributes silence past its
  // length — `SumStereoFloat32` reads `nullptr` as silent, but here we
  // pass a partial buffer so the available samples mix and the rest
  // pads with silence.
  const std::uint32_t mic_frames = mic ? mic->frame_count : 0u;
  const std::uint32_t lb_frames = loopback ? loopback->frame_count : 0u;
  out.frame_count = std::max(mic_frames, lb_frames);
  if (out.frame_count == 0) {
    return out;
  }

  out.samples.resize(static_cast<std::size_t>(out.frame_count) *
                     kPipelineChannelCount);
  for (std::uint32_t frame = 0; frame < out.frame_count; ++frame) {
    for (std::uint32_t channel = 0; channel < kPipelineChannelCount;
         ++channel) {
      const std::size_t idx =
          static_cast<std::size_t>(frame) * kPipelineChannelCount + channel;
      float mic_sample = 0.0f;
      if (mic != nullptr && frame < mic->frame_count && !mic->silent) {
        mic_sample = mic->samples[idx];
      }
      float lb_sample = 0.0f;
      if (loopback != nullptr && frame < loopback->frame_count &&
          !loopback->silent) {
        lb_sample = loopback->samples[idx];
      }
      out.samples[idx] = ClampFloat32ToInt16(mic_sample + lb_sample);
    }
  }

  out.timestamp_hns = SamplesToHns(next_sample_offset_);
  next_sample_offset_ += out.frame_count;
  return out;
}

}  // namespace clingfy::audio
