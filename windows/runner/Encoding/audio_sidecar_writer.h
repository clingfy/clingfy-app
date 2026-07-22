#ifndef RUNNER_ENCODING_AUDIO_SIDECAR_WRITER_H_
#define RUNNER_ENCODING_AUDIO_SIDECAR_WRITER_H_

// `<mfreadwrite.h>` references IMF* interfaces declared in `<mfidl.h>`;
// include order matters (see mf_sink_writer_encoder.h).
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include <cstdint>
#include <mutex>
#include <optional>
#include <string>

#include "Encoding/encoder_error.h"
#include "Encoding/mf_encoder_config.h"

// Audio-separation sidecar writer (docs/decisions/windows-audio-separation.md,
// D2/D5).
//
// A minimal audio-only `IMFSinkWriter`: one AAC-LC stream, 48 kHz stereo
// int16 PCM in — the exact media types `MfSinkWriterEncoder` uses for the
// premixed track, minus the video stream and the D3D manager (neither of
// which an audio file needs; `MfSinkWriterEncoder` hard-requires both).
// The recording engine opens one writer per captured audio source and
// tees the pre-mix packets into it from the mixer thread, producing the
// `capture/mic.m4a` / `capture/system.m4a` sidecars that macOS Phase 1.5
// recordings carry.
//
// Sidecars are best-effort by design: every failure here degrades to
// "no sidecar" (the premixed track in screen.mov is untouched), never to
// a failed recording.
//
// Threading: `Open` / `Finalize` / `Cancel` run on the engine's platform
// thread; `WriteSamples` runs on the mixer thread. The engine joins the
// mixer thread before finalizing, so calls never actually overlap — the
// internal mutex mirrors `MfSinkWriterEncoder`'s belt-and-suspenders
// locking rather than encoding a concurrency contract.
namespace clingfy::encoding {

class AudioSidecarWriter {
 public:
  AudioSidecarWriter();
  // Destroying an un-finalized writer cancels it (no footer is written)
  // rather than blocking in MF — same rationale as ~MfSinkWriterEncoder.
  ~AudioSidecarWriter();

  AudioSidecarWriter(const AudioSidecarWriter&) = delete;
  AudioSidecarWriter& operator=(const AudioSidecarWriter&) = delete;

  // Create the sink writer at `output_path` (UTF-8, fully qualified,
  // `.mp4`-suffixed so MF picks the MPEG-4 container — the project writer
  // renames the temp to `.m4a` at bundle time; the container is identical).
  std::optional<EncoderError> Open(const std::string& output_path);

  // Append `frame_count` interleaved int16 stereo frames starting at
  // `timestamp_hns`. Timestamps are the mixer's synthetic sample-count
  // timeline (`MixedPacket.timestamp_hns`), so the sidecar stays
  // sample-exact against the premixed track by construction (design D3).
  std::optional<EncoderError> WriteSamples(
      const std::int16_t* interleaved_samples,
      std::uint32_t frame_count,
      std::int64_t timestamp_hns);

  // Write the MP4 footer. After Finalize the writer is closed; further
  // calls are no-ops.
  std::optional<EncoderError> Finalize();

  // Drop the writer without finalizing — the output file is abandoned
  // (the caller deletes the temp). Safe to call multiple times.
  void Cancel();

  std::uint64_t samples_written() const;

 private:
  std::optional<EncoderError> ConfigureMediaTypes();

  mutable std::mutex mutex_;
  bool open_ = false;
  Microsoft::WRL::ComPtr<IMFSinkWriter> sink_writer_;
  AudioEncoderConfig config_;
  DWORD stream_index_ = 0;
  std::int64_t last_sample_time_hns_ = -1;
  std::uint64_t samples_written_ = 0;
};

}  // namespace clingfy::encoding

#endif  // RUNNER_ENCODING_AUDIO_SIDECAR_WRITER_H_
