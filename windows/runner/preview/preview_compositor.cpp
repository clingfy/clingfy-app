#include "preview/preview_compositor.h"

#include "Capture/Background/background_image_cache.h"

#include <inspectable.h>
#include <windows.graphics.directx.direct3d11.interop.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <limits>
#include <string>

#include "Bridge/native_log_publisher.h"
#include "preview/zoom_easing_constants.h"

namespace clingfy::preview {

using Microsoft::WRL::ComPtr;
namespace winrt_dxd3d = winrt::Windows::Graphics::DirectX::Direct3D11;

// ---------------------------------------------------------------------
// JSONL parser
// ---------------------------------------------------------------------

namespace {

std::size_t SkipWs(const std::string& s, std::size_t pos) {
  while (pos < s.size() &&
         (s[pos] == ' ' || s[pos] == '\t' || s[pos] == '\n' ||
          s[pos] == '\r')) {
    ++pos;
  }
  return pos;
}

template <typename T>
bool ReadJsonNumber(const std::string& line, const std::string& key, T& out) {
  std::string quoted = std::string("\"") + key + "\"";
  std::size_t pos = line.find(quoted);
  if (pos == std::string::npos) {
    pos = line.find(key);
    if (pos == std::string::npos) return false;
    if (pos > 0 && (std::isalnum(static_cast<unsigned char>(line[pos - 1])) ||
                    line[pos - 1] == '_')) {
      return false;
    }
    const std::size_t after = pos + key.size();
    if (after < line.size() && (std::isalnum(static_cast<unsigned char>(
                                    line[after])) ||
                                line[after] == '_')) {
      return false;
    }
    pos = after;
  } else {
    pos += quoted.size();
  }
  pos = SkipWs(line, pos);
  if (pos >= line.size() || line[pos] != ':') return false;
  pos = SkipWs(line, pos + 1);

  const char* start = line.c_str() + pos;
  char* end = nullptr;
  if constexpr (std::is_integral_v<T>) {
    const long long v = std::strtoll(start, &end, 10);
    if (end == start) return false;
    out = static_cast<T>(v);
  } else {
    const double v = std::strtod(start, &end);
    if (end == start) return false;
    out = static_cast<T>(v);
  }
  return true;
}

bool ParseCursorLine(const std::string& line, CursorEvent& out) {
  const auto first = line.find_first_not_of(" \t\r\n");
  if (first == std::string::npos) return false;
  if (line[first] != '{') return false;

  CursorEvent ev;
  if (!ReadJsonNumber<std::int64_t>(line, "ts_us", ev.ts_us)) return false;
  if (!ReadJsonNumber<double>(line, "x", ev.x)) return false;
  if (!ReadJsonNumber<double>(line, "y", ev.y)) return false;
  ReadJsonNumber<int>(line, "button_state", ev.button_state);
  ReadJsonNumber<int>(line, "monitor_id", ev.monitor_id);
  out = ev;
  return true;
}

}  // namespace

std::vector<CursorEvent> LoadCursorJsonl(const std::wstring& path) {
  std::vector<CursorEvent> out;
  std::ifstream in(path);
  if (!in.is_open()) return out;
  std::string line;
  while (std::getline(in, line)) {
    CursorEvent ev;
    if (ParseCursorLine(line, ev)) out.push_back(ev);
  }
  std::sort(out.begin(), out.end(),
            [](const CursorEvent& a, const CursorEvent& b) {
              return a.ts_us < b.ts_us;
            });
  return out;
}

const CursorEvent* FindNearestCursor(
    const std::vector<CursorEvent>& events, std::int64_t ts_us) {
  if (events.empty()) return nullptr;
  auto it = std::lower_bound(
      events.begin(), events.end(), ts_us,
      [](const CursorEvent& e, std::int64_t v) { return e.ts_us < v; });
  if (it == events.end()) return &events.back();
  if (it == events.begin()) return &*it;
  auto prev = std::prev(it);
  const std::int64_t diff_prev = std::llabs(prev->ts_us - ts_us);
  const std::int64_t diff_next = std::llabs(it->ts_us - ts_us);
  return diff_prev <= diff_next ? &*prev : &*it;
}

const CursorEvent* FindNearestClick(
    const std::vector<CursorEvent>& events, std::int64_t ts_us,
    std::int64_t window_us) {
  if (events.empty()) return nullptr;
  const CursorEvent* best = nullptr;
  std::int64_t best_diff = window_us + 1;
  for (const auto& e : events) {
    if (e.button_state == 0) continue;
    const std::int64_t diff = std::llabs(e.ts_us - ts_us);
    if (diff <= window_us && diff < best_diff) {
      best = &e;
      best_diff = diff;
    }
  }
  return best;
}

// ---------------------------------------------------------------------
// Zoom smoother
// ---------------------------------------------------------------------

void StepZoomSmoother(ZoomState& z, double now_seconds) {
  if (z.last_update_seconds < 0.0) {
    z.last_update_seconds = now_seconds;
    return;
  }
  double dt = now_seconds - z.last_update_seconds;
  z.last_update_seconds = now_seconds;
  if (dt < kZoomFollowMinDtSeconds) dt = kZoomFollowMinDtSeconds;
  if (dt > kZoomFollowMaxDtSeconds) dt = kZoomFollowMaxDtSeconds;

  const double normalized_frames = dt * kZoomFollowReferenceFPS;
  const double strength = kZoomFollowStrengthDefault;
  const double alpha = 1.0 - std::pow(1.0 - strength, normalized_frames);

  z.current_zoom += (z.target_zoom - z.current_zoom) * alpha;
  z.current_x += (z.target_x - z.current_x) * alpha;
  z.current_y += (z.target_y - z.current_y) * alpha;
}

// ---------------------------------------------------------------------
// Geometry helpers
// ---------------------------------------------------------------------

D2D1_RECT_F LetterboxRect(UINT win_w, UINT win_h, UINT vid_w, UINT vid_h) {
  if (win_w == 0 || win_h == 0 || vid_w == 0 || vid_h == 0) {
    return {0, 0, static_cast<float>(win_w), static_cast<float>(win_h)};
  }
  const double win_ratio = static_cast<double>(win_w) / win_h;
  const double vid_ratio = static_cast<double>(vid_w) / vid_h;
  double draw_w = 0, draw_h = 0;
  if (vid_ratio > win_ratio) {
    draw_w = win_w;
    draw_h = win_w / vid_ratio;
  } else {
    draw_h = win_h;
    draw_w = win_h * vid_ratio;
  }
  const double left = (win_w - draw_w) * 0.5;
  const double top = (win_h - draw_h) * 0.5;
  return {static_cast<float>(left), static_cast<float>(top),
          static_cast<float>(left + draw_w),
          static_cast<float>(top + draw_h)};
}

D2D1_POINT_2F VideoToBackBuffer(double vx, double vy, UINT vid_w,
                                UINT vid_h, const D2D1_RECT_F& dest) {
  if (vid_w == 0 || vid_h == 0) return D2D1::Point2F(0.0f, 0.0f);
  const float dx = dest.right - dest.left;
  const float dy = dest.bottom - dest.top;
  const float ox =
      dest.left + static_cast<float>(vx / vid_w) * dx;
  const float oy =
      dest.top + static_cast<float>(vy / vid_h) * dy;
  return D2D1::Point2F(ox, oy);
}

D2D1_RECT_F ZoomedDestRect(const D2D1_RECT_F& dest, float focus_x,
                           float focus_y, float zoom_factor) {
  if (zoom_factor <= 1.0f + 1e-4f) return dest;
  const float left = focus_x - (focus_x - dest.left) * zoom_factor;
  const float top = focus_y - (focus_y - dest.top) * zoom_factor;
  const float width = (dest.right - dest.left) * zoom_factor;
  const float height = (dest.bottom - dest.top) * zoom_factor;
  return {left, top, left + width, top + height};
}

// ---------------------------------------------------------------------
// PreviewCompositor
// ---------------------------------------------------------------------

HRESULT PreviewCompositor::EnsureResources(ID3D11Device* d3d_device,
                                          ID2D1DeviceContext* d2d_context,
                                          UINT vw, UINT vh) {
  if (vw == 0 || vh == 0 || d3d_device == nullptr ||
      d2d_context == nullptr) {
    return E_INVALIDARG;
  }
  HRESULT hr = S_OK;
  if (!video_texture_ || vw != video_width_ || vh != video_height_) {
    video_bitmap_.Reset();
    video_texture_.Reset();
    winrt_video_surface_ = nullptr;

    D3D11_TEXTURE2D_DESC td{};
    td.Width = vw;
    td.Height = vh;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    hr = d3d_device->CreateTexture2D(
        &td, nullptr, video_texture_.ReleaseAndGetAddressOf());
    if (FAILED(hr)) return hr;

    ComPtr<IDXGISurface> dxgi_surface;
    hr = video_texture_.As(&dxgi_surface);
    if (FAILED(hr)) return hr;
    ComPtr<::IInspectable> inspectable;
    hr = ::CreateDirect3D11SurfaceFromDXGISurface(
        dxgi_surface.Get(),
        reinterpret_cast<::IInspectable**>(inspectable.GetAddressOf()));
    if (FAILED(hr)) return hr;
    winrt::com_ptr<::IInspectable> winrt_inspectable;
    winrt_inspectable.attach(inspectable.Detach());
    winrt_video_surface_ =
        winrt_inspectable.as<winrt_dxd3d::IDirect3DSurface>();

    const auto props = D2D1::BitmapProperties1(
        D2D1_BITMAP_OPTIONS_NONE,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                          D2D1_ALPHA_MODE_IGNORE));
    hr = d2d_context->CreateBitmapFromDxgiSurface(
        dxgi_surface.Get(), &props,
        video_bitmap_.ReleaseAndGetAddressOf());
    if (FAILED(hr)) return hr;

    video_width_ = vw;
    video_height_ = vh;
  }
  return EnsureHighlightBrush(d2d_context);
}

