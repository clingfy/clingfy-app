#include "Capture/Camera/camera_export_renderer.h"

#include <d2d1_1helper.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>

#include <algorithm>
#include <cstring>
#include <utility>

namespace clingfy::capture {

namespace {

using Microsoft::WRL::ComPtr;

constexpr DWORD kFirstVideoStream =
    static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);

// Copy an RGB32 sample into a tightly-packed top-down BGRA buffer (pitch =
// width*4). Mirrors export_pipeline's ExtractTopDownBgra: prefer IMF2DBuffer's
// stride-aware lock, fall back to a contiguous buffer assumed top-down packed.
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
      const BYTE* src_row = scan0 + static_cast<LONG>(row) * stride;
      std::memcpy(dest->data() + row * row_bytes, src_row, row_bytes);
    }
    buffer2d->Unlock2D();
    return true;
  }

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

std::unique_ptr<CameraExportRenderer> CameraExportRenderer::Create(
    const std::wstring& camera_path, std::int64_t start_offset_ms) {
  if (camera_path.empty()) {
    return nullptr;
  }

  ComPtr<IMFAttributes> attrs;
  if (FAILED(::MFCreateAttributes(attrs.GetAddressOf(), 1))) {
    return nullptr;
  }
  attrs->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);

  ComPtr<IMFSourceReader> reader;
  if (FAILED(::MFCreateSourceReaderFromURL(camera_path.c_str(), attrs.Get(),
                                           reader.GetAddressOf())) ||
      reader == nullptr) {
    return nullptr;
  }

  reader->SetStreamSelection(
      static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS), FALSE);
  if (FAILED(reader->SetStreamSelection(kFirstVideoStream, TRUE))) {
    return nullptr;
  }

  // Negotiate BGRA (RGB32) output; the reader inserts a video processor.
  ComPtr<IMFMediaType> rgb_type;
  if (FAILED(::MFCreateMediaType(rgb_type.GetAddressOf()))) {
    return nullptr;
  }
  rgb_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  rgb_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
  if (FAILED(reader->SetCurrentMediaType(kFirstVideoStream, nullptr,
                                         rgb_type.Get()))) {
    return nullptr;
  }

  UINT32 w = 0;
  UINT32 h = 0;
  {
    ComPtr<IMFMediaType> current;
    if (FAILED(reader->GetCurrentMediaType(kFirstVideoStream,
                                           current.GetAddressOf())) ||
        FAILED(::MFGetAttributeSize(current.Get(), MF_MT_FRAME_SIZE, &w, &h)) ||
        w == 0 || h == 0) {
      return nullptr;
    }
  }

  auto renderer = std::unique_ptr<CameraExportRenderer>(
      new CameraExportRenderer());
  renderer->reader_ = std::move(reader);
  renderer->stream_index_ = kFirstVideoStream;
  renderer->cam_w_ = w;
  renderer->cam_h_ = h;
  renderer->start_offset_ms_ = start_offset_ms;
  return renderer;
}

bool CameraExportRenderer::Prepare(ID2D1Factory1* factory,
                                   ID2D1DeviceContext* ctx,
                                   const CameraBubbleRect& bubble,
                                   const std::string& shape,
                                   double corner_radius,
                                   const std::string& content_mode) {
  if (factory == nullptr || ctx == nullptr || bubble.width <= 0.0 ||
      bubble.height <= 0.0 || cam_w_ == 0 || cam_h_ == 0) {
    return false;
  }

  bubble_rect_ = D2D1::RectF(
      static_cast<float>(bubble.x), static_cast<float>(bubble.y),
      static_cast<float>(bubble.x + bubble.width),
      static_cast<float>(bubble.y + bubble.height));

  // Source bitmap holds the latest decoded camera frame (system-memory upload).
  const D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
      D2D1_BITMAP_OPTIONS_NONE,
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE));
  if (FAILED(ctx->CreateBitmap(D2D1::SizeU(cam_w_, cam_h_), nullptr, 0, props,
                               frame_bitmap_.GetAddressOf()))) {
    return false;
  }

  // Cover (fill) / contain (fit): scale the camera into the square bubble and
  // center it; the mask below clips the overflow for cover.
  const double side = bubble.width;  // square bubble
  const double cam_w = static_cast<double>(cam_w_);
  const double cam_h = static_cast<double>(cam_h_);
  const double scale = (content_mode == "fit")
                           ? std::min(side / cam_w, side / cam_h)
                           : std::max(side / cam_w, side / cam_h);
  const double draw_w = cam_w * scale;
  const double draw_h = cam_h * scale;
  const double bubble_cx = bubble.x + side / 2.0;
  const double bubble_cy = bubble.y + side / 2.0;
  dest_rect_ = D2D1::RectF(static_cast<float>(bubble_cx - draw_w / 2.0),
                           static_cast<float>(bubble_cy - draw_h / 2.0),
                           static_cast<float>(bubble_cx + draw_w / 2.0),
                           static_cast<float>(bubble_cy + draw_h / 2.0));

  // Mask geometry by shape. "square" needs none (axis-aligned clip handles it).
  if (shape == "circle") {
    ComPtr<ID2D1EllipseGeometry> ellipse;
    if (SUCCEEDED(factory->CreateEllipseGeometry(
            D2D1::Ellipse(D2D1::Point2F(static_cast<float>(bubble_cx),
                                        static_cast<float>(bubble_cy)),
                          static_cast<float>(side / 2.0),
                          static_cast<float>(side / 2.0)),
            ellipse.GetAddressOf()))) {
      ellipse.As(&mask_geometry_);
    }
  } else if (shape == "roundedRect" || shape == "squircle") {
    // corner_radius is the Dart 0..0.5 fraction. Map to pixels off the side; a
    // squircle reads as a generously rounded rect (true superellipse deferred).
    double frac = corner_radius;
    if (shape == "squircle") {
      frac = std::max(frac, 0.3);
    }
    frac = std::max(0.0, std::min(frac, 0.5));
    const double radius = std::min(frac * side, side / 2.0);
    if (radius > 0.0) {
      ComPtr<ID2D1RoundedRectangleGeometry> rrect;
      if (SUCCEEDED(factory->CreateRoundedRectangleGeometry(
              D2D1::RoundedRect(bubble_rect_, static_cast<float>(radius),
                                static_cast<float>(radius)),
              rrect.GetAddressOf()))) {
        rrect.As(&mask_geometry_);
      }
    }
  }
  // "square" (or a rounded radius of 0, or a geometry failure) → no mask; the
  // axis-aligned clip in Draw confines the bitmap to the bubble rect.

  if (mask_geometry_ != nullptr) {
    if (FAILED(ctx->CreateLayer(nullptr, mask_layer_.GetAddressOf()))) {
      // Fall back to the square clip rather than failing the whole camera draw.
      mask_geometry_.Reset();
      mask_layer_.Reset();
    }
  }

  ready_ = true;
  return true;
}

