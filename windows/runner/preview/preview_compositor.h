// Reusable per-frame compositor for the Windows Phase 5 preview path.
//
// Originally inlined inside windows/runner/preview/mediaplayer_frame_server_demo.cpp;
// extracted in Stage 2A-2 so the same composition logic feeds both
// outputs:
//
//   * the standalone HWND swap-chain demo
//     (build/windows-poc/.../mediaplayer_frame_server_demo.exe — drives
//     `stage1d_result.md`), and
//   * the Flutter Texture / DXGI shared-handle bridge
//     (PreviewEngine — drives `stage2a_2_result.md`).
//
// Single source of truth for cursor.jsonl parsing, smart-zoom state +
// smoother math, letterbox / zoom geometry, and the actual Direct2D
// draw call sequence. Constants pulled from
// `preview/zoom_easing_constants.h`.
//
// Threading: ComposeFrame is callable from any thread provided the
// supplied ID2D1DeviceContext was created from a D2D factory in
// MULTI_THREADED mode AND the D3D11 device is multi-thread protected
// (both required by MediaPlayer frame-server already).

#ifndef RUNNER_PREVIEW_PREVIEW_COMPOSITOR_H_
#define RUNNER_PREVIEW_PREVIEW_COMPOSITOR_H_

#include <windows.h>
#include <d2d1_1.h>
#include <d3d11.h>
#include <dxgi.h>
#include <wrl/client.h>

#include <winrt/base.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>

#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

#include "Capture/Cursor/cursor_sidecar_reader.h"
#include "Capture/Export/color_grade.h"
#include "preview/zoom_easing_constants.h"
#include "Capture/Export/export_geometry.h"
#include "Graphics/color_grade_effect.h"

namespace clingfy::preview {

// ±500 ms click-lookup window. POC-specific (cursor.jsonl semantics),
// not a constant from zoom_easing_constants.h.
inline constexpr std::int64_t kClickLookupWindowUs = 500'000;

// Cursor highlight radius in OUTPUT PIXELS. The macOS engine has no
// parity constant for this; chosen at the POC level.
inline constexpr float kHighlightRadiusPx = 60.0f;

// ---------------------------------------------------------------------
// Cursor data — the SAME sidecar the export reads
// ---------------------------------------------------------------------
//
// This used to be a hand-authored JSONL loader requiring a `ts_us` field, from
// the frame-server POC. The shipping recorder has never written that field:
// `CursorSidecarWriter` emits `{"type":"sample","tMs":...}` and
// `{"type":"click","tMs":...}`. So the loader returned ZERO events for every
// real project, and the whole preview cursor/zoom path was dead — no zoom, no
// halo, and a constant screen_zoom of 1.0 handed to the camera (which is why
// scale-with-zoom could not be seen in the editor either). It also meant
// `CURSOR_FILE_MISSING` fired on every open, and Dart force-disabled the
// user's cursor toggle in response.
//
// The preview now parses with `capture::ParseCursorSidecar`, the export's own
// reader, and samples positions with `capture::SampleCursorAt`, its own
// interpolator. One format, one parser, one interpolation rule — the same
// collapse #422 made for the camera composition payload. The POC's `ts_us`
// format lives on only inside `mediaplayer_frame_server_demo.cpp`, which owns
// its fixtures.

// The click nearest `t_ms` within ±`window_ms`, or nullptr when none
// qualifies. Pure; `clicks` must be sorted ascending (ParseCursorSidecar
// guarantees it).
const capture::CursorSidecarClick* FindCursorClickWithin(
    const std::vector<capture::CursorSidecarClick>& clicks,
    std::int64_t t_ms, std::int64_t window_ms);

// ---------------------------------------------------------------------
// Zoom state + per-frame exponential smoother
// ---------------------------------------------------------------------

struct ZoomState {
  double current_zoom = 1.0;
  double current_x = 0.0;        // video pixel x
  double current_y = 0.0;
  double target_zoom = 1.0;
  double target_x = 0.0;
  double target_y = 0.0;
  double last_update_seconds = -1.0;
  std::int64_t last_click_ts_us = std::numeric_limits<std::int64_t>::min();

