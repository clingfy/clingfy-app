#ifndef RUNNER_ENCODING_MF_SINK_WRITER_ENCODER_H_
#define RUNNER_ENCODING_MF_SINK_WRITER_ENCODER_H_

// `<mfreadwrite.h>` references IMFMediaSink / IMFMediaSource /
// IMFAttributes / IMFSourceReader / IMFSinkWriter without declaring them
// itself — those live in `<mfidl.h>`. Include order matters: mfidl
// MUST come first, otherwise the IMF* names are undeclared at the point
// `<mfreadwrite.h>` references them.
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include <cstdint>
#include <mutex>
#include <optional>
#include <string>

#include "Encoding/mf_dxgi_manager.h"
#include "Encoding/mf_encoder_config.h"

namespace clingfy::audio {
struct MixedPacket;
}
namespace clingfy::capture {
struct CapturedVideoFrame;
}
namespace clingfy::graphics {
class D3DDevice;
}

// Phase 3C MP4 / H.264 writer.
//
// Wraps `IMFSinkWriter` and produces a playable MP4 file from a sequence
// of `CapturedVideoFrame`s. The configuration is intentionally narrow —
// hard-coded to MP4 + H.264 (no MOV, no HEVC, no GIF), no audio yet —
// because the priority is "produce *a* playable file" before adding
// preset surface area. Phase 3D wires AAC audio into this same writer;
// Phase 3E expands the configuration matrix to match the macOS engine.
namespace clingfy::encoding {

struct EncoderError {
  std::string message;
  HRESULT hr = 0;
};

class MfSinkWriterEncoder {
 public:
  MfSinkWriterEncoder();
  ~MfSinkWriterEncoder();

  MfSinkWriterEncoder(const MfSinkWriterEncoder&) = delete;
  MfSinkWriterEncoder& operator=(const MfSinkWriterEncoder&) = delete;

  // Open the writer. Initializes MF (idempotent), binds the supplied
  // D3D device through an `IMFDXGIDeviceManager` so the hardware encoder
  // MFT is engaged, configures input (ARGB32 = BGRA in memory layout,
  // matching what WGC produces) and output (H.264 in MP4) media types,
  // and calls `BeginWriting`. Returns std::nullopt on success.
  //
  // The optional `audio` parameter adds an AAC audio stream alongside
  // the video stream. Pass `std::nullopt` for video-only recording
  // (e.g. mic + system audio both disabled).
  std::optional<EncoderError> Open(
      const EncoderConfig& config,
      clingfy::graphics::D3DDevice& device,
      const std::optional<AudioEncoderConfig>& audio = std::nullopt);

  // Write one captured frame. The first call records the frame's
  // timestamp as the recording origin so the resulting MP4 always starts
  // at t=0 regardless of when WGC began producing frames. Drops frames
  // with `texture == nullptr` (the Phase 3B FrameArrived path used to
  // produce these — keeping the guard means a partial-rollback scenario
  // does not crash the writer).
  std::optional<EncoderError> WriteVideoFrame(
      const clingfy::capture::CapturedVideoFrame& frame);

  // Write one mixed audio packet. No-op (success) when the encoder was
  // opened video-only. AAC samples are tagged as clean points (every
  // AAC sample is a keyframe), so the Sink Writer does not need to
  // insert sync hints. Returns std::nullopt on success.
  std::optional<EncoderError> WriteAudioPacket(
      const clingfy::audio::MixedPacket& packet);

  // Finalize the MP4 file. Required before the file is playable;
  // without it the MOOV atom is missing and the MP4 reader sees a 0-byte
  // / corrupted file. Idempotent.
  std::optional<EncoderError> Finalize();

  // Release the writer without finalizing. Used on failure paths to
  // avoid leaking a half-written file with a broken atom layout — the
  // file still exists on disk but is documented as garbage.
  void Cancel();

  bool open() const;
  const std::string& output_path() const { return config_.output_path; }
  std::uint64_t samples_written() const;

 private:
  // Build the input (uncompressed) and output (compressed H.264) media
  // types. Kept private (free helpers in the .cpp) because they capture
  // the bridge contract between WGC's pixel format and Media Foundation
  // input expectations.
  std::optional<EncoderError> ConfigureVideoMediaTypes();
  std::optional<EncoderError> ConfigureAudioMediaTypes();

  mutable std::mutex mutex_;
  EncoderConfig config_;
  std::optional<AudioEncoderConfig> audio_config_;
  MfDxgiManager dxgi_manager_;
  Microsoft::WRL::ComPtr<IMFSinkWriter> sink_writer_;
  DWORD video_stream_index_ = 0;
  DWORD audio_stream_index_ = 0;
  bool has_audio_stream_ = false;
  std::int64_t origin_timestamp_hns_ = -1;
  std::int64_t sample_duration_hns_ = 0;
  std::int64_t last_sample_time_hns_ = -1;
  std::int64_t last_audio_sample_time_hns_ = -1;
  std::uint64_t samples_written_ = 0;
  std::uint64_t audio_samples_written_ = 0;
  bool open_ = false;
};

}  // namespace clingfy::encoding

#endif  // RUNNER_ENCODING_MF_SINK_WRITER_ENCODER_H_