HRESULT PreviewCompositor::EnsureHighlightBrush(
    ID2D1DeviceContext* d2d_context) {
  if (highlight_brush_) return S_OK;
  D2D1_GRADIENT_STOP stops[2] = {
      {0.0f, D2D1::ColorF(1.0f, 0.95f, 0.55f, 0.85f)},
      {1.0f, D2D1::ColorF(1.0f, 0.95f, 0.55f, 0.0f)},
  };
  ComPtr<ID2D1GradientStopCollection> collection;
  HRESULT hr = d2d_context->CreateGradientStopCollection(
      stops, 2, collection.GetAddressOf());
  if (FAILED(hr)) return hr;
  D2D1_RADIAL_GRADIENT_BRUSH_PROPERTIES props{};
  props.center = D2D1::Point2F(0.0f, 0.0f);
  props.gradientOriginOffset = D2D1::Point2F(0.0f, 0.0f);
  props.radiusX = kHighlightRadiusPx;
  props.radiusY = kHighlightRadiusPx;
  return d2d_context->CreateRadialGradientBrush(
      props, collection.Get(),
      highlight_brush_.ReleaseAndGetAddressOf());
}

void PreviewCompositor::ComposeFrame(
    ID2D1DeviceContext* d2d_context, const D2D1_RECT_F& dest_rect,
    const std::vector<CursorEvent>& cursor_events,
    std::int64_t playback_us, double now_seconds, ZoomState& zoom) {
  // Canvas background. This Clear runs BEFORE the colour-grade effect chain
  // below, which is precisely what keeps the canvas ungraded — same rule the
  // cursor halo and camera bubble already follow. Defaults to opaque black, so
  // a preview with no canvas pushed yet looks exactly as it did before.
  capture::export_::RgbaColor bg{};
  float corner_radius_px = 0.0f;
  ID2D1Bitmap* bg_image = nullptr;
  {
    std::lock_guard<std::mutex> lock(canvas_mutex_);
    bg = canvas_background_;
    corner_radius_px = canvas_corner_radius_px_;
    bg_image = canvas_background_image_;
  }
  d2d_context->Clear(D2D1::ColorF(
      static_cast<float>(bg.r), static_cast<float>(bg.g),
      static_cast<float>(bg.b), static_cast<float>(bg.a)));

  // Background image over the fill, scaled to COVER the whole surface (wallpaper
  // behaviour, not letterboxed like the video). Drawn here — before the grade
  // chain and outside the rounded content layer — so it stays ungraded and fills
  // the padding area, exactly like the export composites it.
  if (bg_image != nullptr) {
    D2D1_SIZE_F img = bg_image->GetSize();
    D2D1_SIZE_F surface = d2d_context->GetSize();
    const capture::export_::RectF src =
        capture::background::ComputeCoverSourceRect(
            capture::export_::SizeF{img.width, img.height},
            capture::export_::SizeF{surface.width, surface.height});
    const D2D1_RECT_F src_rect = D2D1::RectF(
        static_cast<float>(src.x), static_cast<float>(src.y),
        static_cast<float>(src.x + src.width),
        static_cast<float>(src.y + src.height));
    d2d_context->DrawBitmap(
        bg_image, D2D1::RectF(0.0f, 0.0f, surface.width, surface.height), 1.0f,
        D2D1_BITMAP_INTERPOLATION_MODE_LINEAR, &src_rect);
  }

  if (!video_bitmap_) return;

  // Rounded content corners. Clamped to half the shorter side of the content
  // rect so an over-large radius degenerates to a pill rather than inverting
  // the geometry — same clamp rule the export applies.
  Microsoft::WRL::ComPtr<ID2D1Layer> canvas_layer;
  bool canvas_layer_pushed = false;
  if (corner_radius_px > 0.0f) {
    const float w = dest_rect.right - dest_rect.left;
    const float h = dest_rect.bottom - dest_rect.top;
    const float r = std::min(corner_radius_px, std::min(w, h) * 0.5f);
    if (r > 0.0f && w > 0.0f && h > 0.0f) {
      Microsoft::WRL::ComPtr<ID2D1Factory> factory;
      d2d_context->GetFactory(&factory);
      Microsoft::WRL::ComPtr<ID2D1RoundedRectangleGeometry> geo;
      if (factory &&
          SUCCEEDED(factory->CreateRoundedRectangleGeometry(
              D2D1::RoundedRect(dest_rect, r, r), &geo)) &&
          SUCCEEDED(d2d_context->CreateLayer(nullptr, &canvas_layer))) {
        d2d_context->PushLayer(
            D2D1::LayerParameters(D2D1::InfiniteRect(), geo.Get()),
            canvas_layer.Get());
        canvas_layer_pushed = true;
      }
      // A failed layer just means square corners this frame — the background
      // and video still composite correctly, so there is nothing to abort.
    }
  }
  // Popped at every return path below via this guard.
  const auto pop_canvas_layer = [&]() {
    if (canvas_layer_pushed) {
      d2d_context->PopLayer();
      canvas_layer_pushed = false;
    }
  };

  const bool has_cursor = !cursor_events.empty();
  float zoom_for_draw = 1.0f;
  float cursor_back_x = 0.0f;
  float cursor_back_y = 0.0f;
  float highlight_alpha = 0.0f;

  if (has_cursor) {
    const CursorEvent* nearest =
        FindNearestCursor(cursor_events, playback_us);
    const CursorEvent* click = FindNearestClick(cursor_events, playback_us,
                                                kClickLookupWindowUs);
    if (nearest != nullptr) {
      zoom.target_x = nearest->x;
      zoom.target_y = nearest->y;
    }
    const std::int64_t now_us = playback_us;
    const std::int64_t hold_us = static_cast<std::int64_t>(
        kZoomMinOnSeconds * 1'000'000.0);
    bool zoom_wanted = false;
    if (click != nullptr) {
      zoom.last_click_ts_us = std::max(zoom.last_click_ts_us, click->ts_us);
      zoom_wanted = true;
    } else if (zoom.last_click_ts_us !=
                   std::numeric_limits<std::int64_t>::min() &&
               now_us >= 0 && now_us >= zoom.last_click_ts_us &&
               (now_us - zoom.last_click_ts_us) < hold_us) {
      zoom_wanted = true;
    }
    zoom.target_zoom = zoom_wanted ? kZoomFactorDefault : 1.0;
    StepZoomSmoother(zoom, now_seconds);

    zoom_for_draw = static_cast<float>(zoom.current_zoom);
    const auto cursor_bb = VideoToBackBuffer(
        zoom.current_x, zoom.current_y, video_width_, video_height_,
        dest_rect);
    cursor_back_x = cursor_bb.x;
    cursor_back_y = cursor_bb.y;
    const double span = kZoomFactorDefault - 1.0;
    const double t = span > 0 ? (zoom.current_zoom - 1.0) / span : 0.0;
    highlight_alpha = static_cast<float>(std::clamp(t, 0.0, 1.0));
  }

  const D2D1_RECT_F zoomed = has_cursor
                                 ? ZoomedDestRect(dest_rect, cursor_back_x,
                                                  cursor_back_y,
                                                  zoom_for_draw)
                                 : dest_rect;

  // Editing port (color): snapshot the grade (SetColorGrade runs on the
  // platform thread). Non-identity → draw the video through the shared D2D
  // color chain; identity or chain failure → the exact pre-color draw.
  capture::export_::color::ColorGrade grade;
  std::uint64_t grade_generation = 0;
  {
    std::lock_guard<std::mutex> lock(grade_mutex_);
    grade = grade_;
    grade_generation = grade_generation_;
  }
  bool graded_drawn = false;
  if (!grade.IsIdentity() &&
      EnsureColorGradeChain(d2d_context, grade, grade_generation)) {
    // DrawImage has no dest rect: map the source-sized effect output into
    // the (possibly zoomed) dest rect with a transform instead.
    D2D1_MATRIX_3X2_F old_transform;
    d2d_context->GetTransform(&old_transform);
    const float sx = (zoomed.right - zoomed.left) /
                     static_cast<float>(video_width_ != 0 ? video_width_ : 1);
    const float sy =
        (zoomed.bottom - zoomed.top) /
        static_cast<float>(video_height_ != 0 ? video_height_ : 1);
    d2d_context->SetTransform(D2D1::Matrix3x2F::Scale(sx, sy) *
                              D2D1::Matrix3x2F::Translation(zoomed.left,
                                                            zoomed.top) *
                              old_transform);
    d2d_context->DrawImage(grade_chain_.Output(), nullptr, nullptr,
                           D2D1_INTERPOLATION_MODE_LINEAR,
                           D2D1_COMPOSITE_MODE_SOURCE_OVER);
    d2d_context->SetTransform(old_transform);
    graded_drawn = true;
  }
  if (!graded_drawn) {
    d2d_context->DrawBitmap(video_bitmap_.Get(), &zoomed, 1.0f,
                            D2D1_BITMAP_INTERPOLATION_MODE_LINEAR);
  }

  if (has_cursor && highlight_brush_ && highlight_alpha > 0.0f) {
    highlight_brush_->SetCenter(
        D2D1::Point2F(cursor_back_x, cursor_back_y));
    highlight_brush_->SetOpacity(highlight_alpha);
    const D2D1_ELLIPSE halo = {
        D2D1::Point2F(cursor_back_x, cursor_back_y),
        kHighlightRadiusPx, kHighlightRadiusPx};
    d2d_context->FillEllipse(halo, highlight_brush_.Get());
  }

  // Content (video + cursor halo) is clipped to the rounded canvas rect so the
  // halo cannot bleed onto the background. The background itself was filled by
  // the Clear above, outside this layer and outside the grade chain.
  pop_canvas_layer();
}

