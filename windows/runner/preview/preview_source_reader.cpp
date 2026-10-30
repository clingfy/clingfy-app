#include "Preview/preview_source_reader.h"

#include <mfapi.h>
#include <mferror.h>
#include <mfobjects.h>
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

// Open the reader. With `manager`, the decoder and the colour converter run on
// that device and samples come back as DXGI surfaces in ARGB32 (B8G8R8A8, the
// compositor's own format, so a GPU copy is legal); without it they come back
// as RGB32 system memory.
ComPtr<IMFSourceReader> OpenReader(const std::wstring& source_path,
                                   IMFDXGIDeviceManager* manager, UINT* w,
                                   UINT* h) {
  ComPtr<IMFAttributes> attrs;
  if (FAILED(::MFCreateAttributes(attrs.GetAddressOf(), 3))) {
    return nullptr;
  }
  // Let the reader insert a video processor to convert NV12/etc → BGRA.
  //
  // ADVANCED, not basic: measured on a 1080p60 recording, the advanced
  // processor decodes+converts at ~69 fps against the basic processor's
  // ~32-44 fps on the CPU path. That is the difference between tracking the
  // audio master clock and never catching it. On the GPU path it is what
  // does the conversion on the device.
  attrs->SetUINT32(MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, TRUE);
  if (manager != nullptr) {
    // A device manager alone measured ~1 fps here, because every frame was
    // then read back GPU -> CPU for the old system-memory upload. The GPU
    // path never reads back: UploadFrame copies surface to surface.
    attrs->SetUnknown(MF_SOURCE_READER_D3D_MANAGER, manager);
    attrs->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
  }

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
  rgb->SetGUID(MF_MT_SUBTYPE, manager != nullptr ? MFVideoFormat_ARGB32
                                                 : MFVideoFormat_RGB32);
  if (FAILED(reader->SetCurrentMediaType(kFirstVideoStream, nullptr,
                                         rgb.Get()))) {
    return nullptr;
  }
  ComPtr<IMFMediaType> current;
  if (FAILED(reader->GetCurrentMediaType(kFirstVideoStream,
                                         current.GetAddressOf())) ||
      FAILED(::MFGetAttributeSize(current.Get(), MF_MT_FRAME_SIZE, w, h)) ||
      *w == 0 || *h == 0) {
    return nullptr;
  }
  return reader;
}

std::int64_t ReaderDurationMs(IMFSourceReader* reader) {
  PROPVARIANT var;
  PropVariantInit(&var);
  std::int64_t ms = 0;
  if (SUCCEEDED(reader->GetPresentationAttribute(
          static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE), MF_PD_DURATION,
          &var)) &&
      var.vt == VT_UI8) {
    ms = static_cast<std::int64_t>(var.uhVal.QuadPart / 10000);
  }
  PropVariantClear(&var);
  return ms;
}

// The decoder surface behind a GPU-path sample, or null for a CPU sample.
ComPtr<ID3D11Texture2D> SampleTexture(IMFSample* sample, UINT* subresource) {
  ComPtr<IMFMediaBuffer> buffer;
  if (sample == nullptr ||
      FAILED(sample->GetBufferByIndex(0, buffer.GetAddressOf()))) {
    return nullptr;
  }
  ComPtr<IMFDXGIBuffer> dxgi;
  if (FAILED(buffer.As(&dxgi)) || dxgi == nullptr) {
    return nullptr;
  }
  ComPtr<ID3D11Texture2D> texture;
  if (FAILED(dxgi->GetResource(IID_PPV_ARGS(texture.GetAddressOf())))) {
    return nullptr;
  }
  if (FAILED(dxgi->GetSubresourceIndex(subresource))) {
    *subresource = 0;
  }
  return texture;
}

}  // namespace

