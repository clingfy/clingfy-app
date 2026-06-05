#include "Encoding/gif_encoder.h"

#include <windows.h>
#include <propvarutil.h>

#include <cstring>
#include <utility>

#include "Capture/Export/gif_export_policy.h"
#include "Capture/captured_video_frame.h"
#include "Graphics/d3d_device.h"

namespace clingfy::encoding {

namespace {

using Microsoft::WRL::ComPtr;
using clingfy::capture::export_::GifDelayCentiseconds;
using clingfy::capture::export_::kGifDefaultDelayCentiseconds;

EncoderError MakeError(const char* message, HRESULT hr) {
  return EncoderError{std::string(message), hr};
}

std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) {
    return {};
  }
  const int needed = ::MultiByteToWideChar(
      CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
  if (needed <= 0) {
    return {};
  }
  std::wstring out(static_cast<size_t>(needed), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                        out.data(), needed);
  return out;
}

}  // namespace

GifEncoder::GifEncoder() = default;

GifEncoder::~GifEncoder() {
  ReleaseWic();
  staging_.Reset();
  if (com_initialized_by_us_) {
    ::CoUninitialize();
    com_initialized_by_us_ = false;
  }
}

void GifEncoder::ReleaseWic() {
  // Release in dependency order (encoder references the stream) before any
  // CoUninitialize in the destructor.
  encoder_.Reset();
  stream_.Reset();
  factory_.Reset();
}

std::optional<EncoderError> GifEncoder::Open(const EncoderConfig& config,
                                             clingfy::graphics::D3DDevice& device) {
  if (open_) {
    return MakeError("GifEncoder::Open called twice", E_UNEXPECTED);
  }
  if (config.width == 0 || config.height == 0) {
    return MakeError("GifEncoder: zero output dimensions", E_INVALIDARG);
  }
  if (config.output_path.empty()) {
    return MakeError("GifEncoder: empty output path", E_INVALIDARG);
  }
  config_ = config;
  device_ = &device;

  // Reset per-export state so an instance reused after Cancel() starts clean
  // (mirrors MfSinkWriterEncoder::Open, which re-initializes its state).
  has_pending_ = false;
  finalized_ = false;
  frames_written_ = 0;
  pending_bgra_.clear();
  staging_.Reset();
  staging_w_ = 0;
  staging_h_ = 0;

  // WIC needs COM. Initialize at most once per instance: S_OK / S_FALSE both
  // mean we hold a refcount to balance with CoUninitialize; RPC_E_CHANGED_MODE
  // means the thread already initialized COM in a different apartment (WIC still
  // works) so we must NOT balance it. Guarding with com_attempted_ keeps a
  // reuse-after-Cancel re-Open from double-counting the per-thread init.
  if (!com_attempted_) {
    const HRESULT co = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    com_initialized_by_us_ = SUCCEEDED(co);
    com_attempted_ = true;
  }

  HRESULT hr = ::CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                  CLSCTX_INPROC_SERVER,
                                  IID_PPV_ARGS(factory_.GetAddressOf()));
  if (FAILED(hr) || factory_ == nullptr) {
    return MakeError("GifEncoder: WIC factory creation failed", hr);
  }

  hr = factory_->CreateStream(stream_.GetAddressOf());
  if (FAILED(hr)) {
    return MakeError("GifEncoder: IWICStream creation failed", hr);
  }
  const std::wstring wpath = Utf8ToWide(config_.output_path);
  hr = stream_->InitializeFromFilename(wpath.c_str(), GENERIC_WRITE);
  if (FAILED(hr)) {
    return MakeError("GifEncoder: could not open the .gif file for writing", hr);
  }

  hr = factory_->CreateEncoder(GUID_ContainerFormatGif, nullptr,
                               encoder_.GetAddressOf());
  if (FAILED(hr)) {
    return MakeError("GifEncoder: WIC GIF encoder creation failed", hr);
  }
  hr = encoder_->Initialize(stream_.Get(), WICBitmapEncoderNoCache);
  if (FAILED(hr)) {
    return MakeError("GifEncoder: encoder Initialize failed", hr);
  }

  // Best-effort: a GIF without the loop extension just plays once instead of
  // looping forever — not worth failing the whole export over.
  (void)WriteLoopExtension();

  open_ = true;
  return std::nullopt;
}

