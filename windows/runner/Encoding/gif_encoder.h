#ifndef RUNNER_ENCODING_GIF_ENCODER_H_
#define RUNNER_ENCODING_GIF_ENCODER_H_

#include <d3d11.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "Encoding/encoder_error.h"
#include "Encoding/mf_encoder_config.h"

namespace clingfy::capture {
struct CapturedVideoFrame;
}
namespace clingfy::graphics {
class D3DDevice;
}

// Phase 6 Slice 5B animated-GIF writer.
//
// Media Foundation has no GIF sink, so GIF gets its own encoder built on the
// Windows Imaging Component (WIC, `GUID_ContainerFormatGif`). It mirrors
// `MfSinkWriterEncoder`'s lifecycle (Open / WriteVideoFrame / Finalize / Cancel,
// same `EncoderError` result) so `RenderComposedExport` can drive either encoder
// from a single loop. The differences are all GIF-shaped:
//   * consumes CPU pixels — the composited frame lives in a GPU texture, so each
//     frame is copied into a STAGING texture and mapped, then quantized to a
//     256-color local color table (WIC adaptive palette + error-diffusion
//     dither).
//   * no audio.
//   * per-frame delay (centiseconds) is derived from the gap between the
//     timestamps of the frames it is handed (the pipeline decimates to
//     ~kGifTargetFps before calling), via a one-frame lookahead, so playback
//     tracks wall-clock time. An infinite-loop NETSCAPE2.0 application
//     extension is written once.
//
// Never throws — every WIC / D3D failure is reported through the returned
// `EncoderError`. The .gif file is created on Open; a Cancel() releases the WIC
// stream so the caller can delete the partial output.
namespace clingfy::encoding {

class GifEncoder {
 public:
  GifEncoder();
  ~GifEncoder();

  GifEncoder(const GifEncoder&) = delete;
  GifEncoder& operator=(const GifEncoder&) = delete;

  // Initialize COM + WIC, open the .gif stream at `config.output_path`, and
  // write the infinite-loop extension. `config.width`/`height` must be the
  // canvas (output) size; `fps` / `avg_bitrate_bps` are ignored (GIF timing is
  // per-frame). `device` is borrowed for the staging-texture readback and must
  // outlive the encoder. Returns std::nullopt on success.
  std::optional<EncoderError> Open(const EncoderConfig& config,
                                   clingfy::graphics::D3DDevice& device);

  // Hand one composited frame to the encoder. Reads the GPU texture back to CPU
  // and buffers it; the *previous* buffered frame is committed with a delay
  // equal to the real gap to this frame's timestamp. Drops frames with a null
  // texture. Returns std::nullopt on success.
  std::optional<EncoderError> WriteVideoFrame(
      const clingfy::capture::CapturedVideoFrame& frame);

  // Commit the last buffered frame (with the default delay) and the GIF
  // container. Required before the file is a valid GIF. Idempotent.
  std::optional<EncoderError> Finalize();

  // Release the WIC stream/encoder without committing. The on-disk file is left
  // partial/invalid; the caller deletes it. Safe to call on an unopened encoder.
  void Cancel();

  bool open() const { return open_; }
  std::uint64_t frames_written() const { return frames_written_; }

 private:
  std::optional<EncoderError> WriteLoopExtension();
  std::optional<EncoderError> ReadbackBgra(
      const clingfy::capture::CapturedVideoFrame& frame,
      std::vector<std::uint8_t>* out, UINT* out_w, UINT* out_h);
  std::optional<EncoderError> EncodeBufferedFrame(std::uint16_t delay_cs);
  void ReleaseWic();

  EncoderConfig config_;
  clingfy::graphics::D3DDevice* device_ = nullptr;  // borrowed, not owned
  // COM is initialized at most once per instance and balanced by exactly one
  // CoUninitialize in the destructor, so a reuse-after-Cancel re-Open does not
  // double-count the per-thread COM init.
  bool com_attempted_ = false;
  bool com_initialized_by_us_ = false;
  bool open_ = false;
  bool finalized_ = false;

  Microsoft::WRL::ComPtr<IWICImagingFactory> factory_;
  Microsoft::WRL::ComPtr<IWICStream> stream_;
  Microsoft::WRL::ComPtr<IWICBitmapEncoder> encoder_;

  // Reused staging texture for the GPU->CPU readback (recreated if the frame
  // size changes, which it does not within one export).
  Microsoft::WRL::ComPtr<ID3D11Texture2D> staging_;
  UINT staging_w_ = 0;
  UINT staging_h_ = 0;

  // One-frame lookahead: the buffered frame is committed when the next frame
  // arrives, using the real timestamp gap as its delay.
  bool has_pending_ = false;
  std::vector<std::uint8_t> pending_bgra_;  // top-down, tightly packed BGRA
  UINT pending_w_ = 0;
  UINT pending_h_ = 0;
  std::int64_t pending_ts_hns_ = 0;

  std::uint64_t frames_written_ = 0;
};

}  // namespace clingfy::encoding

#endif  // RUNNER_ENCODING_GIF_ENCODER_H_