std::unique_ptr<PreviewSourceReader> PreviewSourceReader::Create(
    const std::wstring& source_path, ID3D11Device* gpu_device) {
  if (source_path.empty()) {
    return nullptr;
  }
  EnsureMediaFoundationStarted();

  auto self =
      std::unique_ptr<PreviewSourceReader>(new PreviewSourceReader());
  UINT w = 0;
  UINT h = 0;
  if (gpu_device != nullptr) {
    UINT token = 0;
    ComPtr<IMFDXGIDeviceManager> manager;
    if (SUCCEEDED(::MFCreateDXGIDeviceManager(&token,
                                              manager.GetAddressOf())) &&
        SUCCEEDED(manager->ResetDevice(gpu_device, token))) {
      if (auto reader = OpenReader(source_path, manager.Get(), &w, &h)) {
        // Probe one frame: drivers that accept the manager and then fail or
        // hand back system memory are not rare, and the GPU path must only
        // be taken when the copy it relies on is legal.
        DWORD flags = 0;
        LONGLONG ts = 0;
        ComPtr<IMFSample> probe;
        if (SUCCEEDED(reader->ReadSample(kFirstVideoStream, 0, nullptr,
                                         &flags, &ts, probe.GetAddressOf())) &&
            probe != nullptr) {
          UINT sub = 0;
          const ComPtr<ID3D11Texture2D> tex = SampleTexture(probe.Get(), &sub);
          D3D11_TEXTURE2D_DESC desc{};
          if (tex != nullptr) {
            tex->GetDesc(&desc);
          }
          if (tex != nullptr && desc.Format == DXGI_FORMAT_B8G8R8A8_UNORM &&
              desc.Width >= w && desc.Height >= h) {
            self->device_manager_ = std::move(manager);
            self->reader_ = std::move(reader);
            self->gpu_ = true;
          }
        }
      }
    }
  }
  if (self->gpu_) {
    self->stream_index_ = kFirstVideoStream;
    self->width_ = w;
    self->height_ = h;
    self->duration_ms_ = ReaderDurationMs(self->reader_.Get());
    self->SeekTo(0);  // undo the probe read
    return self;
  }
  auto reader = OpenReader(source_path, nullptr, &w, &h);
  if (reader == nullptr) {
    return nullptr;
  }
  self->reader_ = std::move(reader);
  self->stream_index_ = kFirstVideoStream;
  self->width_ = w;
  self->height_ = h;
  self->duration_ms_ = ReaderDurationMs(self->reader_.Get());
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

bool PreviewSourceReader::ReadNextSample(PreviewDecodedFrame* out) {
  if (reader_ == nullptr || out == nullptr) {
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
    out->sample = std::move(sample);
    out->ts_ms = static_cast<std::int64_t>(ts) / 10000;
    return true;
  }
}

bool PreviewSourceReader::UploadFrame(const PreviewDecodedFrame& frame,
                                      ID3D11DeviceContext* context,
                                      ID3D11Texture2D* dst) const {
  if (frame.sample == nullptr || context == nullptr || dst == nullptr) {
    return false;
  }
  if (gpu_) {
    UINT sub = 0;
    const ComPtr<ID3D11Texture2D> src = SampleTexture(frame.sample.Get(), &sub);
    if (src == nullptr) {
      return false;
    }
    // Decoder surfaces are often padded (1080 -> 1088 rows): copy the
    // picture only.
    const D3D11_BOX box{0, 0, 0, width_, height_, 1};
    context->CopySubresourceRegion(dst, 0, 0, 0, 0, src.Get(), sub, &box);
    return true;
  }
  std::vector<BYTE> bgra;
  if (!ExtractTopDownBgra(frame.sample.Get(), width_, height_, &bgra)) {
    return false;
  }
  context->UpdateSubresource(dst, 0, nullptr, bgra.data(), width_ * 4u, 0);
  return true;
}

bool PreviewSourceReader::ReadNextFrame(std::vector<BYTE>* out_bgra,
                                        std::int64_t* out_ts_ms) {
  if (out_bgra == nullptr) {
    return false;
  }
  PreviewDecodedFrame frame;
  if (!ReadNextSample(&frame)) {
    return false;
  }
  // On the GPU path this reads the surface back: fine for tests and one-off
  // reads, which is all that still calls it.
  if (!ExtractTopDownBgra(frame.sample.Get(), width_, height_, out_bgra)) {
    return false;
  }
  if (out_ts_ms != nullptr) {
    *out_ts_ms = frame.ts_ms;
  }
  return true;
}

}  // namespace clingfy::preview
