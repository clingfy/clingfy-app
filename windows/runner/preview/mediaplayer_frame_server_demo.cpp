// Windows Phase 5 POC — Stage 1B: MediaPlayer frame-server → Direct2D HWND.
//
// What this is: a second opt-in standalone Win32 GUI executable, peer
// to live_compositor_demo.exe from Stage 1A0. It loads a fixed MP4
// fixture (path comes from --video=PATH on the command line, or the
// CLINGFY_POC_VIDEO env var), enables MediaPlayer.IsVideoFrameServerEnabled,
// subscribes to VideoFrameAvailable, calls MediaPlayer.CopyFrameToVideoSurface
// onto an offscreen ID3D11Texture2D wrapped as a WinRT IDirect3DSurface,
// renders that texture into the HWND swap-chain back buffer via Direct2D
// (DrawBitmap, letterboxed to preserve aspect ratio), Presents, and
// records per-callback work time via FrameTimingCollector. On close it
// prints one summary line to stderr:
//
//   STAGE1B_STATS frames=N min=… median=… p99=… max=…
//
// What this is NOT: production code. It is not linked into the main
// Flutter app. It does not touch the bridge contract or the Flutter
// preview surface. The cmake option BUILD_LIVE_COMPOSITOR_POC defaults
// to OFF, so `flutter build windows` ignores this file entirely.
//
// Stage 1B scope, verbatim from the Stage 1A0 docblock:
//   - load a fixed MP4 fixture (here: from --video / env var)
//   - enable `MediaPlayer.IsVideoFrameServerEnabled = true`
//   - subscribe to `VideoFrameAvailable`
//   - call `MediaPlayer.CopyFrameToVideoSurface` onto an IDirect3DSurface
//   - copy/render the frame into a Direct2D / D3D11 surface
//   - present to the same HWND swap chain shape Stage 1A0 set up
//   - keep min/median/p99 frame timing the way Stage 1A0 does
// No seek slider. No animated overlay. No audio. No cursor sidecar.
// No Flutter texture. No Win2D.
//
// Pass bar (from the Phase 5 design doc):
//   1080p source → median ≤ 16 ms, p99 ≤ 25 ms, measured at the
//   VideoFrameAvailable callback (CopyFrameToVideoSurface + D2D blit +
//   Present round trip). Wall-clock between callbacks is NOT in the
//   measurement — only the work this exe does per frame.
//
// Threading note: VideoFrameAvailable fires on a WinRT thread-pool
// worker. We do the whole render-and-present on that worker thread.
// That requires:
//   * D3D11 device with ID3D11Multithread::SetMultithreadProtected(TRUE)
//   * D2D factory created with D2D1_FACTORY_TYPE_MULTI_THREADED
// IDXGISwapChain1::Present is documented as callable from any thread.
//
// Run:
//   live_compositor:  build/windows-poc/runner/preview/Debug/
//   mediaplayer_frame_server_demo.exe --video="C:\path\to\recording.mp4"

#define WIN32_LEAN_AND_MEAN
// NOMINMAX is set via target_compile_definitions in the POC CMakeLists.

#include <windows.h>
#include <shellapi.h>
#include <inspectable.h>
#include <d2d1_1.h>
#include <d3d11.h>
#include <d3d11_4.h>
#include <dxgi1_2.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <wrl/client.h>

#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <winrt/Windows.Media.Core.h>
#include <winrt/Windows.Media.Playback.h>

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#include "preview/frame_timing.h"

namespace {

using Microsoft::WRL::ComPtr;

namespace winrt_foundation = winrt::Windows::Foundation;
namespace winrt_dxd3d = winrt::Windows::Graphics::DirectX::Direct3D11;
namespace winrt_media = winrt::Windows::Media::Core;
namespace winrt_playback = winrt::Windows::Media::Playback;

constexpr wchar_t kWindowClassName[] = L"ClingfyMediaPlayerFrameServerPOC";
constexpr wchar_t kWindowTitle[] =
    L"Clingfy Live Compositor POC — MediaPlayer frame-server";
constexpr int kDefaultWidth = 1280;
constexpr int kDefaultHeight = 720;

// Per-window / per-process state. The Win32 message loop owns one of
// these; the VideoFrameAvailable handler reaches it via a captured
// pointer, NOT via GWLP_USERDATA, because the handler runs on a worker
// thread that does not own the HWND.
struct DemoState {
  // ---- Direct3D / DXGI / Direct2D ----
  ComPtr<ID3D11Device> d3d_device;
  ComPtr<ID3D11DeviceContext> d3d_context;
  ComPtr<IDXGISwapChain1> swap_chain;
  ComPtr<ID2D1Factory1> d2d_factory;
  ComPtr<ID2D1Device> d2d_device;
  ComPtr<ID2D1DeviceContext> d2d_context;
  ComPtr<ID2D1Bitmap1> backbuffer_bitmap;
  ComPtr<ID2D1SolidColorBrush> black_brush;

