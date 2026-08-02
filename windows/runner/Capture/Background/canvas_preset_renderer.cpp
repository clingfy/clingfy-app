#include "Capture/Background/canvas_preset_renderer.h"

#include <d2d1effects.h>

#include <algorithm>
#include <cmath>
#include <sstream>
#include <vector>

#include "Capture/Background/abstract_waves_params.h"
#include "Capture/Background/canvas_preset_params.h"
#include "Capture/Background/background_preset_catalog.h"

namespace clingfy::capture::background {

using Microsoft::WRL::ComPtr;

namespace {

D2D1_COLOR_F ArgbToColor(std::uint32_t argb, double alpha_override = -1.0) {
  const float a = static_cast<float>((argb >> 24) & 0xFF) / 255.0f;
  const float r = static_cast<float>((argb >> 16) & 0xFF) / 255.0f;
  const float g = static_cast<float>((argb >> 8) & 0xFF) / 255.0f;
  const float b = static_cast<float>(argb & 0xFF) / 255.0f;
  return D2D1::ColorF(r, g, b,
                      alpha_override >= 0.0 ? static_cast<float>(alpha_override)
                                            : a);
}

// Pass 1: tilted linear gradient across the palette, evenly spaced.
void DrawBaseGradient(ID2D1DeviceContext* ctx, float w, float h,
                      const BackgroundPalette& palette, double tilt) {
  std::vector<D2D1_GRADIENT_STOP> stops;
  stops.reserve(palette.colors_argb.size());
  const size_t count = palette.colors_argb.size();
  for (size_t i = 0; i < count; ++i) {
    D2D1_GRADIENT_STOP s{};
    s.position = count <= 1 ? 0.0f
                            : static_cast<float>(i) /
                                  static_cast<float>(count - 1);
    s.color = ArgbToColor(palette.colors_argb[i]);
    stops.push_back(s);
  }

  ComPtr<ID2D1GradientStopCollection> collection;
  if (FAILED(ctx->CreateGradientStopCollection(
          stops.data(), static_cast<UINT32>(stops.size()), D2D1_GAMMA_2_2,
          D2D1_EXTEND_MODE_CLAMP, &collection))) {
    // Fall back to the darkest stop rather than leaving the canvas empty.
    ComPtr<ID2D1SolidColorBrush> flat;
    if (SUCCEEDED(ctx->CreateSolidColorBrush(
            ArgbToColor(palette.colors_argb.front()), &flat))) {
      ctx->FillRectangle(D2D1::RectF(0, 0, w, h), flat.Get());
    }
    return;
  }

  // macOS: start (minX, maxY), end (maxX, minY + height*tilt), bottom-left
  // origin. Flipped to D2D's top-left origin here.
  const D2D1_POINT_2F start = D2D1::Point2F(0.0f, 0.0f);
  const D2D1_POINT_2F end =
      D2D1::Point2F(w, h - h * static_cast<float>(tilt));

  ComPtr<ID2D1LinearGradientBrush> brush;
  if (FAILED(ctx->CreateLinearGradientBrush(
          D2D1::LinearGradientBrushProperties(start, end), collection.Get(),
          &brush))) {
    return;
  }
  ctx->FillRectangle(D2D1::RectF(0, 0, w, h), brush.Get());
}

// Pass 2: one wave ribbon, filled from the wave line down to the bottom of the
// canvas (macOS fills from the wave to y=0 in its bottom-left space).
void DrawWaveRibbon(ID2D1DeviceContext* ctx, ID2D1Factory* factory, float w,
                    float h, const WaveRibbonParams& ribbon,
                    std::uint32_t color_argb) {
  ComPtr<ID2D1PathGeometry> geometry;
  if (FAILED(factory->CreatePathGeometry(&geometry))) return;
  ComPtr<ID2D1GeometrySink> sink;
  if (FAILED(geometry->Open(&sink))) return;

  // Step count matches macOS: max(48, width/14).
  const int steps = std::max(48, static_cast<int>(w / 14.0f));
  const double baseline = h * ribbon.baseline_fraction;

  // Start at the bottom-left corner (macOS (0,0) -> D2D (0,h)).
  sink->BeginFigure(D2D1::Point2F(0.0f, h), D2D1_FIGURE_BEGIN_FILLED);
  for (int i = 0; i <= steps; ++i) {
    const double t = static_cast<double>(i) / static_cast<double>(steps);
    const double x = t * w;
    const double wave = SampleRibbonWave(ribbon, t) * h;
    // Flip: macOS y = baseline + wave, measured up from the bottom.
    const double y = h - (baseline + wave);
    sink->AddLine(
        D2D1::Point2F(static_cast<float>(x), static_cast<float>(y)));
  }
  // Close through the bottom-right corner (macOS (w,0)).
  sink->AddLine(D2D1::Point2F(w, h));
  sink->EndFigure(D2D1_FIGURE_END_CLOSED);
  if (FAILED(sink->Close())) return;

  ComPtr<ID2D1SolidColorBrush> brush;
  if (FAILED(ctx->CreateSolidColorBrush(ArgbToColor(color_argb, ribbon.alpha),
                                        &brush))) {
    return;
  }
  ctx->FillGeometry(geometry.Get(), brush.Get());
}

// Pass 3: radial white glow, opaque-ish at the centre fading to transparent.
void DrawGlow(ID2D1DeviceContext* ctx, float w, float h,
              const GlowParams& glow) {
  const D2D1_GRADIENT_STOP stops[2] = {
      {0.0f, D2D1::ColorF(1.0f, 1.0f, 1.0f, static_cast<float>(glow.alpha))},
      {1.0f, D2D1::ColorF(1.0f, 1.0f, 1.0f, 0.0f)},
  };
  ComPtr<ID2D1GradientStopCollection> collection;
  if (FAILED(ctx->CreateGradientStopCollection(stops, 2, D2D1_GAMMA_2_2,
                                               D2D1_EXTEND_MODE_CLAMP,
                                               &collection))) {
    return;
  }

  const float cx = w * static_cast<float>(glow.center_x_fraction);
  // Flip: macOS measures the centre up from the bottom.
  const float cy = h - h * static_cast<float>(glow.center_y_fraction);
  const float radius =
      std::min(w, h) * static_cast<float>(glow.radius_fraction);
  if (!(radius > 0.0f)) return;

  ComPtr<ID2D1RadialGradientBrush> brush;
  if (FAILED(ctx->CreateRadialGradientBrush(
          D2D1::RadialGradientBrushProperties(D2D1::Point2F(cx, cy),
                                              D2D1::Point2F(0, 0), radius,
                                              radius),
          collection.Get(), &brush))) {
    return;
  }
  ctx->FillRectangle(D2D1::RectF(0, 0, w, h), brush.Get());
}

// A radial blob/glow: `color` at `alpha` in the centre, fading to fully
// transparent at `radius`. Shared by graphicMesh and radialGlow — they differ
// in how many, how big, how opaque, and what is underneath, not in the shape.
void DrawRadialBlob(ID2D1DeviceContext* ctx, float w, float h, double cx_frac,
                    double cy_frac, double radius_frac, double alpha,
                    std::uint32_t color_argb) {
  const D2D1_GRADIENT_STOP stops[2] = {
      {0.0f, ArgbToColor(color_argb, alpha)},
      {1.0f, ArgbToColor(color_argb, 0.0)},
  };
  ComPtr<ID2D1GradientStopCollection> collection;
  if (FAILED(ctx->CreateGradientStopCollection(stops, 2, D2D1_GAMMA_2_2,
                                               D2D1_EXTEND_MODE_CLAMP,
                                               &collection))) {
    return;
  }

  const float cx = w * static_cast<float>(cx_frac);
  // Flip: macOS measures y up from the bottom, D2D down from the top.
  const float cy = h - h * static_cast<float>(cy_frac);
  const float radius = std::min(w, h) * static_cast<float>(radius_frac);
  if (!(radius > 0.0f)) return;

  ComPtr<ID2D1RadialGradientBrush> brush;
  if (FAILED(ctx->CreateRadialGradientBrush(
          D2D1::RadialGradientBrushProperties(D2D1::Point2F(cx, cy),
                                              D2D1::Point2F(0, 0), radius,
                                              radius),
          collection.Get(), &brush))) {
    return;
  }
  ctx->FillRectangle(D2D1::RectF(0, 0, w, h), brush.Get());
}

// `graphicMesh`: a base fill in the darkest palette colour, then large soft
// blobs scattered (and bleeding off) the edges.
void DrawGraphicMesh(ID2D1DeviceContext* ctx, float w, float h,
                     const BackgroundPalette& palette,
                     const GraphicMeshParams& params) {
  ComPtr<ID2D1SolidColorBrush> base;
  if (SUCCEEDED(ctx->CreateSolidColorBrush(
          ArgbToColor(palette.colors_argb.front()), &base))) {
    ctx->FillRectangle(D2D1::RectF(0, 0, w, h), base.Get());
  }
  for (const auto& blob : params.blobs) {
    const std::uint32_t color =
        palette.colors_argb[static_cast<size_t>(blob.palette_index) %
                            palette.colors_argb.size()];
    DrawRadialBlob(ctx, w, h, blob.center_x_fraction, blob.center_y_fraction,
                   blob.radius_fraction, blob.alpha, color);
  }
}

// `radialGlow`: a full-palette diagonal gradient lit by three faint glows.
void DrawRadialGlowPreset(ID2D1DeviceContext* ctx, float w, float h,
                          const BackgroundPalette& palette,
                          const RadialGlowParams& params) {
  std::vector<D2D1_GRADIENT_STOP> stops;
  const size_t count = palette.colors_argb.size();
  stops.reserve(count);
  for (size_t i = 0; i < count; ++i) {
    D2D1_GRADIENT_STOP s{};
    s.position = count <= 1
                     ? 0.0f
                     : static_cast<float>(i) / static_cast<float>(count - 1);
    s.color = ArgbToColor(palette.colors_argb[i]);
    stops.push_back(s);
  }

  ComPtr<ID2D1GradientStopCollection> collection;
  if (SUCCEEDED(ctx->CreateGradientStopCollection(
          stops.data(), static_cast<UINT32>(stops.size()), D2D1_GAMMA_2_2,
          D2D1_EXTEND_MODE_CLAMP, &collection))) {
    // macOS draws bottom-left -> top-right; flipped to D2D's top-left origin
    // that is (0, h) -> (w, 0).
    ComPtr<ID2D1LinearGradientBrush> brush;
    if (SUCCEEDED(ctx->CreateLinearGradientBrush(
            D2D1::LinearGradientBrushProperties(D2D1::Point2F(0.0f, h),
                                                D2D1::Point2F(w, 0.0f)),
            collection.Get(), &brush))) {
      ctx->FillRectangle(D2D1::RectF(0, 0, w, h), brush.Get());
    }
  } else {
    ComPtr<ID2D1SolidColorBrush> flat;
    if (SUCCEEDED(ctx->CreateSolidColorBrush(
            ArgbToColor(palette.colors_argb.front()), &flat))) {
      ctx->FillRectangle(D2D1::RectF(0, 0, w, h), flat.Get());
    }
  }

  for (const auto& glow : params.glows) {
    const std::uint32_t color =
        palette.colors_argb[static_cast<size_t>(glow.palette_index) %
                            palette.colors_argb.size()];
    DrawRadialBlob(ctx, w, h, glow.center_x_fraction, glow.center_y_fraction,
                   glow.radius_fraction, glow.alpha, color);
  }
}

// `abstractWaves`: tilted base gradient, wave ribbons, white glows.
void DrawAbstractWaves(ID2D1DeviceContext* ctx, ID2D1Factory* factory, float w,
                       float h, const BackgroundPalette& palette,
                       const AbstractWavesParams& params) {
  DrawBaseGradient(ctx, w, h, palette, params.tilt);
  for (const auto& ribbon : params.ribbons) {
    const std::uint32_t color =
        palette.colors_argb[static_cast<size_t>(ribbon.palette_index) %
                            palette.colors_argb.size()];
    DrawWaveRibbon(ctx, factory, w, h, ribbon, color);
  }
  for (const auto& glow : params.glows) {
    DrawGlow(ctx, w, h, glow);
  }
}

// Create an offscreen BGRA target bitmap the size of the canvas.
ComPtr<ID2D1Bitmap1> CreateTargetBitmap(ID2D1DeviceContext* ctx, UINT w,
                                        UINT h) {
  const D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
      D2D1_BITMAP_OPTIONS_TARGET,
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                        D2D1_ALPHA_MODE_PREMULTIPLIED));
  ComPtr<ID2D1Bitmap1> bitmap;
  if (FAILED(ctx->CreateBitmap(D2D1::SizeU(w, h), nullptr, 0, &props,
                               &bitmap))) {
    return nullptr;
  }
  return bitmap;
}

}  // namespace

