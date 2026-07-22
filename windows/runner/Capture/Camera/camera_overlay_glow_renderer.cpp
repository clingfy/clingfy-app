#include "Capture/Camera/camera_overlay_glow_renderer.h"

#include <d2d1_1helper.h>
#include <d2d1effects.h>

#include <algorithm>
#include <cmath>

#include "Capture/Camera/camera_bubble_painter.h"
#include "Capture/Camera/camera_overlay_glow.h"

namespace clingfy::capture {

namespace {

using Microsoft::WRL::ComPtr;

// macOS systemRed (light appearance): the glow's stroke and halo color.
constexpr float kGlowR = 1.0f;
constexpr float kGlowG = 59.0f / 255.0f;
constexpr float kGlowB = 48.0f / 255.0f;

// Stroke the ring outline onto the current target: the shared silhouette
// geometry when one exists, the plain rect for "square".
void StrokeRing(ID2D1DeviceContext* ctx, ID2D1Geometry* geo,
                const D2D1_RECT_F& rect, ID2D1SolidColorBrush* brush,
                float width) {
  if (geo != nullptr) {
    ctx->DrawGeometry(geo, brush, width);
  } else {
    ctx->DrawRectangle(rect, brush, width);
  }
}

}  // namespace

ComPtr<ID2D1Bitmap1> BakeCameraGlowBitmap(ID2D1Factory1* factory,
                                          ID2D1DeviceContext* ctx,
                                          const std::string& shape,
                                          double corner_radius,
                                          int content_side, int padding_px,
                                          double strength) {
  if (factory == nullptr || ctx == nullptr || content_side <= 0 ||
      padding_px < 0) {
    return nullptr;
  }
  const CameraGlowStyle glow = ResolveCameraGlowStyle(strength);
  const float lw = static_cast<float>(glow.line_width);
  const UINT dim = static_cast<UINT>(content_side + 2 * padding_px);
  if (dim == 0) {
    return nullptr;
  }

  // Ring path: the content square inset by lw/2 so the stroke hugs the inside
  // of the bubble outline (macOS cameraOverlayInsetRect parity). The rounding
  // fraction re-derives from the inset rect, matching the macOS getPath call.
  const float inset = std::min(lw / 2.0f, content_side / 2.0f);
  const D2D1_RECT_F ring_rect = D2D1::RectF(
      static_cast<float>(padding_px) + inset,
      static_cast<float>(padding_px) + inset,
      static_cast<float>(padding_px + content_side) - inset,
      static_cast<float>(padding_px + content_side) - inset);
  const ComPtr<ID2D1Geometry> ring_geo =
      CreateCameraShapeGeometry(factory, shape, corner_radius, ring_rect);

  const D2D1_BITMAP_PROPERTIES1 tprops = D2D1::BitmapProperties1(
      D2D1_BITMAP_OPTIONS_TARGET,
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                        D2D1_ALPHA_MODE_PREMULTIPLIED));

  // 1) The stroke silhouette at full alpha — the blur input.
  ComPtr<ID2D1Bitmap1> silhouette;
  if (FAILED(ctx->CreateBitmap(D2D1::SizeU(dim, dim), nullptr, 0, tprops,
                               silhouette.GetAddressOf()))) {
    return nullptr;
  }
  ComPtr<ID2D1SolidColorBrush> solid;
  if (FAILED(ctx->CreateSolidColorBrush(
          D2D1::ColorF(kGlowR, kGlowG, kGlowB, 1.0f),
          solid.GetAddressOf()))) {
    return nullptr;
  }
  ctx->SetTarget(silhouette.Get());
  ctx->BeginDraw();
  ctx->Clear(D2D1::ColorF(0.0f, 0.0f, 0.0f, 0.0f));
  StrokeRing(ctx, ring_geo.Get(), ring_rect, solid.Get(), lw);
  HRESULT hr = ctx->EndDraw();
  ctx->SetTarget(nullptr);
  if (FAILED(hr)) {
    return nullptr;
  }

  // 2) The halo: Gaussian blur of the stroke (stddev = radius/2, the same
  // mapping the painter's shadow bake uses).
  ComPtr<ID2D1Effect> blur;
  if (FAILED(ctx->CreateEffect(CLSID_D2D1GaussianBlur,
                               blur.GetAddressOf())) ||
      blur == nullptr) {
    return nullptr;
  }
  blur->SetInput(0, silhouette.Get());
  blur->SetValue(D2D1_GAUSSIANBLUR_PROP_STANDARD_DEVIATION,
                 static_cast<float>(glow.halo_radius * 0.5));
  ComPtr<ID2D1Image> halo;
  blur->GetOutput(halo.GetAddressOf());

  // 3) Composite halo (at halo_alpha) under the stroke (at stroke_alpha).
  ComPtr<ID2D1Bitmap1> baked;
  if (FAILED(ctx->CreateBitmap(D2D1::SizeU(dim, dim), nullptr, 0, tprops,
                               baked.GetAddressOf()))) {
    return nullptr;
  }
  ComPtr<ID2D1Layer> halo_layer;
  if (FAILED(ctx->CreateLayer(nullptr, halo_layer.GetAddressOf()))) {
    return nullptr;
  }
  ComPtr<ID2D1SolidColorBrush> stroke;
  if (FAILED(ctx->CreateSolidColorBrush(
          D2D1::ColorF(kGlowR, kGlowG, kGlowB,
                       static_cast<float>(glow.stroke_alpha)),
          stroke.GetAddressOf()))) {
    return nullptr;
  }
  ctx->SetTarget(baked.Get());
  ctx->BeginDraw();
  ctx->Clear(D2D1::ColorF(0.0f, 0.0f, 0.0f, 0.0f));
  if (halo != nullptr) {
    ctx->PushLayer(
        D2D1::LayerParameters1(D2D1::InfiniteRect(), nullptr,
                               D2D1_ANTIALIAS_MODE_PER_PRIMITIVE,
                               D2D1::Matrix3x2F::Identity(),
                               static_cast<float>(glow.halo_alpha)),
        halo_layer.Get());
    ctx->DrawImage(halo.Get());
    ctx->PopLayer();
  }
  StrokeRing(ctx, ring_geo.Get(), ring_rect, stroke.Get(), lw);
  hr = ctx->EndDraw();
  ctx->SetTarget(nullptr);
  if (FAILED(hr)) {
    return nullptr;
  }
  return baked;
}

}  // namespace clingfy::capture
