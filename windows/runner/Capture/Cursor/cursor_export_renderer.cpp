#include "Capture/Cursor/cursor_export_renderer.h"

#include <fstream>
#include <sstream>
#include <utility>

namespace clingfy::capture {

namespace {

using Microsoft::WRL::ComPtr;

// Classic arrow pointer, in cursor units, tip (hotspot) at (0,0). ~12 wide x
// ~19 tall — scaled to canvas px by the glyph scale at draw time.
constexpr D2D1_POINT_2F kArrowPoints[] = {
    {0.0f, 0.0f},   {0.0f, 18.0f}, {4.0f, 13.8f},  {6.6f, 19.6f},
    {8.7f, 18.7f},  {6.1f, 13.0f}, {11.2f, 13.0f},
};

// Phase 8.4 click-ripple shape/timing. Windows-specific (macOS has no click-
// ripple constant — its highlighter is a live-recording overlay). The ring
// expands from min→max capture px over its lifetime and fades out; sizes scale
// with the content like the cursor glyph.
constexpr std::int64_t kClickRippleMs = 450;
constexpr double kClickRippleMinPx = 6.0;
constexpr double kClickRippleMaxPx = 30.0;
constexpr double kClickRippleStrokePx = 2.5;
constexpr float kClickRippleOpacity = 0.8f;

}  // namespace

double ClickRippleProgress(std::int64_t click_t_ms, std::int64_t frame_ms,
                           std::int64_t ripple_ms) {
  if (ripple_ms <= 0) {
    return -1.0;
  }
  const std::int64_t age = frame_ms - click_t_ms;
  if (age < 0 || age > ripple_ms) {
    return -1.0;  // not animating at this frame.
  }
  return static_cast<double>(age) / static_cast<double>(ripple_ms);
}

std::unique_ptr<CursorExportRenderer> CursorExportRenderer::Create(
    const std::wstring& sidecar_path) {
  if (sidecar_path.empty()) {
    return nullptr;
  }
  std::ifstream in(sidecar_path, std::ios::binary);
  if (!in) {
    return nullptr;  // no sidecar → no cursor (not an error).
  }
  std::ostringstream ss;
  ss << in.rdbuf();
  auto parsed = ParseCursorSidecar(ss.str());
  if (!parsed.has_value()) {
    return nullptr;  // malformed / headerless → no cursor.
  }
  std::unique_ptr<CursorExportRenderer> renderer(new CursorExportRenderer());
  renderer->data_ = std::move(*parsed);
  return renderer;
}

bool CursorExportRenderer::Prepare(ID2D1Factory1* factory,
                                   ID2D1DeviceContext* ctx) {
  if (factory == nullptr || ctx == nullptr) {
    return false;
  }
  ComPtr<ID2D1PathGeometry> geometry;
  if (FAILED(factory->CreatePathGeometry(geometry.GetAddressOf())) ||
      geometry == nullptr) {
    return false;
  }
  ComPtr<ID2D1GeometrySink> sink;
  if (FAILED(geometry->Open(sink.GetAddressOf())) || sink == nullptr) {
    return false;
  }
  sink->BeginFigure(kArrowPoints[0], D2D1_FIGURE_BEGIN_FILLED);
  const int count = static_cast<int>(sizeof(kArrowPoints) /
                                     sizeof(kArrowPoints[0]));
  for (int i = 1; i < count; ++i) {
    sink->AddLine(kArrowPoints[i]);
  }
  sink->EndFigure(D2D1_FIGURE_END_CLOSED);
  if (FAILED(sink->Close())) {
    return false;
  }

  // White fill + near-black outline = the canonical pointer over any content.
  if (FAILED(ctx->CreateSolidColorBrush(D2D1::ColorF(1.0f, 1.0f, 1.0f, 1.0f),
                                        fill_brush_.GetAddressOf())) ||
      FAILED(ctx->CreateSolidColorBrush(D2D1::ColorF(0.1f, 0.1f, 0.1f, 1.0f),
                                        stroke_brush_.GetAddressOf()))) {
    return false;
  }
  // Click-ripple brush (white; per-ripple opacity is set at draw time). A
  // failure here only disables the click animation, not the cursor.
  ctx->CreateSolidColorBrush(D2D1::ColorF(1.0f, 1.0f, 1.0f, 1.0f),
                             ripple_brush_.GetAddressOf());
  arrow_ = std::move(geometry);
  ready_ = true;
  return true;
}

void CursorExportRenderer::DrawClicks(ID2D1DeviceContext* ctx,
                                      std::int64_t frame_ms,
                                      const D2D1_RECT_F& content_rect,
                                      double source_w, double source_h) {
  if (!ready_ || ctx == nullptr || ripple_brush_ == nullptr ||
      data_.clicks.empty()) {
    return;
  }
  const double content_w =
      static_cast<double>(content_rect.right - content_rect.left);
  const double content_h =
      static_cast<double>(content_rect.bottom - content_rect.top);
  for (const auto& click : data_.clicks) {
    const double progress =
        ClickRippleProgress(click.t_ms, frame_ms, kClickRippleMs);
    // progress < 0 → not animating; progress == 1 → fully faded (opacity 0), so
    // skip the invisible terminal-frame draw.
    if (progress < 0.0 || progress >= 1.0) {
      continue;
    }
    // The ripple sits where the cursor was at the click instant.
    const CursorAtResult at = SampleCursorAt(data_.samples, click.t_ms);
    if (!at.has || !at.visible) {
      continue;
    }
    // cursor_size = 1.0 → glyph_scale is the pure content scale, so the ring is
    // sized in capture px (matching the cursor's coordinate space).
    const CursorPlacement place = ResolveCursorPlacement(
        at.x, at.y, content_rect.left, content_rect.top, content_w, content_h,
        source_w, source_h, 1.0);
    if (place.glyph_scale <= 0.0) {
      continue;
    }
    const double radius =
        (kClickRippleMinPx + (kClickRippleMaxPx - kClickRippleMinPx) * progress) *
        place.glyph_scale;
    ripple_brush_->SetOpacity(
        static_cast<float>((1.0 - progress)) * kClickRippleOpacity);
    const D2D1_ELLIPSE ellipse = D2D1::Ellipse(
        D2D1::Point2F(static_cast<float>(place.canvas_x),
                      static_cast<float>(place.canvas_y)),
        static_cast<float>(radius), static_cast<float>(radius));
    ctx->DrawEllipse(
        ellipse, ripple_brush_.Get(),
        static_cast<float>(kClickRippleStrokePx * place.glyph_scale));
  }
}

void CursorExportRenderer::Draw(ID2D1DeviceContext* ctx, std::int64_t frame_ms,
                                const D2D1_RECT_F& content_rect,
                                double source_w, double source_h,
                                double cursor_size) {
  if (!ready_ || ctx == nullptr) {
    return;
  }
  const CursorAtResult at = SampleCursorAt(data_.samples, frame_ms);
  if (!at.has || !at.visible) {
    return;
  }
  const double content_w =
      static_cast<double>(content_rect.right - content_rect.left);
  const double content_h =
      static_cast<double>(content_rect.bottom - content_rect.top);
  const CursorPlacement place = ResolveCursorPlacement(
      at.x, at.y, content_rect.left, content_rect.top, content_w, content_h,
      source_w, source_h, cursor_size);
  if (place.glyph_scale <= 0.0) {
    return;
  }

  D2D1_MATRIX_3X2_F previous;
  ctx->GetTransform(&previous);

  // The REAL recorded shape, when the recording carries one. Anything captured
  // before shapes existed — and any cursor that failed to rasterize — has
  // sprite_id -1 and falls through to the vector arrow below, which is why
  // that arrow is still here.
  if (ID2D1Bitmap* sprite = BitmapForSprite(ctx, at.sprite_id)) {
    const auto& meta = data_.sprites[static_cast<size_t>(at.sprite_id)];
    const float scale = static_cast<float>(place.glyph_scale);
    // Position by the HOTSPOT, not the top-left. An I-beam's hotspot is its
    // middle and a resize cursor's is its centre, so drawing at the raw
    // position would offset every non-arrow shape by up to its own size.
    const float left =
        static_cast<float>(place.canvas_x) - meta.hotspot_x * scale;
    const float top =
        static_cast<float>(place.canvas_y) - meta.hotspot_y * scale;
    const D2D1_RECT_F dest = D2D1::RectF(
        left, top, left + meta.width * scale, top + meta.height * scale);
    ctx->DrawBitmap(sprite, dest, 1.0f,
                    // Linear: the sprite is upscaled by cursorSize and the
                    // content scale, and nearest-neighbour would alias the
                    // antialiased edges the OS already baked in.
                    D2D1_BITMAP_INTERPOLATION_MODE_LINEAR);
    ctx->SetTransform(previous);
    return;
  }

  // geometry (cursor units) → scale to px → translate so the tip lands on the
  // cursor position → then any pre-existing transform (identity here).
  const D2D1_MATRIX_3X2_F glyph =
      D2D1::Matrix3x2F::Scale(static_cast<float>(place.glyph_scale),
                              static_cast<float>(place.glyph_scale)) *
      D2D1::Matrix3x2F::Translation(static_cast<float>(place.canvas_x),
                                    static_cast<float>(place.canvas_y));
  ctx->SetTransform(glyph * previous);
  ctx->FillGeometry(arrow_.Get(), fill_brush_.Get());
  // Stroke width is in geometry (cursor) units, so it scales with the glyph.
  ctx->DrawGeometry(arrow_.Get(), stroke_brush_.Get(), 1.1f);
  ctx->SetTransform(previous);
}

ID2D1Bitmap* CursorExportRenderer::BitmapForSprite(ID2D1DeviceContext* ctx,
                                                   int sprite_id) {
  if (sprite_id < 0 || ctx == nullptr ||
      static_cast<size_t>(sprite_id) >= data_.sprites.size()) {
    return nullptr;
  }
  if (const auto hit = sprite_bitmaps_.find(sprite_id);
      hit != sprite_bitmaps_.end()) {
    return hit->second.Get();  // may be null: a previous failed upload
  }
  const CursorSidecarSprite& sprite =
      data_.sprites[static_cast<size_t>(sprite_id)];
  Microsoft::WRL::ComPtr<ID2D1Bitmap> bitmap;
  const D2D1_BITMAP_PROPERTIES props = D2D1::BitmapProperties(
      // PREMULTIPLIED, matching what the rasterizer wrote. Declaring it
      // straight would double-apply alpha and halo every glyph.
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED));
  const HRESULT hr = ctx->CreateBitmap(
      D2D1::SizeU(static_cast<UINT32>(sprite.width),
                  static_cast<UINT32>(sprite.height)),
      sprite.pixels.data(), static_cast<UINT32>(sprite.width) * 4, props,
      bitmap.GetAddressOf());
  if (FAILED(hr)) {
    // Cache the failure so a broken sprite is not retried every frame; the
    // null entry sends this frame and every later one to the arrow.
    sprite_bitmaps_[sprite_id] = nullptr;
    return nullptr;
  }
  sprite_bitmaps_[sprite_id] = bitmap;
  return sprite_bitmaps_[sprite_id].Get();
}

}  // namespace clingfy::capture