  // ---- WinRT MediaPlayer ----
  winrt_dxd3d::IDirect3DDevice winrt_device{nullptr};
  winrt_playback::MediaPlayer player{nullptr};
  winrt::event_token frame_token{};

  // ---- Per-frame video surface ----
  // Created lazily on first VideoFrameAvailable once we know the video
  // size. Re-created on size change.
  ComPtr<ID3D11Texture2D> video_texture;
  ComPtr<ID2D1Bitmap1> video_bitmap;
  winrt_dxd3d::IDirect3DSurface winrt_video_surface{nullptr};
  UINT video_width = 0;
  UINT video_height = 0;

  // ---- Window state ----
  HWND hwnd = nullptr;
  UINT client_width = kDefaultWidth;
  UINT client_height = kDefaultHeight;

  // ---- Synchronization ----
  // The render path is invoked on the WinRT worker thread. The HWND
  // size-change path is invoked on the UI thread. They both touch the
  // swap chain + backbuffer_bitmap. One mutex serializes the two.
  std::mutex render_mutex;
  std::atomic<bool> shutting_down{false};

  // ---- Stats ----
  clingfy::preview::FrameTimingCollector timing;
  std::atomic<bool> stats_printed{false};
  std::atomic<std::uint64_t> dropped_frames{0};

