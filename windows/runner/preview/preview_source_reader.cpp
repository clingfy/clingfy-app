#include "Preview/preview_source_reader.h"

#include <mfapi.h>
#include <mferror.h>
#include <propidl.h>

#include <algorithm>
#include <cstring>
#include <mutex>
#include <utility>

namespace clingfy::preview {

namespace {

using Microsoft::WRL::ComPtr;

constexpr DWORD kFirstVideoStream =
    static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);

// Idempotent MF startup (paired with MFShutdown only at process exit, like the
// export pipeline / encoder). Opening a reader must not churn global MF state.
void EnsureMediaFoundationStarted() {
  static std::once_flag flag;
  std::call_once(flag, [] { ::MFStartup(MF_VERSION, MFSTARTUP_LITE); });
}

// Copy one decoded BGRA frame into a top-down, tightly-packed buffer regardless
// of the source buffer's stride sign — Lock2D hands back a pointer to the top
// row plus a stride that may be negative for bottom-up layouts; indexing by
// `scan0 + row * stride` walks top-to-bottom either way. Mirrors the export's
// ExtractTopDownBgra. Returns false on lock failure.
bool ExtractTopDownBgra(IMFSample* sample, UINT width, UINT height,
                        std::vector<BYTE>* dest) {
  const size_t row_bytes = static_cast<size_t>(width) * 4u;
  dest->resize(row_bytes * height);

  ComPtr<IMFMediaBuffer> raw;
  if (FAILED(sample->GetBufferByIndex(0, raw.GetAddressOf())) ||
      raw == nullptr) {
    return false;
  }
  ComPtr<IMF2DBuffer> buffer2d;
  if (SUCCEEDED(raw.As(&buffer2d)) && buffer2d != nullptr) {
    BYTE* scan0 = nullptr;
    LONG stride = 0;
    if (FAILED(buffer2d->Lock2D(&scan0, &stride)) || scan0 == nullptr) {
      return false;
    }
    for (UINT row = 0; row < height; ++row) {
      std::memcpy(dest->data() + row * row_bytes,
                  scan0 + static_cast<LONG>(row) * stride, row_bytes);
    }
    buffer2d->Unlock2D();
    return true;
  }

  // Fallback: a plain contiguous buffer (top-down, tightly packed — the common
  // case for a Video-Processor RGB32 output).
  ComPtr<IMFMediaBuffer> contiguous;
  if (FAILED(sample->ConvertToContiguousBuffer(contiguous.GetAddressOf())) ||
      contiguous == nullptr) {
    return false;
  }
  BYTE* data = nullptr;
  DWORD max_len = 0;
  DWORD cur_len = 0;
  if (FAILED(contiguous->Lock(&data, &max_len, &cur_len)) || data == nullptr) {
    return false;
  }
  const size_t copy_bytes = (cur_len < dest->size()) ? cur_len : dest->size();
  std::memcpy(dest->data(), data, copy_bytes);
  contiguous->Unlock();
  return true;
}

}  // namespace

std::unique_ptr<PreviewSourceReader> PreviewSourceReader::Create(
    const std::wstring& source_path) {
  if (source_path.empty()) {
    return nullptr;
  }
  EnsureMediaFoundationStarted();

  ComPtr<IMFAttributes> attrs;
  if (FAILED(::MFCreateAttributes(attrs.GetAddressOf(), 1))) {
    return nullptr;
  }
  // Let the reader insert a video processor to convert NV12/etc → RGB32 in
  // system memory (no D3D binding needed — the pacer uploads to the
  // compositor).
  //
  // ADVANCED, not basic: measured on a 1080p60 recording, the advanced
  // processor decodes+converts at ~69 fps against the basic processor's
  // ~32-44 fps. That is the difference between tracking the audio master
  // clock and never catching it (the reported "laggy preview" — the source
  // runs at 57 fps, so the basic path could not keep up at all). Output
  // format and buffer layout are unchanged, so this is throughput-only.
  //
  // Deliberately NOT paired with MF_SOURCE_READER_D3D_MANAGER: measured at
  // ~1 fps, because every frame would then be read back GPU->CPU for the
  // compositor upload. Keeping frames on the GPU end to end is the real
  // win but needs the compositor's upload seam redesigned (issue #296).
  attrs->SetUINT32(MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, TRUE);

  ComPtr<IMFSourceReader> reader;
  if (FAILED(::MFCreateSourceReaderFromURL(source_path.c_str(), attrs.Get(),
                                           reader.GetAddressOf())) ||
      reader == nullptr) {
    return nullptr;
  }

  reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS),
                             FALSE);
  if (FAILED(reader->SetStreamSelection(kFirstVideoStream, TRUE))) {
    return nullptr;
  }

  ComPtr<IMFMediaType> rgb;
  if (FAILED(::MFCreateMediaType(rgb.GetAddressOf()))) {
    return nullptr;
  }
  rgb->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  rgb->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
  if (FAILED(reader->SetCurrentMediaType(kFirstVideoStream, nullptr,
                                         rgb.Get()))) {
    return nullptr;
  }

  UINT w = 0;
  UINT h = 0;
  {
    ComPtr<IMFMediaType> current;
    if (FAILED(reader->GetCurrentMediaType(kFirstVideoStream,
                                           current.GetAddressOf())) ||
        FAILED(::MFGetAttributeSize(current.Get(), MF_MT_FRAME_SIZE, &w, &h)) ||
        w == 0 || h == 0) {
      return nullptr;
    }
  }

  auto self =
      std::unique_ptr<PreviewSourceReader>(new PreviewSourceReader());
  self->reader_ = std::move(reader);
  self->stream_index_ = kFirstVideoStream;
  self->width_ = w;
  self->height_ = h;
  return self;
}

void PreviewSourceReader::SeekTo(std::int64_t source_ms) {
  if (reader_ == nullptr) {
    return;
  }
  PROPVARIANT pos;
  PropVariantInit(&pos);
  pos.vt = VT_I8;
  pos.hVal.QuadPart = std::max<std::int64_t>(0, source_ms) * 10000;
  reader_->SetCurrentPosition(GUID_NULL, pos);
  PropVariantClear(&pos);
}

bool PreviewSourceReader::ReadNextFrame(std::vector<BYTE>* out_bgra,
                                        std::int64_t* out_ts_ms) {
  if (reader_ == nullptr || out_bgra == nullptr) {
    return false;
  }
  for (;;) {
    DWORD flags = 0;
    LONGLONG ts = 0;
    ComPtr<IMFSample> sample;
    if (FAILED(reader_->ReadSample(stream_index_, 0, nullptr, &flags, &ts,
                                   sample.GetAddressOf()))) {
      return false;
    }
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
      return false;
    }
    if (sample == nullptr) {
      continue;  // stream tick (gap / format change)
    }
    if (!ExtractTopDownBgra(sample.Get(), width_, height_, out_bgra)) {
      return false;
    }
    if (out_ts_ms != nullptr) {
      *out_ts_ms = static_cast<std::int64_t>(ts) / 10000;
    }
    return true;
  }
}

}  // namespace clingfy::preview
