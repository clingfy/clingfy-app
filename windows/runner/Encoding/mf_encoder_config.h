#ifndef RUNNER_ENCODING_MF_ENCODER_CONFIG_H_
#define RUNNER_ENCODING_MF_ENCODER_CONFIG_H_

#include <cstdint>
#include <optional>
#include <string>

// Encoder configuration for the Phase 3C Media Foundation Sink Writer
// wrapper.
//
// Kept as a plain struct so the engine can fill it in from the
// `StartRecordingRequest` + the resolved display size, and so it can be
// unit-tested without touching MF.
namespace clingfy::encoding {

struct EncoderConfig {
  // Absolute path to the MP4 file the Sink Writer will create.
  // `MFCreateSinkWriterFromURL` requires a fully-qualified URL or file
  // path; relative paths produce confusing E_INVALIDARG errors from
  // somewhere deep inside `mfreadwrite`. The engine resolves this through
  // `encoder_output_path::ResolveTempMp4Path` for Phase 3C; Phase 3E will
  // start routing the file into the real project folder.
  std::string output_path;

  std::uint32_t width = 0;
  std::uint32_t height = 0;
  std::uint32_t fps = 30;

  // ~8 Mbps default. Picked to land between YouTube's recommended 1080p
  // upload bitrate (8-12 Mbps) and the Sink Writer's compressed-but-still
  // honest range. Phase 3D+ may surface this to a quality preset in the
  // settings UI.
  std::uint32_t avg_bitrate_bps = 8'000'000;

  // Validation. Returns std::nullopt when the config is usable; otherwise
  // a human-readable message describing what's wrong. Kept here so the
  // engine can fail with `BAD_ARGS` before any MF object is created.
  std::optional<std::string> Validate() const;
};

// Audio side of the encoder, added in Phase 3D. Pinned to AAC-LC at
// 48 kHz stereo because that's what the WASAPI mixer produces and what
// the Sink Writer's AAC encoder MFT accepts as a universal input —
// expanding the matrix is future work.
struct AudioEncoderConfig {
  // PCM input: 48 kHz stereo int16. Mirrors the AudioMixer's output.
  std::uint32_t sample_rate_hz = 48'000;
  std::uint16_t channel_count = 2;
  std::uint16_t bits_per_sample = 16;

  // Output AAC bitrate. 128 kbps is the canonical "voice + music"
  // shared-mode default and matches what Windows' own Game Bar uses.
  std::uint32_t avg_bitrate_bps = 128'000;

  std::optional<std::string> Validate() const;
};

}  // namespace clingfy::encoding

#endif  // RUNNER_ENCODING_MF_ENCODER_CONFIG_H_