  // ---- CLI ----
  std::wstring video_path;
};

// ---------------------------------------------------------------------
// CLI parsing
// ---------------------------------------------------------------------
//
// Accepts --video=PATH (or --video PATH) on the command line, or the
// CLINGFY_POC_VIDEO environment variable. Quotes are stripped from the
// PATH so callers can drag-drop or shell-escape. No defaults — the exe
// errors out cleanly via MessageBox if neither is provided.
std::wstring ParseVideoPath(LPWSTR cmdline) {
  // ---- 1. Try command line ----
  int argc = 0;
  LPWSTR* argv = ::CommandLineToArgvW(cmdline, &argc);
  std::wstring out;
  if (argv != nullptr) {
    for (int i = 0; i < argc; ++i) {
      std::wstring a = argv[i];
      const std::wstring prefix = L"--video=";
      if (a.rfind(prefix, 0) == 0) {
        out = a.substr(prefix.size());
        break;
      }
      if (a == L"--video" && i + 1 < argc) {
        out = argv[i + 1];
        break;
      }
    }
    ::LocalFree(argv);
  }
  // ---- 2. Fall back to env var ----
  if (out.empty()) {
    wchar_t buf[MAX_PATH * 2] = {};
    const DWORD n = ::GetEnvironmentVariableW(
        L"CLINGFY_POC_VIDEO", buf, ARRAYSIZE(buf));
    if (n > 0 && n < ARRAYSIZE(buf)) {
      out = buf;
    }
  }
  // ---- 3. Strip surrounding double quotes ----
  if (out.size() >= 2 && out.front() == L'"' && out.back() == L'"') {
    out = out.substr(1, out.size() - 2);
  }
  return out;
}

double NowSeconds() {
  LARGE_INTEGER now{}, freq{};
  ::QueryPerformanceCounter(&now);
  ::QueryPerformanceFrequency(&freq);
  return freq.QuadPart > 0
             ? static_cast<double>(now.QuadPart) / freq.QuadPart
             : 0.0;
}

void PrintStatsOnce(DemoState& state) {
  bool expected = false;
  if (!state.stats_printed.compare_exchange_strong(expected, true)) {
    return;
  }
  const auto stats = state.timing.ComputeStats();
  const auto line = clingfy::preview::FrameTimingCollector::FormatStats(stats);
  std::fprintf(stderr, "STAGE1B_STATS %s  dropped=%llu\n", line.c_str(),
               static_cast<unsigned long long>(state.dropped_frames.load()));
  std::fflush(stderr);
}

// ---------------------------------------------------------------------
// D3D11 / D2D setup. Almost identical to Stage 1A0's harness except:
//   * D3D11 device is multi-thread protected.
//   * D2D factory is D2D1_FACTORY_TYPE_MULTI_THREADED.
//   * A WinRT IDirect3DDevice is also constructed so MediaPlayer can be
//     handed surfaces backed by our device.
// ---------------------------------------------------------------------

HRESULT CreateDeviceIndependentResources(DemoState& s) {
  D2D1_FACTORY_OPTIONS opts{};
#if defined(_DEBUG)
  opts.debugLevel = D2D1_DEBUG_LEVEL_INFORMATION;
#endif
  // MULTI_THREADED so the WinRT worker can BeginDraw on its callback.
  return D2D1CreateFactory(D2D1_FACTORY_TYPE_MULTI_THREADED,
                           __uuidof(ID2D1Factory1), &opts,
                           reinterpret_cast<void**>(
                               s.d2d_factory.ReleaseAndGetAddressOf()));
}

HRESULT CreateD3DAndD2DDevices(DemoState& s) {
  UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
#if defined(_DEBUG)
  flags |= D3D11_CREATE_DEVICE_DEBUG;
#endif
  const D3D_FEATURE_LEVEL feature_levels[] = {
      D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0,
      D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0,
  };
  HRESULT hr = D3D11CreateDevice(
      nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags, feature_levels,
      ARRAYSIZE(feature_levels), D3D11_SDK_VERSION,
      s.d3d_device.ReleaseAndGetAddressOf(), nullptr,
      s.d3d_context.ReleaseAndGetAddressOf());
#if defined(_DEBUG)
  if (FAILED(hr)) {
    flags &= ~D3D11_CREATE_DEVICE_DEBUG;
    hr = D3D11CreateDevice(
        nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags, feature_levels,
        ARRAYSIZE(feature_levels), D3D11_SDK_VERSION,
        s.d3d_device.ReleaseAndGetAddressOf(), nullptr,
        s.d3d_context.ReleaseAndGetAddressOf());
  }
#endif
  if (FAILED(hr)) {
    return hr;
  }

  // Enable multi-thread protection on the immediate context: MediaPlayer
  // dispatches our VideoFrameAvailable on a thread-pool worker, and
  // CopyFrameToVideoSurface ends up calling into the same D3D11 device.
  ComPtr<ID3D11Multithread> mt;
  if (SUCCEEDED(s.d3d_context.As(&mt))) {
    mt->SetMultithreadProtected(TRUE);
  }

  ComPtr<IDXGIDevice> dxgi_device;
  hr = s.d3d_device.As(&dxgi_device);
  if (FAILED(hr)) {
    return hr;
  }
  hr = s.d2d_factory->CreateDevice(
      dxgi_device.Get(), s.d2d_device.ReleaseAndGetAddressOf());
  if (FAILED(hr)) {
    return hr;
  }
  hr = s.d2d_device->CreateDeviceContext(
      D2D1_DEVICE_CONTEXT_OPTIONS_NONE,
      s.d2d_context.ReleaseAndGetAddressOf());
  if (FAILED(hr)) {
    return hr;
  }

  // Wrap the same DXGI device as a WinRT IDirect3DDevice so MediaPlayer
  // surfaces are backed by it. (Same pattern wgc_display_capture_backend
  // uses for Phase 3B.)
  ComPtr<::IInspectable> inspectable;
  hr = ::CreateDirect3D11DeviceFromDXGIDevice(
      dxgi_device.Get(),
      reinterpret_cast<::IInspectable**>(inspectable.GetAddressOf()));
  if (FAILED(hr)) {
    return hr;
  }
  winrt::com_ptr<::IInspectable> winrt_inspectable;
  winrt_inspectable.attach(inspectable.Detach());
  s.winrt_device = winrt_inspectable.as<winrt_dxd3d::IDirect3DDevice>();
  return S_OK;
}

HRESULT CreateSwapChainForHwnd(DemoState& s, HWND hwnd) {
  ComPtr<IDXGIDevice> dxgi_device;
  HRESULT hr = s.d3d_device.As(&dxgi_device);
  if (FAILED(hr)) return hr;
  ComPtr<IDXGIAdapter> dxgi_adapter;
  hr = dxgi_device->GetAdapter(dxgi_adapter.GetAddressOf());
  if (FAILED(hr)) return hr;
  ComPtr<IDXGIFactory2> factory;
  hr = dxgi_adapter->GetParent(
      __uuidof(IDXGIFactory2),
      reinterpret_cast<void**>(factory.GetAddressOf()));
  if (FAILED(hr)) return hr;

  DXGI_SWAP_CHAIN_DESC1 desc{};
  desc.Width = s.client_width;
  desc.Height = s.client_height;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
  desc.BufferCount = 2;
  desc.Scaling = DXGI_SCALING_NONE;
  desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
  desc.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
  return factory->CreateSwapChainForHwnd(
      s.d3d_device.Get(), hwnd, &desc, nullptr, nullptr,
      s.swap_chain.ReleaseAndGetAddressOf());
}

HRESULT BindBackBuffer(DemoState& s) {
  s.backbuffer_bitmap.Reset();
  s.d2d_context->SetTarget(nullptr);

  ComPtr<IDXGISurface> dxgi_back;
  HRESULT hr = s.swap_chain->GetBuffer(
      0, __uuidof(IDXGISurface),
      reinterpret_cast<void**>(dxgi_back.GetAddressOf()));
  if (FAILED(hr)) return hr;
  const auto props = D2D1::BitmapProperties1(
      D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                        D2D1_ALPHA_MODE_IGNORE));
  hr = s.d2d_context->CreateBitmapFromDxgiSurface(
      dxgi_back.Get(), &props,
      s.backbuffer_bitmap.ReleaseAndGetAddressOf());
  if (FAILED(hr)) return hr;
  s.d2d_context->SetTarget(s.backbuffer_bitmap.Get());

