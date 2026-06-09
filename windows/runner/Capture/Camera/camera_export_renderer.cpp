#include "Capture/Camera/camera_export_renderer.h"

#include <d2d1_1helper.h>
// d2d1effects.h declares the built-in effect CLSIDs (CLSID_D2D1GaussianBlur);
// their GUID definitions come from dxguid.lib (linked in CMakeLists).
#include <d2d1effects.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <utility>

namespace clingfy::capture {

namespace {

using Microsoft::WRL::ComPtr;

constexpr DWORD kFirstVideoStream =
    static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);

// Build a mask/stroke geometry for `shape` inscribed in `rect`. Returns null for
// "square" (caller uses the rect directly) or on failure. corner_radius is the
// Dart 0..0.5 fraction off the shorter side; squircle reads as a generously
// rounded rect (true superellipse deferred).
ComPtr<ID2D1Geometry> CreateShapeGeometry(ID2D1Factory1* factory,
                                          const std::string& shape,
                                          double corner_radius,
                                          const D2D1_RECT_F& rect) {
  const double w = rect.right - rect.left;
  const double h = rect.bottom - rect.top;
  const double side = (w < h ? w : h);
  ComPtr<ID2D1Geometry> geo;
  if (shape == "circle") {
    const D2D1_POINT_2F c =
        D2D1::Point2F((rect.left + rect.right) / 2.0f,
                      (rect.top + rect.bottom) / 2.0f);
    ComPtr<ID2D1EllipseGeometry> ellipse;
    if (SUCCEEDED(factory->CreateEllipseGeometry(
            D2D1::Ellipse(c, static_cast<float>(w / 2.0),
                          static_cast<float>(h / 2.0)),
            ellipse.GetAddressOf()))) {
      ellipse.As(&geo);
    }
  } else if (shape == "roundedRect" || shape == "squircle") {
    double frac = corner_radius;
    if (shape == "squircle") {
      frac = (frac > 0.3 ? frac : 0.3);
    }
    frac = frac < 0.0 ? 0.0 : (frac > 0.5 ? 0.5 : frac);
    const double radius = std::min(frac * side, side / 2.0);
    if (radius > 0.0) {
      ComPtr<ID2D1RoundedRectangleGeometry> rrect;
      if (SUCCEEDED(factory->CreateRoundedRectangleGeometry(
              D2D1::RoundedRect(rect, static_cast<float>(radius),
                                static_cast<float>(radius)),
              rrect.GetAddressOf()))) {
        rrect.As(&geo);
      }
    }
  }
  return geo;  // null for square / zero-radius rounded → caller clips to rect
}

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
                                   const std::string& content_mode,
                                   const Style& style) {
  if (factory == nullptr || ctx == nullptr || bubble.width <= 0.0 ||
      bubble.height <= 0.0 || cam_w_ == 0 || cam_h_ == 0) {
    return false;
  }

  style_ = style;
  style_.opacity = style_.opacity < 0.0 ? 0.0 : (style_.opacity > 1.0 ? 1.0
                                                                      : style_.opacity);

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
  bubble_cx_ = static_cast<float>(bubble_cx);
  bubble_cy_ = static_cast<float>(bubble_cy);
  dest_rect_ = D2D1::RectF(static_cast<float>(bubble_cx - draw_w / 2.0),
                           static_cast<float>(bubble_cy - draw_h / 2.0),
                           static_cast<float>(bubble_cx + draw_w / 2.0),
                           static_cast<float>(bubble_cy + draw_h / 2.0));

  // Mask geometry by shape (canvas space). null for "square" → axis-aligned clip.
  mask_geometry_ =
      CreateShapeGeometry(factory, shape, corner_radius, bubble_rect_);
  if (mask_geometry_ != nullptr) {
    if (FAILED(ctx->CreateLayer(nullptr, mask_layer_.GetAddressOf()))) {
      // Fall back to the square clip rather than failing the whole camera draw.
      mask_geometry_.Reset();
      mask_layer_.Reset();
    }
  }

  // --- Phase 9.5 border. Stroke the bubble shape; soft-fail (no border) if the
  // brush can't be made or no color was supplied.
  if (style_.border_width > 0.0 && style_.has_border_color) {
    const float a = ((style_.border_argb >> 24) & 0xFF) / 255.0f;
    const float r = ((style_.border_argb >> 16) & 0xFF) / 255.0f;
    const float g = ((style_.border_argb >> 8) & 0xFF) / 255.0f;
    const float b = (style_.border_argb & 0xFF) / 255.0f;
    if (SUCCEEDED(ctx->CreateSolidColorBrush(D2D1::ColorF(r, g, b, a),
                                             border_brush_.GetAddressOf()))) {
      border_width_px_ = static_cast<float>(style_.border_width);
    }
  }

  // --- Phase 9.5 shadow. Bake a blurred silhouette of the bubble shape ONCE
  // (it's static), drawn behind the bubble every frame. Soft-fail leaves no
  // shadow. Done here (before the frame loop's BeginDraw) so the SetTarget round
  // trips don't collide with the per-frame target.
  PrepareShadow(factory, ctx, shape, corner_radius, side, bubble.x, bubble.y);

  ready_ = true;
  return true;
}

