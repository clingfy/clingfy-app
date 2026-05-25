#ifndef RUNNER_AUDIO_AUDIO_FORMAT_H_
#define RUNNER_AUDIO_AUDIO_FORMAT_H_

#include <cstdint>

struct tWAVEFORMATEX;
typedef struct tWAVEFORMATEX WAVEFORMATEX;

// Pure helpers for inspecting and comparing WASAPI `WAVEFORMATEX`
// descriptors.
//
// The Phase 3D capture path uses `IAudioClient::GetMixFormat` to fetch the
// endpoint's preferred format and feeds that to the mixer / encoder. The
// helpers here let the mixer assert that microphone and loopback formats
// are compatible (same sample rate + channel layout + sample type) without
// pulling Win32 into every consumer, which keeps the mixer unit-testable.
namespace clingfy::audio {

// Canonical mix format the Phase 3D pipeline expects to receive from both
// the microphone and the system-audio loopback endpoint. Windows shared-
// mode defaults to 48 kHz float32 stereo for both — this is the format
// the AAC encoder downstream is configured against, with a single int16
// conversion step inside the mixer.
inline constexpr std::uint32_t kPipelineSampleRateHz = 48'000;
inline constexpr std::uint32_t kPipelineChannelCount = 2;
inline constexpr std::uint32_t kPipelineBytesPerSampleFloat = 4;
inline constexpr std::uint32_t kPipelineBytesPerSampleInt16 = 2;

enum class SampleType {
  kUnknown,
  kFloat32,
  kInt16,
};

struct AudioFormatSnapshot {
  std::uint32_t sample_rate_hz = 0;
  std::uint16_t channel_count = 0;
  std::uint16_t bits_per_sample = 0;
  SampleType sample_type = SampleType::kUnknown;
};

// Snapshot a WAVEFORMATEX (or WAVEFORMATEXTENSIBLE) into the plain
// struct above so the mixer and tests can reason about it without
// touching mmreg.h.
AudioFormatSnapshot Snapshot(const WAVEFORMATEX* format);

// True if `format` matches the canonical pipeline expectations: 48 kHz,
// 2 channels, 32-bit float samples. The capture path may opt to resample
// non-matching streams in a later phase, but Phase 3D rejects them with
// a structured error so we never write silently-wrong audio.
bool IsPipelineCompatible(const AudioFormatSnapshot& snapshot);

// Convenience: byte count of one `frame` (one sample × channels) for the
// given snapshot. Returns 0 when the snapshot is unknown.
std::uint32_t FrameSizeBytes(const AudioFormatSnapshot& snapshot);

// Convert a float32 sample to a clamped int16 PCM sample. The mixer
// uses this when handing data to the AAC encoder, which always wants
// PCM-16 input. Public for the unit tests.
std::int16_t ClampFloat32ToInt16(float value);

}  // namespace clingfy::audio

#endif  // RUNNER_AUDIO_AUDIO_FORMAT_H_
