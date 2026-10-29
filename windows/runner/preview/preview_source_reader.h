#ifndef RUNNER_PREVIEW_PREVIEW_SOURCE_READER_H_
#define RUNNER_PREVIEW_PREVIEW_SOURCE_READER_H_

#include <windows.h>
// mfidl.h (IMFSample / IMFSourceReader deps) MUST precede mfreadwrite.h.
#include <mfidl.h>
#include <mfreadwrite.h>
#include <d3d11.h>
#include <wrl/client.h>

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

// Editing port (clips, step 4-2): the source-video decode front-end for the
// stitched-timeline live preview.
//
// The live preview's default path is a WinRT MediaPlayer frame server bound to
// one file; it plays the source 1:1 and cannot play a stitched timeline of
// non-contiguous kept ranges (cuts / reorder). For EDITED sessions the engine
// instead drives frames from this reader — an IMFSourceReader over the same
// recording that decodes to top-down BGRA system memory, which the pacer
// (step 4-3) uploads straight into the compositor's video texture (the same
// seam the headless compositor tests fill via UpdateSubresource).
//
// The read model mirrors the EXPORT reorder path (shipped + validated in 3b-2):
// SeekTo() at a RANGE boundary (never per frame — per-frame seeking is the
// forbidden §5.4 "seek-through-cuts" that hitches on sparse-keyframe screen
// recordings), then ReadNextFrame() decodes forward inside the range. All
// failures are soft: Create returns nullptr and the caller stays on MediaPlayer.
namespace clingfy::preview {

// One decoded frame, not yet copied anywhere. On the GPU path it holds the
// decoder's output surface; on the CPU path, a system-memory sample. Hold at
// most a couple at once: the decoder's surface pool is finite.
struct PreviewDecodedFrame {
  Microsoft::WRL::ComPtr<IMFSample> sample;
  std::int64_t ts_ms = 0;
};

class PreviewSourceReader {
 public:
  // `gpu_device` (optional) is the device the frames will be drawn with. When
  // it can decode (created with D3D11_CREATE_DEVICE_VIDEO_SUPPORT), the reader
  // decodes AND converts to BGRA on it, so a frame reaches the compositor
  // with a GPU copy instead of a system-memory round trip (issue #296: the
  // CPU path decodes 4K60 at ~28 fps on an i5-1135G7). Any failure on that
  // path falls back to the CPU reader; `gpu()` says which one you got.
  static std::unique_ptr<PreviewSourceReader> Create(
      const std::wstring& source_path, ID3D11Device* gpu_device = nullptr);

  // Seek so the next ReadNextFrame re-primes at `source_ms`. MF lands at the
  // nearest prior keyframe; the caller decodes forward and discards the lead-in
  // until the target frame is reached. Call at a RANGE boundary only.
  void SeekTo(std::int64_t source_ms);

  // Pull the next decoded frame forward into `out_bgra` (top-down, tightly
  // packed, width()*4*height() bytes) and report its recording-relative
  // timestamp in `out_ts_ms` (may be null). Returns false at end-of-stream or on
  // a decode failure. Never seeks.
  bool ReadNextFrame(std::vector<BYTE>* out_bgra, std::int64_t* out_ts_ms);

  // The zero-copy pair: decode the next frame without touching its pixels,
  // then copy it into `dst` (a width() x height() B8G8R8A8 texture on the
  // device the reader was created with, for the GPU path) when it is the one
  // to show. Lets a caller decoding forward to a target skip the copy for
  // every frame it discards. Same EOS / failure contract as ReadNextFrame.
  bool ReadNextSample(PreviewDecodedFrame* out);
  bool UploadFrame(const PreviewDecodedFrame& frame,
                   ID3D11DeviceContext* context, ID3D11Texture2D* dst) const;

  bool gpu() const { return gpu_; }

  // The source's duration (MF_PD_DURATION), 0 when the container does not
  // say. Read once at Create.
  std::int64_t duration_ms() const { return duration_ms_; }

  UINT width() const { return width_; }
  UINT height() const { return height_; }

 private:
  PreviewSourceReader() = default;

  Microsoft::WRL::ComPtr<IMFDXGIDeviceManager> device_manager_;
  Microsoft::WRL::ComPtr<IMFSourceReader> reader_;
  bool gpu_ = false;
  DWORD stream_index_ = 0;
  UINT width_ = 0;
  UINT height_ = 0;
  std::int64_t duration_ms_ = 0;
};

}  // namespace clingfy::preview

#endif  // RUNNER_PREVIEW_PREVIEW_SOURCE_READER_H_