std::optional<EncoderError> GifEncoder::WriteLoopExtension() {
  ComPtr<IWICMetadataQueryWriter> writer;
  HRESULT hr = encoder_->GetMetadataQueryWriter(writer.GetAddressOf());
  if (FAILED(hr) || writer == nullptr) {
    return MakeError("GifEncoder: encoder has no metadata writer", hr);
  }

  // Application Extension block: identifier must be exactly "NETSCAPE2.0".
  static const BYTE kApplication[] = {'N', 'E', 'T', 'S', 'C', 'A',
                                      'P', 'E', '2', '.', '0'};
  PROPVARIANT app;
  hr = ::InitPropVariantFromBuffer(kApplication,
                                   static_cast<UINT>(sizeof(kApplication)),
                                   &app);
  if (SUCCEEDED(hr)) {
    hr = writer->SetMetadataByName(L"/appext/Application", &app);
    ::PropVariantClear(&app);
  }
  if (FAILED(hr)) {
    return MakeError("GifEncoder: set NETSCAPE Application failed", hr);
  }

  // Data sub-block: {blockSize=3, subBlockId=1, loopCountLo, loopCountHi}.
  // Loop count 0 = loop forever.
  static const BYTE kData[] = {0x03, 0x01, 0x00, 0x00};
  PROPVARIANT data;
  hr = ::InitPropVariantFromBuffer(kData, static_cast<UINT>(sizeof(kData)),
                                   &data);
  if (SUCCEEDED(hr)) {
    hr = writer->SetMetadataByName(L"/appext/Data", &data);
    ::PropVariantClear(&data);
  }
  if (FAILED(hr)) {
    return MakeError("GifEncoder: set NETSCAPE Data failed", hr);
  }
  return std::nullopt;
}

std::optional<EncoderError> GifEncoder::ReadbackBgra(
    const clingfy::capture::CapturedVideoFrame& frame,
    std::vector<std::uint8_t>* out, UINT* out_w, UINT* out_h) {
  if (frame.texture == nullptr) {
    return MakeError("GifEncoder: frame has no texture", E_INVALIDARG);
  }
  ID3D11Device* dev = device_ != nullptr ? device_->device() : nullptr;
  ID3D11DeviceContext* ctx = device_ != nullptr ? device_->context() : nullptr;
  if (dev == nullptr || ctx == nullptr) {
    return MakeError("GifEncoder: D3D device not ready", E_UNEXPECTED);
  }

  const UINT w = frame.width;
  const UINT h = frame.height;
  if (w == 0 || h == 0) {
    return MakeError("GifEncoder: zero frame size", E_INVALIDARG);
  }

  if (staging_ == nullptr || staging_w_ != w || staging_h_ != h) {
    staging_.Reset();
    D3D11_TEXTURE2D_DESC desc{};
    desc.Width = w;
    desc.Height = h;
    desc.MipLevels = 1;
    desc.ArraySize = 1;
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.Usage = D3D11_USAGE_STAGING;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    const HRESULT hr =
        dev->CreateTexture2D(&desc, nullptr, staging_.GetAddressOf());
    if (FAILED(hr)) {
      return MakeError("GifEncoder: staging texture creation failed", hr);
    }
    staging_w_ = w;
    staging_h_ = h;
  }

  ctx->CopyResource(staging_.Get(), frame.texture.Get());
  D3D11_MAPPED_SUBRESOURCE map{};
  const HRESULT hr = ctx->Map(staging_.Get(), 0, D3D11_MAP_READ, 0, &map);
  if (FAILED(hr) || map.pData == nullptr) {
    return MakeError("GifEncoder: staging texture Map failed", hr);
  }
  const size_t row_bytes = static_cast<size_t>(w) * 4u;
  out->resize(row_bytes * h);
  const BYTE* src = static_cast<const BYTE*>(map.pData);
  for (UINT row = 0; row < h; ++row) {
    std::memcpy(out->data() + static_cast<size_t>(row) * row_bytes,
                src + static_cast<size_t>(row) * map.RowPitch, row_bytes);
  }
  ctx->Unmap(staging_.Get(), 0);
  *out_w = w;
  *out_h = h;
  return std::nullopt;
}