  // Black brush for the letterbox bars.
  return s.d2d_context->CreateSolidColorBrush(
      D2D1::ColorF(D2D1::ColorF::Black),
      s.black_brush.ReleaseAndGetAddressOf());
}

HRESULT ResizeSwapChain(DemoState& s, UINT w, UINT h) {
  std::lock_guard<std::mutex> lock(s.render_mutex);
  s.client_width = w;
  s.client_height = h;
  s.backbuffer_bitmap.Reset();
  s.d2d_context->SetTarget(nullptr);
  HRESULT hr =
      s.swap_chain->ResizeBuffers(0, w, h, DXGI_FORMAT_UNKNOWN, 0);
  if (FAILED(hr)) return hr;
  return BindBackBuffer(s);
}

// Allocate (or re-allocate) the offscreen texture / WinRT surface / D2D
// bitmap that backs CopyFrameToVideoSurface. Called from the WinRT
// worker thread on the first VideoFrameAvailable, or whenever the video
// reports a new size mid-stream.
HRESULT EnsureVideoTarget(DemoState& s, UINT vw, UINT vh) {
  if (vw == 0 || vh == 0) return E_INVALIDARG;
  if (s.video_texture && s.video_width == vw && s.video_height == vh) {
    return S_OK;
  }
  s.video_bitmap.Reset();
  s.video_texture.Reset();
  s.winrt_video_surface = nullptr;

  D3D11_TEXTURE2D_DESC td{};
  td.Width = vw;
  td.Height = vh;
  td.MipLevels = 1;
  td.ArraySize = 1;
  td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  td.SampleDesc.Count = 1;
  td.Usage = D3D11_USAGE_DEFAULT;
  td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  HRESULT hr = s.d3d_device->CreateTexture2D(
      &td, nullptr, s.video_texture.ReleaseAndGetAddressOf());
  if (FAILED(hr)) return hr;

  // Wrap the same texture as a WinRT IDirect3DSurface for MediaPlayer
  // and as an ID2D1Bitmap1 for the D2D blit. Both consume the same
  // IDXGISurface back end so the COPIED frame lands on it once and is
  // visible to both APIs.
  ComPtr<IDXGISurface> dxgi_surface;
  hr = s.video_texture.As(&dxgi_surface);
  if (FAILED(hr)) return hr;
  ComPtr<::IInspectable> inspectable;
  hr = ::CreateDirect3D11SurfaceFromDXGISurface(
      dxgi_surface.Get(),
      reinterpret_cast<::IInspectable**>(inspectable.GetAddressOf()));
  if (FAILED(hr)) return hr;
  winrt::com_ptr<::IInspectable> winrt_inspectable;
  winrt_inspectable.attach(inspectable.Detach());
  s.winrt_video_surface =
      winrt_inspectable.as<winrt_dxd3d::IDirect3DSurface>();

  const auto props = D2D1::BitmapProperties1(
      D2D1_BITMAP_OPTIONS_NONE,
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                        D2D1_ALPHA_MODE_IGNORE));
  hr = s.d2d_context->CreateBitmapFromDxgiSurface(
      dxgi_surface.Get(), &props,
      s.video_bitmap.ReleaseAndGetAddressOf());
  if (FAILED(hr)) return hr;

  s.video_width = vw;
  s.video_height = vh;
  return S_OK;
}