void PreviewCompositor::SetCanvasFraming(
    capture::export_::RgbaColor background, float corner_radius_px,
    ID2D1Bitmap* background_image) {
  std::lock_guard<std::mutex> lock(canvas_mutex_);
  canvas_background_ = background;
  canvas_corner_radius_px_ = std::max(0.0f, corner_radius_px);
  canvas_background_image_ = background_image;
}

void PreviewCompositor::SetColorGrade(
    const capture::export_::color::ColorGrade& grade) {
  std::lock_guard<std::mutex> lock(grade_mutex_);
  if (grade == grade_) {
    return;
  }
  grade_ = grade;
  ++grade_generation_;
}

bool PreviewCompositor::EnsureColorGradeChain(
    ID2D1DeviceContext* d2d_context,
    const capture::export_::color::ColorGrade& grade,
    std::uint64_t generation) {
  const auto degrade = [&](const char* step, HRESULT hr) {
    grade_chain_.Reset();
    chain_context_ = nullptr;
    // Log once per grade change, not per frame — a broken chain would
    // otherwise spam 60 lines a second.
    if (failed_generation_ != generation) {
      failed_generation_ = generation;
      char hr_buf[32];
      std::snprintf(hr_buf, sizeof(hr_buf), " (hr=0x%08lX)",
                    static_cast<unsigned long>(hr));
      clingfy::bridge::NativeLogPublisher::Instance().Warn(
          "Preview",
          std::string("PREVIEW_COLOR_GRADE_DEGRADED: could not build the "
                      "color-grade pass — ") +
              step + hr_buf +
              " — preview renders UNGRADED (macOS-parity best-effort).");
    }
    return false;
  };

  // Rebuild from scratch when the context changed (device loss recreates
  // it) or the chain never built; otherwise a grade change is a cheap
  // matrix update in place.
  if (chain_context_ != d2d_context || !grade_chain_.IsBuilt()) {
    const HRESULT hr = grade_chain_.Build(d2d_context, grade);
    if (FAILED(hr)) {
      return degrade("effect chain", hr);
    }
    chain_context_ = d2d_context;
    chain_generation_ = generation;
  } else if (chain_generation_ != generation) {
    const HRESULT hr = grade_chain_.UpdateGrade(grade);
    if (FAILED(hr)) {
      return degrade("matrix update", hr);
    }
    chain_generation_ = generation;
  }

  // Re-point the input every time: EnsureResources recreates video_bitmap_
  // on size changes with the same context, and a stale input would grade a
  // released bitmap. SetInput is a pointer store — per-frame cost is nil.
  grade_chain_.SetInput(video_bitmap_.Get());
  return true;
}

}  // namespace clingfy::preview
