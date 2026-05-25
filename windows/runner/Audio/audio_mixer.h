#ifndef RUNNER_AUDIO_AUDIO_MIXER_H_
#define RUNNER_AUDIO_AUDIO_MIXER_H_

#include <cstdint>
#include <vector>

#include "Audio/audio_packet.h"

// Sums microphone + system-audio loopback float32 streams into a single
// interleaved int16 PCM buffer ready for the AAC encoder.
//
// The mixer is intentionally stateless except for tracking the running
// sample position so it can emit monotonic timestamps. Each call to
// `MixInto` consumes one packet from each stream (either or both may be
// `std::nullopt` when the corresponding capture is disabled or stalled)
// and writes the mixed result into the caller's int16 buffer.
//
// Channel + frame count must match the canonical pipeline format
// (48 kHz float32 stereo). The capture path rejects non-matching mix
// formats at start time so the mixer can assume compatibility here.
namespace clingfy::audio {

struct MixedPacket {
  // Interleaved int16 stereo samples. Length = frame_count * 2.
  std::vector<std::int16_t> samples;
  std::uint32_t frame_count = 0;
  std::int64_t timestamp_hns = 0;
};

class AudioMixer {
 public:
  // Mix one packet from the mic stream and one from the loopback stream
  // into a `MixedPacket`. At least one of the two must have a value;
  // when both are present they are summed element-wise. Returns an
  // empty `MixedPacket` (frame_count = 0) when both inputs are absent
  // so the caller can drop the slot without splitting a per-source
  // branch.
  MixedPacket Mix(const AudioPacket* mic, const AudioPacket* loopback);

  // Sum `frame_count` interleaved float32 stereo samples from two
  // sources into the destination buffer (resized to frame_count * 2).
  // Either source pointer may be null, in which case it contributes
  // silence. Exposed so unit tests can pin the summing math without
  // building a full `AudioPacket`.
  static void SumStereoFloat32(const float* mic,
                               const float* loopback,
                               std::uint32_t frame_count,
                               std::vector<std::int16_t>& out);

 private:
  // Monotonically-increasing sample position. The first MixInto call
  // emits at timestamp 0; subsequent calls advance by the previous
  // packet's frame count. Used when both inputs supply a timestamp but
  // we want to pin the encoder's view to a continuous timeline.
  std::int64_t next_sample_offset_ = 0;
};

}  // namespace clingfy::audio

#endif  // RUNNER_AUDIO_AUDIO_MIXER_H_
