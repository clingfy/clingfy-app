#include "Capture/Background/background_image_cache.h"

#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>

namespace clingfy::capture::background {

using Microsoft::WRL::ComPtr;

export_::RectF ComputeCoverSourceRect(export_::SizeF image,
                                      export_::SizeF canvas) {
  export_::RectF full{0.0, 0.0, image.width, image.height};
  if (!(image.width > 0.0) || !(image.height > 0.0) ||
      !(canvas.width > 0.0) || !(canvas.height > 0.0)) {
    return full;
  }

  // Cover: the larger of the two scales, so neither axis leaves a gap.
  const double scale = std::max(canvas.width / image.width,
                                canvas.height / image.height);

  // How much of the source is actually visible once scaled by `scale`.
  const double visible_w = std::min(image.width, canvas.width / scale);
  const double visible_h = std::min(image.height, canvas.height / scale);

  // Centre the visible window inside the source.
  return export_::RectF{(image.width - visible_w) * 0.5,
                        (image.height - visible_h) * 0.5, visible_w, visible_h};
}

std::int64_t FileWriteTime(const std::wstring& path) {
  if (path.empty()) return 0;
  WIN32_FILE_ATTRIBUTE_DATA data{};
  if (::GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &data) == 0) {
    return 0;
  }
  ULARGE_INTEGER t{};
  t.LowPart = data.ftLastWriteTime.dwLowDateTime;
  t.HighPart = data.ftLastWriteTime.dwHighDateTime;
  return static_cast<std::int64_t>(t.QuadPart);
}

namespace {

// Decode `path` to a premultiplied BGRA D2D bitmap. Returns nullptr on any
// failure — a missing or corrupt background is drawn as the background colour,
// never as a hard error, because it must not take the preview down.
ComPtr<ID2D1Bitmap> DecodeToD2DBitmap(ID2D1DeviceContext* ctx,
                                      const std::wstring& path) {
  if (ctx == nullptr || path.empty()) return nullptr;

  ComPtr<IWICImagingFactory> factory;
  if (FAILED(::CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&factory)))) {
    return nullptr;
  }

  ComPtr<IWICBitmapDecoder> decoder;
  if (FAILED(factory->CreateDecoderFromFilename(
          path.c_str(), nullptr, GENERIC_READ,
          WICDecodeMetadataCacheOnLoad, &decoder))) {
    return nullptr;
  }

  ComPtr<IWICBitmapFrameDecode> frame;
  if (FAILED(decoder->GetFrame(0, &frame))) return nullptr;

  // D2D wants premultiplied BGRA; the source could be anything (PNG with alpha,
  // JPEG, indexed GIF), so always run it through the converter.
  ComPtr<IWICFormatConverter> converter;
  if (FAILED(factory->CreateFormatConverter(&converter))) return nullptr;
  if (FAILED(converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppPBGRA,
                                   WICBitmapDitherTypeNone, nullptr, 0.0,
                                   WICBitmapPaletteTypeMedianCut))) {
    return nullptr;
  }

  ComPtr<ID2D1Bitmap> bitmap;
  if (FAILED(ctx->CreateBitmapFromWicBitmap(converter.Get(), nullptr,
                                            &bitmap))) {
    return nullptr;
  }
  return bitmap;
}

}  // namespace

ID2D1Bitmap* BackgroundImageCache::Get(ID2D1DeviceContext* ctx,
                                       const std::wstring& path) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (path.empty()) {
    bitmap_.Reset();
    cached_path_.clear();
    cached_write_time_ = 0;
    attempted_ = false;
    return nullptr;
  }

  const std::int64_t write_time = FileWriteTime(path);

  // Cache hit: same file, same mtime, already attempted. This is the branch
  // taken on every frame after the first — decoding here would put a static
  // image on the per-frame path.
  //
  // Keyed on `attempted_`, NOT on `bitmap_` being non-null: a missing or corrupt
  // file must be remembered as a null result, or a deleted background would be
  // re-decoded at playback rate.
  if (attempted_ && path == cached_path_ && write_time == cached_write_time_) {
    return bitmap_.Get();
  }

  ComPtr<ID2D1Bitmap> decoded = DecodeToD2DBitmap(ctx, path);
  ++decode_count_;
  bitmap_ = decoded;
  cached_path_ = path;
  cached_write_time_ = write_time;
  attempted_ = true;
  // Null on failure is cached too, so a missing file is not retried 60x/second.
  // A later edit changes the mtime (or the file appears) and re-triggers decode.
  return bitmap_.Get();
}

void BackgroundImageCache::Reset() {
  std::lock_guard<std::mutex> lock(mutex_);
  bitmap_.Reset();
  cached_path_.clear();
  cached_write_time_ = 0;
  // Clearing `attempted_` is what forces the next Get() back through decode
  // instead of handing back a bitmap that belonged to the destroyed context.
  attempted_ = false;
}

std::int64_t BackgroundImageCache::decode_count() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return decode_count_;
}

}  // namespace clingfy::capture::background