Microsoft::WRL::ComPtr<ID2D1Bitmap1> RenderCanvasPreset(
    ID2D1DeviceContext* ctx, UINT width, UINT height,
    const CanvasPresetSpec& spec) {
  if (ctx == nullptr || width == 0 || height == 0) return nullptr;

  ComPtr<ID2D1Factory> factory;
  ctx->GetFactory(&factory);
  if (!factory) return nullptr;

  ComPtr<ID2D1Bitmap1> canvas = CreateTargetBitmap(ctx, width, height);
  if (!canvas) return nullptr;

  const BackgroundPalette& palette = BackgroundPaletteFor(spec.palette_id);
  if (palette.colors_argb.empty()) return nullptr;
  const int palette_size = static_cast<int>(palette.colors_argb.size());

  const float w = static_cast<float>(width);
  const float h = static_cast<float>(height);

  // Save and restore the caller's target: this function owns the retarget, and
  // leaving the context pointed at our scratch bitmap would silently redirect
  // the caller's next frame.
  ComPtr<ID2D1Image> previous_target;
  ctx->GetTarget(&previous_target);

  ctx->SetTarget(canvas.Get());
  ctx->BeginDraw();
  ctx->Clear(D2D1::ColorF(0, 0, 0, 0));
  // Unknown ids fall back to abstract waves rather than rendering nothing,
  // matching the macOS `default:` arm — a stale or typo'd id from an older
  // project still gets a reasonable background.
  if (spec.preset_id == "graphicMesh") {
    DrawGraphicMesh(
        ctx, w, h, palette,
        DeriveGraphicMeshParams(spec.seed, spec.intensity, palette_size));
  } else if (spec.preset_id == "radialGlow") {
    DrawRadialGlowPreset(
        ctx, w, h, palette,
        DeriveRadialGlowParams(spec.seed, spec.intensity, palette_size));
  } else {
    DrawAbstractWaves(
        ctx, factory.Get(), w, h, palette,
        DeriveAbstractWavesParams(spec.seed, spec.intensity, palette_size));
  }
  const HRESULT end_hr = ctx->EndDraw();
  ctx->SetTarget(previous_target.Get());
  if (FAILED(end_hr)) return nullptr;

  // Pass 4: optional Gaussian softening. Rendered into a second bitmap so the
  // returned image is a plain bitmap the caller can draw like any other.
  const double sigma = ResolveBlurSigma(spec.blur, w, h);
  if (!(sigma > 0.0)) return canvas;

  ComPtr<ID2D1Effect> blur;
  if (FAILED(ctx->CreateEffect(CLSID_D2D1GaussianBlur, &blur))) return canvas;
  blur->SetInput(0, canvas.Get());
  if (FAILED(blur->SetValue(D2D1_GAUSSIANBLUR_PROP_STANDARD_DEVIATION,
                            static_cast<float>(sigma)))) {
    return canvas;
  }
  // HARD edges: the default SOFT mode expands the output past the canvas, which
  // would shrink the visible art when the result is drawn 1:1.
  blur->SetValue(D2D1_GAUSSIANBLUR_PROP_BORDER_MODE,
                 D2D1_BORDER_MODE_HARD);

  ComPtr<ID2D1Bitmap1> blurred = CreateTargetBitmap(ctx, width, height);
  if (!blurred) return canvas;

  ctx->SetTarget(blurred.Get());
  ctx->BeginDraw();
  ctx->Clear(D2D1::ColorF(0, 0, 0, 0));
  ctx->DrawImage(blur.Get());
  const HRESULT blur_hr = ctx->EndDraw();
  ctx->SetTarget(previous_target.Get());
  // A failed blur is cosmetic: return the sharp canvas rather than nothing.
  return FAILED(blur_hr) ? canvas : blurred;
}

std::string CanvasPresetCacheKey(const CanvasPresetSpec& spec, UINT width,
                                 UINT height) {
  std::ostringstream os;
  os << "v" << kCanvasPresetRendererVersion << '|' << spec.preset_id << '|'
     << spec.palette_id << '|' << spec.intensity << '|' << spec.blur << '|'
     << spec.seed << '|' << width << 'x' << height;
  return os.str();
}

}  // namespace clingfy::capture::background