  // The user's per-recording zoom settings, mirrored from the same
  // `zoomFactor` / `zoomEffectEnabled` args the EXPORT already honours
  // (export_router HandleExportVideo). The preview used to hardcode
  // kZoomFactorDefault and ignore the toggle entirely, so the editor zoomed
  // 1.5x no matter what the user picked on the 1.0-3.0 slider, and kept
  // zooming after they turned the effect off — while the exported file did
  // neither. Defaults match the Dart defaults so an old payload behaves as
  // before.
  double zoom_factor = kZoomFactorDefault;
  bool effect_enabled = kZoomEffectEnabledDefault;
};

// The magnitude a frame should ease TOWARD: the user's configured factor
// (clamped to the 1.0-3.0 slider range) while a zoom is wanted and the effect
// is on, else 1.0. Pure so the "preview honours the user's zoom settings"
// contract is unit-testable without a D2D device — the preview previously
// hardcoded kZoomFactorDefault here and ignored the toggle entirely, which the
// export never did.
double ResolveTargetZoom(bool effect_enabled, bool zoom_wanted,
                         double configured_factor);

// Lerps current_* toward target_* with the exponential smoothing
// alpha from zoom_easing_constants.h. `now_seconds` is wall-clock
// (QueryPerformanceCounter) on the calling thread.
void StepZoomSmoother(ZoomState& z, double now_seconds);

// ---------------------------------------------------------------------
// Geometry helpers (pure functions — also exported here so the HWND
// demo can reuse them for layouts that include slider strips, etc.)
// ---------------------------------------------------------------------

D2D1_RECT_F LetterboxRect(UINT win_w, UINT win_h, UINT vid_w, UINT vid_h);

D2D1_POINT_2F VideoToBackBuffer(double vx, double vy, UINT vid_w,
                                UINT vid_h, const D2D1_RECT_F& dest);

D2D1_RECT_F ZoomedDestRect(const D2D1_RECT_F& dest, float focus_x,
                           float focus_y, float zoom_factor);

// ---------------------------------------------------------------------
// PreviewCompositor — owns the offscreen video texture + D2D wrappers
// + radial halo brush, and runs the per-frame composition.
// ---------------------------------------------------------------------

class PreviewCompositor {
 public:
  PreviewCompositor() = default;
  ~PreviewCompositor() = default;

  PreviewCompositor(const PreviewCompositor&) = delete;
  PreviewCompositor& operator=(const PreviewCompositor&) = delete;

  // Ensures the offscreen video texture (size vw × vh), its WinRT
  // surface wrapper, its D2D bitmap wrapper, and the highlight brush
  // are allocated against the given device + d2d_context. Idempotent
  // for the same (device, size) tuple. Call from the same thread as
  // the per-frame ComposeFrame.
  HRESULT EnsureResources(ID3D11Device* d3d_device,
                          ID2D1DeviceContext* d2d_context, UINT vw,
                          UINT vh);

  // The WinRT IDirect3DSurface that MediaPlayer.CopyFrameToVideoSurface
  // writes into. Valid after EnsureResources succeeds. The caller is
  // expected to copy a new frame into this surface BEFORE each
  // ComposeFrame call.
  winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DSurface
      winrt_video_surface() const {
    return winrt_video_surface_;
  }

  // Render the composed frame onto the d2d_context's current target.
  // The caller owns BeginDraw / EndDraw around this call.
  //
  //   dest_rect       — letterboxed destination rect on the target
  //                     surface, in output pixel coordinates.
  //   cursor_events   — empty for video-only mode; else drives zoom
  //                     and the highlight halo.
  //   playback_us     — current MediaPlayer playback position; used
  //                     to look up cursor events around now.
  //   now_seconds     — QPC-derived wall-clock seconds (for the
  //                     smoother's per-frame alpha).
  //   zoom            — input/output. Updated in place by the
  //                     smoother every frame.
  // `cursor` is the parsed sidecar; empty samples = the video-only path (no
  // zoom, no halo), which is what a recording with cursor capture off yields.
  void ComposeFrame(ID2D1DeviceContext* d2d_context,
                    const D2D1_RECT_F& dest_rect,
                    const capture::CursorSidecarData& cursor,
                    std::int64_t playback_us, double now_seconds,
                    ZoomState& zoom);

  UINT video_width() const { return video_width_; }
  UINT video_height() const { return video_height_; }
  bool has_video_target() const { return video_texture_ != nullptr; }

