#include "Capture/Camera/camera_bubble_painter.h"

#include <d2d1_1helper.h>
// d2d1effects.h declares the built-in effect CLSIDs (CLSID_D2D1GaussianBlur);
// d2d1effects_2.h adds CLSID_D2D1ChromaKey + D2D1_CHROMAKEY_PROP_*. Their GUID
// definitions come from dxguid.lib (linked in CMakeLists).
#include <d2d1effects.h>
#include <d2d1effects_2.h>

#include <algorithm>
#include <cmath>
#include <cstring>

namespace clingfy::capture {

using Microsoft::WRL::ComPtr;

namespace {

constexpr double kPi = 3.14159265358979323846;

// A sharp regular polygon / star path geometry inscribed in `rect` (centered,
// circum-radius = half the shorter side). `sides` vertices for a polygon; a
// star uses 2*`sides` vertices alternating outer / inner (= outer * inner_ratio)
// radius. Mirrors the GDI overlay's BuildPolygonRegion
// (camera_floating_overlay.cpp) and the Dart preview's _polygonPath / _starPath
// (lib/app/home/widgets/camera_overlay_bubble.dart) EXACTLY — same vertex
// count, rotation, inner ratio, and sharp corners — so the DComp bubble, the
// GDI bubble, the in-app preview, and the export all draw the identical
// silhouette. (This is DELIBERATELY the Windows/Dart convention, which differs
// from the macOS live overlay: macOS uses a pointy-top hexagon, a 0.4 star
// inner ratio, and roundness-driven corner rounding. Keep them in sync with
// BuildPolygonRegion if either changes.)
ComPtr<ID2D1Geometry> BuildCameraPolygonGeometry(ID2D1Factory1* factory,
                                                 const D2D1_RECT_F& rect,
                                                 int sides, double rotation,
                                                 double inner_ratio,
                                                 bool is_star) {
  const double cx = (rect.left + rect.right) / 2.0;
  const double cy = (rect.top + rect.bottom) / 2.0;
  const double radius =
      (std::min)(rect.right - rect.left, rect.bottom - rect.top) / 2.0;
  ComPtr<ID2D1Geometry> geo;
  if (radius <= 0.0 || sides < 3) {
    return geo;
  }
  const int vertices = is_star ? sides * 2 : sides;
  ComPtr<ID2D1PathGeometry> path;
  if (FAILED(factory->CreatePathGeometry(path.GetAddressOf()))) {
    return geo;
  }
  ComPtr<ID2D1GeometrySink> sink;
  if (FAILED(path->Open(sink.GetAddressOf()))) {
    return geo;
  }
  auto vertex = [&](int i) {
    const double r =
        is_star ? ((i % 2 == 0) ? radius : radius * inner_ratio) : radius;
    const double angle = rotation + (2.0 * kPi * i / vertices) - kPi / 2.0;
    return D2D1::Point2F(static_cast<float>(cx + r * std::cos(angle)),
                         static_cast<float>(cy + r * std::sin(angle)));
  };
  sink->BeginFigure(vertex(0), D2D1_FIGURE_BEGIN_FILLED);
  for (int i = 1; i < vertices; ++i) {
    sink->AddLine(vertex(i));
  }
  sink->EndFigure(D2D1_FIGURE_END_CLOSED);
  if (SUCCEEDED(sink->Close())) {
    path.As(&geo);
  }
  return geo;
}

}  // namespace

// Build a mask/stroke geometry for `shape` inscribed in `rect`. Returns null for
// "square" (caller uses the rect directly) or on failure. corner_radius is the
// Dart 0..0.5 fraction off the shorter side; squircle reads as a generously
// rounded rect (true superellipse deferred). hexagon / star are sharp polygons
// matching the GDI overlay + Dart preview (corner_radius is ignored for them,
// the Windows/Dart convention). Public (P4b) so the presenter's glow ring
// strokes the identical silhouette.
ComPtr<ID2D1Geometry> CreateCameraShapeGeometry(ID2D1Factory1* factory,
                                                const std::string& shape,
                                                double corner_radius,
                                                const D2D1_RECT_F& rect) {
  const double w = rect.right - rect.left;
  const double h = rect.bottom - rect.top;
  const double side = (w < h ? w : h);
  ComPtr<ID2D1Geometry> geo;
  if (shape == "circle") {
    const D2D1_POINT_2F c = D2D1::Point2F((rect.left + rect.right) / 2.0f,
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
  } else if (shape == "hexagon") {
    // Regular hexagon, rotation +30° (flat top/bottom, points left/right) —
    // BuildPolygonRegion(w, h, 6, kPi/6, 0, false) / Dart _polygonPath(6, π/6).
    geo = BuildCameraPolygonGeometry(factory, rect, /*sides=*/6,
                                     /*rotation=*/kPi / 6.0,
                                     /*inner_ratio=*/0.0, /*is_star=*/false);
  } else if (shape == "star") {
    // 5-point star, inner ratio 0.5, first point straight up —
    // BuildPolygonRegion(w, h, 5, 0, 0.5, true) / Dart _starPath(5, 0.5).
    geo = BuildCameraPolygonGeometry(factory, rect, /*sides=*/5,
                                     /*rotation=*/0.0,
                                     /*inner_ratio=*/0.5, /*is_star=*/true);
  }
  return geo;  // null for square / zero-radius rounded → caller clips to rect
}

bool ExtractCameraFrameBgra(IMFSample* sample, UINT width, UINT height,
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

bool CameraBubblePainter::Prepare(ID2D1Factory1* factory,
                                  ID2D1DeviceContext* ctx,
                                  const CameraBubbleRect& bubble,
                                  const std::string& shape,
                                  double corner_radius,
                                  const std::string& content_mode,
                                  const Style& style, UINT cam_w, UINT cam_h) {
  if (factory == nullptr || ctx == nullptr || bubble.width <= 0.0 ||
      bubble.height <= 0.0 || cam_w == 0 || cam_h == 0) {
    return false;
  }

  style_ = style;
  style_.opacity =
      style_.opacity < 0.0 ? 0.0 : (style_.opacity > 1.0 ? 1.0 : style_.opacity);
  cam_w_ = cam_w;
  cam_h_ = cam_h;

  bubble_rect_ = D2D1::RectF(static_cast<float>(bubble.x),
                             static_cast<float>(bubble.y),
                             static_cast<float>(bubble.x + bubble.width),
                             static_cast<float>(bubble.y + bubble.height));

  // Cover (fill) / contain (fit): scale the camera into the square bubble and
  // center it; the mask clips the overflow for cover.
  const double side = bubble.width;  // square bubble
  const double cw = static_cast<double>(cam_w);
  const double ch = static_cast<double>(cam_h);
  const double scale = (content_mode == "fit") ? std::min(side / cw, side / ch)
                                               : std::max(side / cw, side / ch);
  const double draw_w = cw * scale;
  const double draw_h = ch * scale;
  const double bubble_cx = bubble.x + side / 2.0;
  const double bubble_cy = bubble.y + side / 2.0;
  bubble_cx_ = static_cast<float>(bubble_cx);
  bubble_cy_ = static_cast<float>(bubble_cy);
  dest_rect_ = D2D1::RectF(static_cast<float>(bubble_cx - draw_w / 2.0),
                           static_cast<float>(bubble_cy - draw_h / 2.0),
                           static_cast<float>(bubble_cx + draw_w / 2.0),
                           static_cast<float>(bubble_cy + draw_h / 2.0));

  // Mask geometry by shape (canvas space). null for "square" → axis-aligned clip.
  // Reset the layer first: GetAddressOf() overwrites the raw pointer without
  // releasing, so re-Prepare (every composition change) would leak the old
  // ID2D1Layer otherwise.
  mask_layer_.Reset();
  mask_geometry_ =
      CreateCameraShapeGeometry(factory, shape, corner_radius, bubble_rect_);
  if (mask_geometry_ != nullptr) {
    if (FAILED(ctx->CreateLayer(nullptr, mask_layer_.GetAddressOf()))) {
      mask_geometry_.Reset();
      mask_layer_.Reset();
    }
  }

  // Border. Stroke the bubble shape; soft-fail (no border) if the brush can't be
  // made or no color was supplied.
  border_brush_.Reset();
  border_width_px_ = 0.0f;
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

  // Shadow. Bake a blurred silhouette of the bubble shape ONCE. Soft-fail leaves
  // no shadow.
  shadow_bitmap_.Reset();
  PrepareShadow(factory, ctx, shape, corner_radius, side, bubble.x, bubble.y);

  // Chroma key (Phase 9.7). Build the effect once; the enhanced draw path sets
  // its input per frame. Soft-fail (no effect) → the camera draws unkeyed.
  chroma_effect_.Reset();
  if (style_.chroma_enabled) {
    ComPtr<ID2D1Effect> fx;
    if (SUCCEEDED(ctx->CreateEffect(CLSID_D2D1ChromaKey, fx.GetAddressOf())) &&
        fx != nullptr) {
      float kr = 0.0f, kg = 1.0f, kb = 0.0f;  // default green screen
      if (style_.has_chroma_color) {
        kr = ((style_.chroma_argb >> 16) & 0xFF) / 255.0f;
        kg = ((style_.chroma_argb >> 8) & 0xFF) / 255.0f;
        kb = (style_.chroma_argb & 0xFF) / 255.0f;
      }
      const float tol = static_cast<float>(
          style_.chroma_strength < 0.0
              ? 0.0
              : (style_.chroma_strength > 1.0 ? 1.0 : style_.chroma_strength));
      fx->SetValue(D2D1_CHROMAKEY_PROP_COLOR, D2D1::Vector3F(kr, kg, kb));
      fx->SetValue(D2D1_CHROMAKEY_PROP_TOLERANCE, tol);
      fx->SetValue(D2D1_CHROMAKEY_PROP_INVERT_ALPHA, FALSE);
      fx->SetValue(D2D1_CHROMAKEY_PROP_FEATHER, TRUE);  // soften the matte edge
      chroma_effect_ = fx;
    }
  }

  // Opacity layer for the enhanced (keyed/animated) draw path. Soft-fail → the
  // enhanced path skips the opacity layer (square fallback) but still draws.
  content_layer_.Reset();
  ctx->CreateLayer(nullptr, content_layer_.GetAddressOf());

  ready_ = true;
  return true;
}

void CameraBubblePainter::PrepareShadow(ID2D1Factory1* factory,
                                        ID2D1DeviceContext* ctx,
                                        const std::string& shape,
                                        double corner_radius, double side,
                                        double bubble_x, double bubble_y) {
  const CameraShadowStyle sh = ResolveCameraShadowStyle(style_.shadow_preset);
  if (!sh.enabled) {
    return;
  }
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
      CreateCameraShapeGeometry(factory, shape, corner_radius, local);
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
  const float ox = static_cast<float>(bubble_x - margin + sh.offset_x);
  const float oy = static_cast<float>(bubble_y - margin + sh.offset_y);
  shadow_dest_ = D2D1::RectF(ox, oy, ox + static_cast<float>(dim),
                             oy + static_cast<float>(dim));
}

void CameraBubblePainter::Draw(ID2D1DeviceContext* ctx, ID2D1Bitmap1* source) {
  Draw(ctx, source, Frame{});
}

void CameraBubblePainter::Draw(ID2D1DeviceContext* ctx, ID2D1Bitmap1* source,
                               const Frame& frame) {
  if (!ready_ || ctx == nullptr || source == nullptr) {
    return;
  }

  // Anything to animate or key? If not, fall through to the Phase 9.6 fast path
  // below, which the inline preview's static bubble depends on staying identical.
  //
  // Compared with an epsilon, NOT exactly. The zoom smoother decays toward 1.0
  // asymptotically and never actually reaches it, so an exact `!= 1.0` meant
  // that after the first zoom of a clip every remaining frame took the enhanced
  // path (PushLayer + DrawImage + a per-frame transform) forever, and the
  // byte-identical static path was never re-entered. Sub-epsilon values are
  // visually indistinguishable anyway — a 1e-4 scale on a 200px bubble is
  // 0.02px.
  constexpr double kIdentityEpsilon = 1e-4;
  const bool animated = std::abs(frame.scale - 1.0) > kIdentityEpsilon ||
                        std::abs(frame.translate_x) > kIdentityEpsilon ||
                        std::abs(frame.translate_y) > kIdentityEpsilon ||
                        std::abs(frame.opacity_mul - 1.0) > kIdentityEpsilon;
  if (chroma_effect_ != nullptr || animated) {
    DrawEnhanced(ctx, source, frame);
    return;
  }

  // 1) Shadow, behind everything.
  if (shadow_bitmap_ != nullptr) {
    ctx->DrawBitmap(shadow_bitmap_.Get(), shadow_dest_, 1.0f,
                    D2D1_BITMAP_INTERPOLATION_MODE_LINEAR, nullptr);
  }

  // 2) Camera content, masked, optionally mirrored, faded by opacity.
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
    // INVARIANT: must stay axis-aligned-preserving (a pure horizontal flip) or
    // the square path's axis-aligned clip is invalidated and EndDraw fails.
    ctx->SetTransform(D2D1::Matrix3x2F::Scale(
        D2D1::SizeF(-1.0f, 1.0f), D2D1::Point2F(bubble_cx_, bubble_cy_)));
  }
  ctx->DrawBitmap(source, dest_rect_, static_cast<float>(style_.opacity),
                  D2D1_BITMAP_INTERPOLATION_MODE_LINEAR, nullptr);
  if (style_.mirror) {
    ctx->SetTransform(D2D1::Matrix3x2F::Identity());
  }

  if (pushed_layer) {
    ctx->PopLayer();
  } else if (pushed_clip) {
    ctx->PopAxisAlignedClip();
  }

  // 3) Border, stroked on the bubble outline (not clipped by the mask).
  if (border_brush_ != nullptr && border_width_px_ > 0.0f) {
    if (mask_geometry_ != nullptr) {
      ctx->DrawGeometry(mask_geometry_.Get(), border_brush_.Get(),
                        border_width_px_);
    } else {
      ctx->DrawRectangle(bubble_rect_, border_brush_.Get(), border_width_px_);
    }
  }
}

void CameraBubblePainter::DrawEnhanced(ID2D1DeviceContext* ctx,
                                       ID2D1Bitmap1* source,
                                       const Frame& frame) {
  using D2D1::Matrix3x2F;

  auto clamp01 = [](double v) {
    return static_cast<float>(v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v));
  };
  const float content_opacity = clamp01(style_.opacity * frame.opacity_mul);
  const float fade = clamp01(frame.opacity_mul);  // shadow + border fade only

  // Animation base transform: extra uniform scale about the bubble center, then
  // the canvas-space translation. Identity when frame is identity.
  const Matrix3x2F anim =
      Matrix3x2F::Scale(D2D1::SizeF(static_cast<float>(frame.scale),
                                    static_cast<float>(frame.scale)),
                        D2D1::Point2F(bubble_cx_, bubble_cy_)) *
      Matrix3x2F::Translation(static_cast<float>(frame.translate_x),
                              static_cast<float>(frame.translate_y));

  // 1) Shadow, behind everything, riding the animation transform + fade.
  if (shadow_bitmap_ != nullptr) {
    ctx->SetTransform(anim);
    ctx->DrawBitmap(shadow_bitmap_.Get(), shadow_dest_, fade,
                    D2D1_BITMAP_INTERPOLATION_MODE_LINEAR, nullptr);
    ctx->SetTransform(Matrix3x2F::Identity());
  }

  // 2) Camera content (optionally chroma-keyed), masked, mirrored, scaled into
  // the bubble, faded by an opacity layer.
  ID2D1Image* content = source;
  ComPtr<ID2D1Image> chroma_out;
  if (chroma_effect_ != nullptr) {
    chroma_effect_->SetInput(0, source);
    chroma_effect_->GetOutput(chroma_out.GetAddressOf());
    if (chroma_out != nullptr) {
      content = chroma_out.Get();
    }
  }

  // Map source-pixel space → the resting dest rect (cover/contain already baked
  // in), then mirror about the bubble center, then ride the animation transform.
  const float dest_w = dest_rect_.right - dest_rect_.left;
  const float dest_h = dest_rect_.bottom - dest_rect_.top;
  Matrix3x2F content_m =
      Matrix3x2F::Scale(D2D1::SizeF(dest_w / static_cast<float>(cam_w_),
                                    dest_h / static_cast<float>(cam_h_)),
                        D2D1::Point2F(0.0f, 0.0f)) *
      Matrix3x2F::Translation(dest_rect_.left, dest_rect_.top);
  if (style_.mirror) {
    content_m = content_m * Matrix3x2F::Scale(D2D1::SizeF(-1.0f, 1.0f),
                                              D2D1::Point2F(bubble_cx_,
                                                            bubble_cy_));
  }
  content_m = content_m * anim;

  bool pushed_layer = false;
  bool pushed_clip = false;
  // The mask geometry / clip is established in the animated bubble space so it
  // scales and translates with the content it bounds.
  ctx->SetTransform(anim);
  if (mask_geometry_ != nullptr && content_layer_ != nullptr) {
    ctx->PushLayer(
        D2D1::LayerParameters1(D2D1::InfiniteRect(), mask_geometry_.Get(),
                               D2D1_ANTIALIAS_MODE_PER_PRIMITIVE,
                               Matrix3x2F::Identity(), content_opacity),
        content_layer_.Get());
    pushed_layer = true;
  } else if (content_layer_ != nullptr) {
    ctx->PushAxisAlignedClip(bubble_rect_, D2D1_ANTIALIAS_MODE_ALIASED);
    ctx->PushLayer(
        D2D1::LayerParameters1(D2D1::InfiniteRect(), nullptr,
                               D2D1_ANTIALIAS_MODE_PER_PRIMITIVE,
                               Matrix3x2F::Identity(), content_opacity),
        content_layer_.Get());
    pushed_clip = true;
    pushed_layer = true;
  } else {
    // Layer creation soft-failed; clip only (opacity not applied in this rare
    // path, which only matters when style/anim opacity < 1).
    ctx->PushAxisAlignedClip(bubble_rect_, D2D1_ANTIALIAS_MODE_ALIASED);
    pushed_clip = true;
  }

  ctx->SetTransform(content_m);
  ctx->DrawImage(content, nullptr, nullptr, D2D1_INTERPOLATION_MODE_LINEAR,
                 D2D1_COMPOSITE_MODE_SOURCE_OVER);

  // Restore an axis-aligned transform before popping the clip (kept matched).
  ctx->SetTransform(anim);
  if (pushed_layer) {
    ctx->PopLayer();
  }
  if (pushed_clip) {
    ctx->PopAxisAlignedClip();
  }
  ctx->SetTransform(Matrix3x2F::Identity());

  // 3) Border, stroked on the (animated) bubble outline, faded with the bubble.
  if (border_brush_ != nullptr && border_width_px_ > 0.0f) {
    border_brush_->SetOpacity(fade);
    ctx->SetTransform(anim);
    if (mask_geometry_ != nullptr) {
      ctx->DrawGeometry(mask_geometry_.Get(), border_brush_.Get(),
                        border_width_px_);
    } else {
      ctx->DrawRectangle(bubble_rect_, border_brush_.Get(), border_width_px_);
    }
    ctx->SetTransform(Matrix3x2F::Identity());
    border_brush_->SetOpacity(1.0f);  // restore for the next frame's fast/enh path
  }
}

}  // namespace clingfy::capture
