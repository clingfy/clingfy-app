#include "Audio/audio_format.h"

#include <windows.h>
#include <mmreg.h>

#include <algorithm>
#include <cmath>

namespace clingfy::audio {

namespace {

bool IsFloatGuid(const GUID& guid) {
  return guid == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
}

bool IsPcmGuid(const GUID& guid) {
  return guid == KSDATAFORMAT_SUBTYPE_PCM;
}

}  // namespace

AudioFormatSnapshot Snapshot(const WAVEFORMATEX* format) {
  AudioFormatSnapshot out;
  if (format == nullptr) {
    return out;
  }
  out.sample_rate_hz = format->nSamplesPerSec;
  out.channel_count = format->nChannels;
  out.bits_per_sample = format->wBitsPerSample;

  if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
      format->cbSize >= sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) {
    const auto* ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format);
    if (IsFloatGuid(ext->SubFormat)) {
      out.sample_type = SampleType::kFloat32;
    } else if (IsPcmGuid(ext->SubFormat)) {
      out.sample_type = SampleType::kInt16;
    }
  } else if (format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
    out.sample_type = SampleType::kFloat32;
  } else if (format->wFormatTag == WAVE_FORMAT_PCM) {
    out.sample_type = SampleType::kInt16;
  }
  return out;
}

bool IsPipelineCompatible(const AudioFormatSnapshot& snapshot) {
  return snapshot.sample_rate_hz == kPipelineSampleRateHz &&
         snapshot.channel_count == kPipelineChannelCount &&
         snapshot.sample_type == SampleType::kFloat32 &&
         snapshot.bits_per_sample == 32;
}

std::uint32_t FrameSizeBytes(const AudioFormatSnapshot& snapshot) {
  if (snapshot.channel_count == 0 || snapshot.bits_per_sample == 0) {
    return 0;
  }
  return static_cast<std::uint32_t>(snapshot.channel_count) *
         (snapshot.bits_per_sample / 8u);
}

std::int16_t ClampFloat32ToInt16(float value) {
  // WASAPI float samples are in [-1.0, 1.0] but content can clip past
  // those edges (e.g. live music + boosted gain). Clamp explicitly so a
  // signal above the legal range does not wrap around inside the encoder.
  if (std::isnan(value)) {
    return 0;
  }
  const float scaled = value * 32767.0f;
  if (scaled >= 32767.0f) return 32767;
  if (scaled <= -32768.0f) return -32768;
  return static_cast<std::int16_t>(std::lround(scaled));
}

}  // namespace clingfy::audio