void CameraExportRenderer::PrepareShadow(ID2D1Factory1* factory,
                                         ID2D1DeviceContext* ctx,
                                         const std::string& shape,
                                         double corner_radius, double side,
                                         double bubble_x, double bubble_y) {
  const CameraShadowStyle sh = ResolveCameraShadowStyle(style_.shadow_preset);
  if (!sh.enabled) {
    return;
  }
  // Map the macOS blur radius to a D2D Gaussian standard deviation (~radius/2),
  // and pad the bake bitmap by 3σ so the tail isn't clipped.
  const double stddev = sh.blur_radius * 0.5;
  const double margin = std::ceil(stddev * 3.0) + border_width_px_ / 2.0 + 2.0;
  const UINT dim = static_cast<UINT>(std::ceil(side + 2.0 * margin));
  if (dim == 0) {
    return;
  }

  const D2D1_BITMAP_PROPERTIES1 tprops = D2D1::BitmapProperties1(
      D2D1_BITMAP_OPTIONS_TARGET,
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                        D2D1_ALPHA_MODE_PREMULTIPLIED));

  // 1) Render the shape silhouette (black @ shadow opacity) into a target.
  ComPtr<ID2D1Bitmap1> silhouette;
  if (FAILED(ctx->CreateBitmap(D2D1::SizeU(dim, dim), nullptr, 0, tprops,
                               silhouette.GetAddressOf()))) {
    return;
  }
  const D2D1_RECT_F local =
      D2D1::RectF(static_cast<float>(margin), static_cast<float>(margin),
                  static_cast<float>(margin + side),
                  static_cast<float>(margin + side));
  ComPtr<ID2D1Geometry> local_geo =
      CreateShapeGeometry(factory, shape, corner_radius, local);
  ComPtr<ID2D1SolidColorBrush> black;
  if (FAILED(ctx->CreateSolidColorBrush(
          D2D1::ColorF(0.0f, 0.0f, 0.0f, static_cast<float>(sh.opacity)),
          black.GetAddressOf()))) {
    return;
  }
  ctx->SetTarget(silhouette.Get());
  ctx->BeginDraw();
  ctx->Clear(D2D1::ColorF(0.0f, 0.0f, 0.0f, 0.0f));
  if (local_geo != nullptr) {
    ctx->FillGeometry(local_geo.Get(), black.Get());
  } else {
    ctx->FillRectangle(local, black.Get());
  }
  HRESULT hr = ctx->EndDraw();
  ctx->SetTarget(nullptr);
  if (FAILED(hr)) {
    return;
  }

  // 2) Blur it and bake the result into shadow_bitmap_.
  ComPtr<ID2D1Effect> blur;
  if (FAILED(ctx->CreateEffect(CLSID_D2D1GaussianBlur, blur.GetAddressOf())) ||
      blur == nullptr) {
    return;
  }
  blur->SetInput(0, silhouette.Get());
  blur->SetValue(D2D1_GAUSSIANBLUR_PROP_STANDARD_DEVIATION,
                 static_cast<float>(stddev));
  ComPtr<ID2D1Image> blur_out;
  blur->GetOutput(blur_out.GetAddressOf());

  ComPtr<ID2D1Bitmap1> baked;
  if (FAILED(ctx->CreateBitmap(D2D1::SizeU(dim, dim), nullptr, 0, tprops,
                               baked.GetAddressOf()))) {
    return;
  }
  ctx->SetTarget(baked.Get());
  ctx->BeginDraw();
  ctx->Clear(D2D1::ColorF(0.0f, 0.0f, 0.0f, 0.0f));
  if (blur_out != nullptr) {
    ctx->DrawImage(blur_out.Get());
  }
  hr = ctx->EndDraw();
  ctx->SetTarget(nullptr);
  if (FAILED(hr)) {
    return;
  }

  shadow_bitmap_ = baked;
  // The silhouette sits at [margin, margin] inside the bitmap, so drawing the
  // bitmap at (bubble - margin) lands the shape at the bubble; add the offset.
  const float ox = static_cast<float>(bubble_x - margin + sh.offset_x);
  const float oy = static_cast<float>(bubble_y - margin + sh.offset_y);
  shadow_dest_ = D2D1::RectF(ox, oy, ox + static_cast<float>(dim),
                             oy + static_cast<float>(dim));
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

  // 1) Shadow, behind everything (already offset + blurred, full alpha bitmap).
  if (shadow_bitmap_ != nullptr) {
    ctx->DrawBitmap(shadow_bitmap_.Get(), shadow_dest_, 1.0f,
                    D2D1_BITMAP_INTERPOLATION_MODE_LINEAR, nullptr);
  }

  // 2) Camera content, masked to the bubble shape, optionally mirrored, faded
  //    by the camera opacity. The mask layer/clip is captured under the identity
  //    transform; the mirror flip applies only to the content drawn inside it
  //    (the mask shapes are horizontally symmetric, so the mask is unaffected).
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

  if (style_.mirror) {
    // INVARIANT: this transform MUST stay axis-aligned-preserving (a pure
    // horizontal flip). The square path pushes an axis-aligned clip under the
    // identity transform above, and D2D only tolerates a still-axis-aligned
    // transform while that clip is active — a reflection qualifies, but adding
    // any rotation/shear here would put the context into an error state and fail
    // EndDraw for the whole export. Keep it a flip about the bubble center.
    ctx->SetTransform(D2D1::Matrix3x2F::Scale(
        D2D1::SizeF(-1.0f, 1.0f), D2D1::Point2F(bubble_cx_, bubble_cy_)));
  }
  ctx->DrawBitmap(frame_bitmap_.Get(), dest_rect_,
                  static_cast<float>(style_.opacity),
                  D2D1_BITMAP_INTERPOLATION_MODE_LINEAR, nullptr);
  if (style_.mirror) {
    ctx->SetTransform(D2D1::Matrix3x2F::Identity());
  }

  if (pushed_layer) {
    ctx->PopLayer();
  } else if (pushed_clip) {
    ctx->PopAxisAlignedClip();
  }

  // 3) Border, stroked on the bubble outline on top (not clipped by the mask).
  if (border_brush_ != nullptr && border_width_px_ > 0.0f) {
    if (mask_geometry_ != nullptr) {
      ctx->DrawGeometry(mask_geometry_.Get(), border_brush_.Get(),
                        border_width_px_);
    } else {
      ctx->DrawRectangle(bubble_rect_, border_brush_.Get(), border_width_px_);
    }
  }
}

}  // namespace clingfy::capture