// Compute the centered, aspect-preserving destination rect on the back
// buffer for the current video size + window size. Letterbox bars are
// drawn in black where the rect doesn't cover.
D2D1_RECT_F LetterboxRect(UINT win_w, UINT win_h, UINT vid_w, UINT vid_h) {
  if (win_w == 0 || win_h == 0 || vid_w == 0 || vid_h == 0) {
    return {0, 0, static_cast<float>(win_w), static_cast<float>(win_h)};
  }
  const double win_ratio = static_cast<double>(win_w) / win_h;
  const double vid_ratio = static_cast<double>(vid_w) / vid_h;
  double draw_w = 0, draw_h = 0;
  if (vid_ratio > win_ratio) {
    // Video wider than window → letterbox top/bottom.
    draw_w = win_w;
    draw_h = win_w / vid_ratio;
  } else {
    // Video taller (or equal) than window → letterbox left/right.
    draw_h = win_h;
    draw_w = win_h * vid_ratio;
  }
  const double left = (win_w - draw_w) * 0.5;
  const double top = (win_h - draw_h) * 0.5;
  return {static_cast<float>(left), static_cast<float>(top),
          static_cast<float>(left + draw_w),
          static_cast<float>(top + draw_h)};
}

// The Phase 5 design doc question being answered here: end-to-end
// per-frame work time (CopyFrameToVideoSurface + D2D blit + Present).
// Measured at the VideoFrameAvailable callback. Wall-clock between
// callbacks is NOT in the measurement.
void HandleVideoFrameAvailable(DemoState& s,
                               winrt_playback::MediaPlayer const& sender) {
  if (s.shutting_down.load()) {
    s.dropped_frames.fetch_add(1, std::memory_order_relaxed);
    return;
  }
  s.timing.BeginFrame();

  std::lock_guard<std::mutex> lock(s.render_mutex);
  if (!s.swap_chain || !s.backbuffer_bitmap) {
    s.dropped_frames.fetch_add(1, std::memory_order_relaxed);
    s.timing.EndFrame();
    return;
  }

  // Pull the natural video size from the playback session. This may
  // become non-zero only after the first frame arrives.
  const auto session = sender.PlaybackSession();
  const UINT vw = session.NaturalVideoWidth();
  const UINT vh = session.NaturalVideoHeight();
  if (vw == 0 || vh == 0) {
    s.dropped_frames.fetch_add(1, std::memory_order_relaxed);
    s.timing.EndFrame();
    return;
  }
  if (FAILED(EnsureVideoTarget(s, vw, vh))) {
    s.dropped_frames.fetch_add(1, std::memory_order_relaxed);
    s.timing.EndFrame();
    return;
  }

  // Hand off the decoded frame to our shared surface. This is the moment
  // MediaPlayer touches our D3D11 device from its worker thread; the
  // multi-thread-protected context handles the locking for us.
  try {
    sender.CopyFrameToVideoSurface(s.winrt_video_surface);
  } catch (winrt::hresult_error const&) {
    s.dropped_frames.fetch_add(1, std::memory_order_relaxed);
    s.timing.EndFrame();
    return;
  }

  // Letterbox + D2D blit + present.
  s.d2d_context->BeginDraw();
  s.d2d_context->Clear(D2D1::ColorF(0.0f, 0.0f, 0.0f, 1.0f));
  const auto dest = LetterboxRect(s.client_width, s.client_height,
                                  s.video_width, s.video_height);
  s.d2d_context->DrawBitmap(s.video_bitmap.Get(), &dest, 1.0f,
                            D2D1_BITMAP_INTERPOLATION_MODE_LINEAR);
  const HRESULT end_hr = s.d2d_context->EndDraw();
  if (end_hr == D2DERR_RECREATE_TARGET) {
    BindBackBuffer(s);
  }

  // SyncInterval 0 — MediaPlayer paces by video PTS, not by our vsync.
  // Using SyncInterval 1 would tie the timing to the display refresh
  // and mask MediaPlayer's pacing behavior.
  s.swap_chain->Present(0, 0);

  s.timing.EndFrame();
}

