#ifndef RUNNER_PREVIEW_PREVIEW_SOURCE_READER_H_
#define RUNNER_PREVIEW_PREVIEW_SOURCE_READER_H_

#include <windows.h>
// mfidl.h (IMFSample / IMFSourceReader deps) MUST precede mfreadwrite.h.
#include <mfidl.h>
#include <mfreadwrite.h>
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

class PreviewSourceReader {
 public:
  static std::unique_ptr<PreviewSourceReader> Create(
      const std::wstring& source_path);

  // Seek so the next ReadNextFrame re-primes at `source_ms`. MF lands at the
  // nearest prior keyframe; the caller decodes forward and discards the lead-in
  // until the target frame is reached. Call at a RANGE boundary only.
  void SeekTo(std::int64_t source_ms);

  // Pull the next decoded frame forward into `out_bgra` (top-down, tightly
  // packed, width()*4*height() bytes) and report its recording-relative
  // timestamp in `out_ts_ms` (may be null). Returns false at end-of-stream or on
  // a decode failure. Never seeks.
  bool ReadNextFrame(std::vector<BYTE>* out_bgra, std::int64_t* out_ts_ms);

  UINT width() const { return width_; }
  UINT height() const { return height_; }

 private:
  PreviewSourceReader() = default;

  Microsoft::WRL::ComPtr<IMFSourceReader> reader_;
  DWORD stream_index_ = 0;
  UINT width_ = 0;
  UINT height_ = 0;
};

}  // namespace clingfy::preview

#endif  // RUNNER_PREVIEW_PREVIEW_SOURCE_READER_H_
