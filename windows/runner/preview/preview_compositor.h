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
#include <string>
#include <vector>

namespace clingfy::preview {

// ±500 ms click-lookup window. POC-specific (cursor.jsonl semantics),
// not a constant from zoom_easing_constants.h.
inline constexpr std::int64_t kClickLookupWindowUs = 500'000;

// Cursor highlight radius in OUTPUT PIXELS. The macOS engine has no
// parity constant for this; chosen at the POC level.
inline constexpr float kHighlightRadiusPx = 60.0f;

// ---------------------------------------------------------------------
// Cursor event model + hand-authored JSONL loader
// ---------------------------------------------------------------------

struct CursorEvent {
  std::int64_t ts_us = 0;     // playback timestamp, microseconds
  double x = 0.0;             // video pixel x
  double y = 0.0;             // video pixel y
  int button_state = 0;       // 0 = up sample, non-zero = mouse-down
  int monitor_id = 0;         // unused in POC, preserved for symmetry
};

// Loads + sorts cursor events from a JSONL file. Each line is expected
// to be `{"ts_us":N,"x":N,"y":N,"button_state":N,"monitor_id":N}`.
// Bad lines are dropped silently. Empty on IO failure.
std::vector<CursorEvent> LoadCursorJsonl(const std::wstring& path);

// Nearest cursor sample by absolute distance in ts. nullptr only when
// `events` is empty.
const CursorEvent* FindNearestCursor(
    const std::vector<CursorEvent>& events, std::int64_t ts_us);

// Nearest event with button_state != 0 within ±window_us of ts_us.
// Returns nullptr when no click qualifies.
const CursorEvent* FindNearestClick(
    const std::vector<CursorEvent>& events, std::int64_t ts_us,
    std::int64_t window_us);

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
};

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
  void ComposeFrame(ID2D1DeviceContext* d2d_context,
                    const D2D1_RECT_F& dest_rect,
                    const std::vector<CursorEvent>& cursor_events,
                    std::int64_t playback_us, double now_seconds,
                    ZoomState& zoom);

  UINT video_width() const { return video_width_; }
  UINT video_height() const { return video_height_; }
  bool has_video_target() const { return video_texture_ != nullptr; }

 private:
  HRESULT EnsureHighlightBrush(ID2D1DeviceContext* d2d_context);

  Microsoft::WRL::ComPtr<ID3D11Texture2D> video_texture_;
  Microsoft::WRL::ComPtr<ID2D1Bitmap1> video_bitmap_;
  Microsoft::WRL::ComPtr<ID2D1RadialGradientBrush> highlight_brush_;
  winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DSurface
      winrt_video_surface_{nullptr};
  UINT video_width_ = 0;
  UINT video_height_ = 0;
};

}  // namespace clingfy::preview

#endif  // RUNNER_PREVIEW_PREVIEW_COMPOSITOR_H_