  // The offscreen video texture the frames land in. Exposed so the headless
  // compositor tests can fill it directly (UpdateSubresource) without a
  // MediaPlayer.
  ID3D11Texture2D* video_texture() const { return video_texture_.Get(); }

  // Editing port (color): sets the grade applied to the VIDEO ONLY — the
  // cursor highlight halo (drawn after) stays ungraded, matching the macOS
  // preview, where color hits the screen track and not the overlays. The
  // export grades video+cursor+clicks (its cursor is baked before the grade
  // on both platforms) — that asymmetry is macOS behavior, reproduced
  // deliberately.
  //
  // Thread-safe: callable from the platform thread while ComposeFrame runs
  // on the frame-server thread. The D2D effect chain itself is built lazily
  // ON the frame thread against the frame thread's device context (and
  // rebuilt after device loss); a build failure degrades to an ungraded
  // preview with one loud log per grade change.
  void SetColorGrade(const capture::export_::color::ColorGrade& grade);

  // Canvas framing for the live preview: the fill drawn behind and around the
  // video, and the corner radius applied to the video rect. Both already
  // resolved to THIS surface's pixels by the engine (the wire contract carries
  // resolution-independent fractions — see Core/canvas_composition.h).
  //
  // The background is filled by the Clear() at the top of ComposeFrame, which
  // happens BEFORE the colour-grade effect chain runs. That ordering is what
  // keeps the canvas ungraded, matching the existing rule that the cursor halo
  // and camera bubble stay outside the grade.
  //
  // Thread-safe: called from the platform thread, read on the frame thread.
  // `background_image` is optional and may be null. When present it is drawn
  // scaled-to-COVER across the whole surface, on top of the colour fill — the
  // fill still paints first so a missing or undecodable image degrades to the
  // colour rather than to nothing. The caller owns the bitmap's lifetime
  // (BackgroundImageCache); the compositor only borrows it for the frame.
  void SetCanvasFraming(capture::export_::RgbaColor background,
                        float corner_radius_px,
                        ID2D1Bitmap* background_image);

 private:
  HRESULT EnsureHighlightBrush(ID2D1DeviceContext* d2d_context);

  // Frame-thread only. Ensures the effect chain exists for `d2d_context`
  // and carries `generation`'s matrix. Returns false (ungraded fallback)
  // on any failure.
  bool EnsureColorGradeChain(
      ID2D1DeviceContext* d2d_context,
      const capture::export_::color::ColorGrade& grade,
      std::uint64_t generation);

  Microsoft::WRL::ComPtr<ID3D11Texture2D> video_texture_;
  Microsoft::WRL::ComPtr<ID2D1Bitmap1> video_bitmap_;
  Microsoft::WRL::ComPtr<ID2D1RadialGradientBrush> highlight_brush_;
  winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DSurface
      winrt_video_surface_{nullptr};
  UINT video_width_ = 0;
  UINT video_height_ = 0;

  // Editing port (color). grade_mutex_ guards grade_ + grade_generation_
  // (written by SetColorGrade on the platform thread, snapshotted by
  // ComposeFrame on the frame thread). The chain members are frame-thread
  // only.
  std::mutex grade_mutex_;

  // Canvas framing (canvas_mutex_ guards both). Defaults reproduce today's
  // behaviour exactly: opaque black fill, square corners.
  std::mutex canvas_mutex_;
  capture::export_::RgbaColor canvas_background_{0.0, 0.0, 0.0, 1.0};
  float canvas_corner_radius_px_ = 0.0f;
  // Borrowed, not owned — BackgroundImageCache owns the bitmap and outlives the
  // frame. Null means "colour background".
  ID2D1Bitmap* canvas_background_image_ = nullptr;
  capture::export_::color::ColorGrade grade_;
  std::uint64_t grade_generation_ = 0;
  std::uint64_t chain_generation_ = 0;
  std::uint64_t failed_generation_ = 0;  // log-once per grade change
  ID2D1DeviceContext* chain_context_ = nullptr;  // observed, not owned
  clingfy::graphics::ColorGradeEffectChain grade_chain_;
};

}  // namespace clingfy::preview

#endif  // RUNNER_PREVIEW_PREVIEW_COMPOSITOR_H_
