#ifndef RUNNER_AUDIO_AUDIO_PACKET_H_
#define RUNNER_AUDIO_AUDIO_PACKET_H_

#include <cstdint>
#include <vector>

// One chunk of audio captured from either the microphone endpoint or the
// system-audio loopback endpoint.
//
// Samples are stored interleaved: `samples[frame * channels + channel]`.
// Phase 3D pins both channels and sample type to the canonical pipeline
// values (`kPipelineChannelCount` = 2, `kPipelineSampleRateHz` = 48k,
// float32) so the mixer can sum the two streams element-wise without
// resampling. A later phase can introduce a resampler shim by
// normalizing the packet's data into the same layout before pushing.
namespace clingfy::audio {

struct AudioPacket {
  // Interleaved float32 samples in [-1.0, 1.0]. Length = frame_count *
  // channels.
  std::vector<float> samples;

  // Number of frames in this packet (= samples.size() / channels).
  std::uint32_t frame_count = 0;

  // 100-nanosecond timestamp, re-based against the recording origin so
  // the encoder can emit AAC samples with monotonic times that start at
  // t=0.
  std::int64_t timestamp_hns = 0;

  // True when the producer flagged the buffer as silent (WASAPI sets
  // AUDCLNT_BUFFERFLAGS_SILENT). The mixer fast-paths these as zeros.
  bool silent = false;
};

}  // namespace clingfy::audio

#endif  // RUNNER_AUDIO_AUDIO_PACKET_H_