// ---------------------------------------------------------------------
// Win32 plumbing
// ---------------------------------------------------------------------

LRESULT CALLBACK WindowProc(HWND hwnd, UINT msg, WPARAM wparam,
                            LPARAM lparam) {
  auto* state = reinterpret_cast<DemoState*>(
      ::GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  switch (msg) {
    case WM_CREATE: {
      auto* cs = reinterpret_cast<CREATESTRUCTW*>(lparam);
      ::SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                          reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
      return 0;
    }
    case WM_SIZE: {
      if (state && state->swap_chain) {
        const UINT w = LOWORD(lparam);
        const UINT h = HIWORD(lparam);
        if (w > 0 && h > 0) {
          ResizeSwapChain(*state, w, h);
        }
      }
      return 0;
    }
    case WM_PAINT: {
      PAINTSTRUCT ps;
      ::BeginPaint(hwnd, &ps);
      ::EndPaint(hwnd, &ps);
      return 0;
    }
    case WM_CLOSE: {
      if (state) PrintStatsOnce(*state);
      ::DestroyWindow(hwnd);
      return 0;
    }
    case WM_DESTROY: {
      if (state) PrintStatsOnce(*state);
      ::PostQuitMessage(0);
      return 0;
    }
    case WM_KEYDOWN: {
      if (wparam == VK_ESCAPE) {
        ::SendMessageW(hwnd, WM_CLOSE, 0, 0);
        return 0;
      }
      break;
    }
    default:
      break;
  }
  return ::DefWindowProcW(hwnd, msg, wparam, lparam);
}

int ShowErrorAndExit(const std::wstring& msg, int code) {
  ::MessageBoxW(nullptr, msg.c_str(), kWindowTitle, MB_ICONERROR);
  return code;
}

int RunDemo(HINSTANCE hinstance, int show_cmd, LPWSTR cmdline) {
  // ---- 1. Parse CLI ----
  const std::wstring video_path = ParseVideoPath(cmdline);
  if (video_path.empty()) {
    return ShowErrorAndExit(
        L"No video specified. Pass --video=PATH or set the\n"
        L"CLINGFY_POC_VIDEO environment variable.",
        100);
  }
  if (::GetFileAttributesW(video_path.c_str()) == INVALID_FILE_ATTRIBUTES) {
    return ShowErrorAndExit(
        L"Video file not found:\n" + video_path, 101);
  }

  // ---- 2. Init COM apartment for the UI thread ----
  // MediaPlayer is a WinRT type; the calling apartment must be
  // initialized. STA on the UI thread is the standard pattern for a
  // GUI exe — VideoFrameAvailable still dispatches on the WinRT
  // thread pool regardless.
  winrt::init_apartment(winrt::apartment_type::single_threaded);

  // ---- 3. Register window class ----
  WNDCLASSEXW wc{};
  wc.cbSize = sizeof(wc);
  wc.style = CS_HREDRAW | CS_VREDRAW;
  wc.lpfnWndProc = WindowProc;
  wc.hInstance = hinstance;
  wc.hCursor = ::LoadCursorW(nullptr, IDC_ARROW);
  wc.hbrBackground = nullptr;
  wc.lpszClassName = kWindowClassName;
  if (!::RegisterClassExW(&wc)) return 1;

  DemoState state;
  state.video_path = video_path;

  // ---- 4. Devices ----
  if (FAILED(CreateDeviceIndependentResources(state))) {
    return ShowErrorAndExit(L"Failed to create D2D factory.", 2);
  }
  if (FAILED(CreateD3DAndD2DDevices(state))) {
    return ShowErrorAndExit(L"Failed to create D3D11 / D2D device.", 3);
  }

  // ---- 5. Window ----
  RECT window_rect = {0, 0, kDefaultWidth, kDefaultHeight};
  ::AdjustWindowRectEx(&window_rect, WS_OVERLAPPEDWINDOW, FALSE,
                       WS_EX_APPWINDOW);
  state.hwnd = ::CreateWindowExW(
      WS_EX_APPWINDOW, kWindowClassName, kWindowTitle, WS_OVERLAPPEDWINDOW,
      CW_USEDEFAULT, CW_USEDEFAULT, window_rect.right - window_rect.left,
      window_rect.bottom - window_rect.top, nullptr, nullptr, hinstance,
      &state);
  if (!state.hwnd) return 4;
  if (FAILED(CreateSwapChainForHwnd(state, state.hwnd))) {
    ::DestroyWindow(state.hwnd);
    return ShowErrorAndExit(L"Failed to create DXGI swap chain.", 5);
  }
  if (FAILED(BindBackBuffer(state))) {
    ::DestroyWindow(state.hwnd);
    return 6;
  }
  ::ShowWindow(state.hwnd, show_cmd);
  ::UpdateWindow(state.hwnd);

  // ---- 6. MediaPlayer + frame-server mode ----
  try {
    state.player = winrt_playback::MediaPlayer();
    state.player.IsVideoFrameServerEnabled(true);
    state.player.IsLoopingEnabled(true);

    // Build a URI from the absolute file path. file:/// scheme works
    // for both packaged and unpackaged Win32 apps.
    wchar_t full[MAX_PATH * 2] = {};
    const DWORD n =
        ::GetFullPathNameW(state.video_path.c_str(), ARRAYSIZE(full),
                           full, nullptr);
    if (n == 0 || n >= ARRAYSIZE(full)) {
      ::DestroyWindow(state.hwnd);
      return ShowErrorAndExit(
          L"Could not resolve video path to an absolute file URI.", 7);
    }
    std::wstring uri = L"file:///";
    for (DWORD i = 0; i < n; ++i) {
      uri.push_back(full[i] == L'\\' ? L'/' : full[i]);
    }
    const winrt_foundation::Uri winrt_uri{uri};
    state.player.Source(winrt_media::MediaSource::CreateFromUri(winrt_uri));

    // Subscribe BEFORE Play() — frames can fire immediately on the
    // worker thread once the source is ready.
    state.frame_token = state.player.VideoFrameAvailable(
        [&state](winrt_playback::MediaPlayer const& sender,
                 winrt_foundation::IInspectable const& /*args*/) {
          HandleVideoFrameAvailable(state, sender);
        });
    state.player.Play();
  } catch (winrt::hresult_error const& e) {
    ::DestroyWindow(state.hwnd);
    return ShowErrorAndExit(
        std::wstring(L"MediaPlayer setup failed: ") + e.message().c_str(),
        8);
  }

  // ---- 7. Message loop ----
  // No idle rendering: MediaPlayer drives every frame via the worker
  // thread. The UI thread just pumps Win32 messages.
  MSG msg{};
  while (::GetMessageW(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessageW(&msg);
  }

  // ---- 8. Tear down ----
  state.shutting_down.store(true);
  try {
    if (state.player) {
      state.player.Pause();
      if (state.frame_token.value) {
        state.player.VideoFrameAvailable(state.frame_token);
      }
      state.player.Close();
      state.player = nullptr;
    }
  } catch (winrt::hresult_error const&) {
    // Best-effort. Stats already printed by WM_DESTROY.
  }
  PrintStatsOnce(state);
  return static_cast<int>(msg.wParam);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE hinstance,
                      _In_opt_ HINSTANCE /*hprev*/,
                      _In_ LPWSTR cmdline, _In_ int show_cmd) {
  return RunDemo(hinstance, show_cmd, cmdline);
}