bool CameraExportRenderer::UploadSample(IMFSample* sample) {
  if (sample == nullptr || frame_bitmap_ == nullptr) {
    return false;
  }
  if (!ExtractTopDownBgra(sample, cam_w_, cam_h_, &scratch_)) {
    return false;
  }
  return SUCCEEDED(frame_bitmap_->CopyFromMemory(
      nullptr, scratch_.data(), static_cast<UINT32>(cam_w_) * 4u));
}

void CameraExportRenderer::Advance(std::int64_t frame_ms) {
  if (!ready_) {
    return;
  }

  const std::int64_t camera_ms =
      CameraTimeMsForFrame(frame_ms, start_offset_ms_);
  if (camera_ms < 0) {
    return;  // the camera hadn't started yet at this point in the recording
  }
  const std::int64_t camera_hns = camera_ms * 10000;

  // Pull the held frame forward to the latest camera frame at/<= camera_hns.
  while (!eos_) {
    if (has_pending_) {
      if (pending_pts_hns_ <= camera_hns) {
        if (UploadSample(pending_sample_.Get())) {
          has_held_frame_ = true;
        }
        has_pending_ = false;
        pending_sample_.Reset();
        continue;
      }
      break;  // pending frame is in the future; the held frame is current
    }
    DWORD flags = 0;
    LONGLONG ts = 0;
    ComPtr<IMFSample> sample;
    const HRESULT hr = reader_->ReadSample(stream_index_, 0, nullptr, &flags,
                                           &ts, sample.GetAddressOf());
    if (FAILED(hr)) {
      eos_ = true;
      break;
    }
    if (sample != nullptr) {
      // A source may deliver its final frame WITH the end-of-stream flag set on
      // the same call; park it as pending and let the loop evaluate it (the next
      // ReadSample then returns EOS with no sample and stops us). Dropping it
      // here would freeze the bubble one frame early.
      pending_sample_ = std::move(sample);
      pending_pts_hns_ = static_cast<std::int64_t>(ts);
      has_pending_ = true;
      continue;
    }
    // No sample: terminal EOS, or a stream tick (gap / format change) to skip.
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
      eos_ = true;
      break;
    }
    continue;
  }
}

void CameraExportRenderer::Draw(ID2D1DeviceContext* ctx) {
  if (!ready_ || ctx == nullptr || !has_held_frame_) {
    return;  // no camera frame available for this time yet
  }

  bool pushed_layer = false;
  bool pushed_clip = false;
  if (mask_geometry_ != nullptr && mask_layer_ != nullptr) {
    ctx->PushLayer(
        D2D1::LayerParameters1(D2D1::InfiniteRect(), mask_geometry_.Get(),
                               D2D1_ANTIALIAS_MODE_PER_PRIMITIVE),
        mask_layer_.Get());
    pushed_layer = true;
  } else {
    ctx->PushAxisAlignedClip(bubble_rect_, D2D1_ANTIALIAS_MODE_ALIASED);
    pushed_clip = true;
  }

  ctx->DrawBitmap(frame_bitmap_.Get(), dest_rect_, 1.0f,
                  D2D1_BITMAP_INTERPOLATION_MODE_LINEAR, nullptr);

  if (pushed_layer) {
    ctx->PopLayer();
  } else if (pushed_clip) {
    ctx->PopAxisAlignedClip();
  }
}

}  // namespace clingfy::capture