std::optional<EncoderError> GifEncoder::EncodeBufferedFrame(
    std::uint16_t delay_cs) {
  if (!has_pending_) {
    return std::nullopt;
  }
  const UINT w = pending_w_;
  const UINT h = pending_h_;

  ComPtr<IWICBitmapFrameEncode> frame;
  ComPtr<IPropertyBag2> props;
  HRESULT hr =
      encoder_->CreateNewFrame(frame.GetAddressOf(), props.GetAddressOf());
  if (FAILED(hr)) {
    return MakeError("GifEncoder: CreateNewFrame failed", hr);
  }
  hr = frame->Initialize(props.Get());
  if (FAILED(hr)) {
    return MakeError("GifEncoder: frame Initialize failed", hr);
  }
  hr = frame->SetSize(w, h);
  if (FAILED(hr)) {
    return MakeError("GifEncoder: frame SetSize failed", hr);
  }
  WICPixelFormatGUID pixel_format = GUID_WICPixelFormat8bppIndexed;
  hr = frame->SetPixelFormat(&pixel_format);
  if (FAILED(hr)) {
    return MakeError("GifEncoder: frame SetPixelFormat failed", hr);
  }

  // Wrap the readback buffer as a 32bpp BGRA source bitmap.
  ComPtr<IWICBitmap> source;
  hr = factory_->CreateBitmapFromMemory(
      w, h, GUID_WICPixelFormat32bppBGRA, static_cast<UINT>(w) * 4u,
      static_cast<UINT>(pending_bgra_.size()), pending_bgra_.data(),
      source.GetAddressOf());
  if (FAILED(hr)) {
    return MakeError("GifEncoder: CreateBitmapFromMemory failed", hr);
  }

  // Adaptive 256-color local color table for this frame.
  ComPtr<IWICPalette> palette;
  hr = factory_->CreatePalette(palette.GetAddressOf());
  if (FAILED(hr)) {
    return MakeError("GifEncoder: CreatePalette failed", hr);
  }
  hr = palette->InitializeFromBitmap(source.Get(), 256, FALSE);
  if (FAILED(hr)) {
    return MakeError("GifEncoder: palette InitializeFromBitmap failed", hr);
  }
  hr = frame->SetPalette(palette.Get());
  if (FAILED(hr)) {
    return MakeError("GifEncoder: frame SetPalette failed", hr);
  }

  // Quantize 32bpp BGRA -> 8bpp indexed against that palette, dithered.
  ComPtr<IWICFormatConverter> converter;
  hr = factory_->CreateFormatConverter(converter.GetAddressOf());
  if (FAILED(hr)) {
    return MakeError("GifEncoder: CreateFormatConverter failed", hr);
  }
  hr = converter->Initialize(source.Get(), GUID_WICPixelFormat8bppIndexed,
                             WICBitmapDitherTypeErrorDiffusion, palette.Get(),
                             0.0, WICBitmapPaletteTypeCustom);
  if (FAILED(hr)) {
    return MakeError("GifEncoder: format converter Initialize failed", hr);
  }

  // Per-frame delay (Graphic Control Extension). Best-effort: a GIF with no GCE
  // still decodes (viewers default the delay), so don't fail the frame over it.
  ComPtr<IWICMetadataQueryWriter> meta;
  if (SUCCEEDED(frame->GetMetadataQueryWriter(meta.GetAddressOf())) &&
      meta != nullptr) {
    PROPVARIANT delay;
    ::PropVariantInit(&delay);
    delay.vt = VT_UI2;
    delay.uiVal = delay_cs;
    meta->SetMetadataByName(L"/grctlext/Delay", &delay);
    ::PropVariantClear(&delay);
  }

  hr = frame->WriteSource(converter.Get(), nullptr);
  if (FAILED(hr)) {
    return MakeError("GifEncoder: frame WriteSource failed", hr);
  }
  hr = frame->Commit();
  if (FAILED(hr)) {
    return MakeError("GifEncoder: frame Commit failed", hr);
  }

  ++frames_written_;
  has_pending_ = false;
  return std::nullopt;
}

std::optional<EncoderError> GifEncoder::WriteVideoFrame(
    const clingfy::capture::CapturedVideoFrame& frame) {
  if (!open_) {
    return MakeError("GifEncoder: WriteVideoFrame before Open", E_UNEXPECTED);
  }
  if (finalized_) {
    return MakeError("GifEncoder: WriteVideoFrame after Finalize", E_UNEXPECTED);
  }
  // Mirror MfSinkWriterEncoder: silently drop a frame with no texture.
  if (frame.texture == nullptr) {
    return std::nullopt;
  }

  std::vector<std::uint8_t> current;
  UINT w = 0;
  UINT h = 0;
  if (auto err = ReadbackBgra(frame, &current, &w, &h)) {
    return err;
  }

  // Commit the previous frame now that we know the gap to this one.
  if (has_pending_) {
    const std::uint16_t delay =
        GifDelayCentiseconds(pending_ts_hns_, frame.timestamp_hns);
    if (auto err = EncodeBufferedFrame(delay)) {
      return err;
    }
  }

  pending_bgra_ = std::move(current);
  pending_w_ = w;
  pending_h_ = h;
  pending_ts_hns_ = frame.timestamp_hns;
  has_pending_ = true;
  return std::nullopt;
}

std::optional<EncoderError> GifEncoder::Finalize() {
  if (finalized_) {
    return std::nullopt;
  }
  if (!open_) {
    return MakeError("GifEncoder: Finalize before Open", E_UNEXPECTED);
  }
  // Flush the last buffered frame; it has no successor, so use the default delay.
  if (has_pending_) {
    if (auto err = EncodeBufferedFrame(kGifDefaultDelayCentiseconds)) {
      return err;
    }
  }
  if (frames_written_ == 0) {
    return MakeError("GifEncoder: no frames were written", E_FAIL);
  }
  const HRESULT hr = encoder_->Commit();
  if (FAILED(hr)) {
    return MakeError("GifEncoder: encoder Commit failed", hr);
  }
  finalized_ = true;
  return std::nullopt;
}

void GifEncoder::Cancel() {
  ReleaseWic();
  open_ = false;
}

}  // namespace clingfy::encoding
