// Windows Phase 5 POC — Stage 1A0: Direct2D HWND timing harness.
//
// What this is: an opt-in standalone Win32 GUI executable that proves
// the build / GPU-rendering / frame-timing slice of the Phase 5 design
// works end-to-end on a real Windows machine. Pure rendering harness,
// no video decode, no cursor data, no Flutter integration.
//
// What this is NOT: production code. It is not linked into the main
// Flutter app. It does not touch the bridge contract or the Flutter
// preview surface. The cmake option BUILD_LIVE_COMPOSITOR_POC defaults
// to OFF, so `flutter build windows` ignores this file entirely.
//
// Stage 1A0 scope (deliberately small):
//   - Win32 HWND opens with the title "Clingfy Live Compositor POC".
//   - A GPU-backed DXGI swap chain renders an animated pulsing +
//     rotating square so the developer can confirm the rendering
//     pipeline is producing real output.
//   - FrameTimingCollector measures per-frame elapsed time via QPC and
//     prints min / median / p99 / max on shutdown.
//
// Out of scope for Stage 1A0 (will arrive in later sub-stages):
//   - Stage 1B: MediaPlayer frame-server → Direct2D HWND. Concretely:
//       * load a fixed MP4 fixture
//       * enable `MediaPlayer.IsVideoFrameServerEnabled = true`
//       * subscribe to `VideoFrameAvailable`
//       * call `MediaPlayer.CopyFrameToVideoSurface` to lift each
//         decoded frame onto an `IDirect3DSurface`
//       * copy/render the frame into a Direct2D / D3D11 surface
//       * present to the same HWND swap chain Stage 1A0 set up
//       * keep min/median/p99 frame timing the way Stage 1A0 does
//   - Cursor sidecar parsing + zoom composition (later).
//   - Win2D upgrade (`Microsoft.Graphics.Win2D` NuGet + WindowsAppSDK
//     runtime bootstrap + C++/WinRT projection headers) — deferred
//     past Stage 1B because Direct2D's interop with `IDirect3DSurface`
//     from MediaPlayer frame-server is enough to validate the
//     architecture; Win2D's effects layer is only worth the NuGet cost
//     once we know we want it.
//   - Flutter `Texture` bridge integration (Stage 2).
//
// Why Direct2D for the GPU 2D layer:
//   Direct2D is shipped with the Windows SDK — no NuGet, no
//   bootstrapper, no codegen. It is the underlying GPU 2D path that
//   Win2D itself wraps, so the architectural risk being de-risked here
//   (does GPU 2D rendering at 60fps composited work in our build /
//   driver mix?) is the same. The output surfaces (D2D bitmap from
//   `IDXGISurface`) compose naturally with MediaPlayer frame-server's
//   `IDirect3DSurface` outputs in Stage 1B.
//
// Build & run (developer machine, not CI):
//   cmake -S windows -B build/windows-poc -DBUILD_LIVE_COMPOSITOR_POC=ON ...
//   cmake --build build/windows-poc --config Debug --target live_compositor_demo
//   build/windows-poc/runner/preview/Debug/live_compositor_demo.exe
//
// On close, the process prints one line of stats to stderr:
//   STAGE1A_STATS frames=N min=… median=… p99=… max=…
// (Print, don't write to disk — Stage 1A0 is interactive, not a CI job.)

#define WIN32_LEAN_AND_MEAN
// NOMINMAX is set on the command line via target_compile_definitions in
// the POC CMakeLists; don't redefine it here.
#include <windows.h>

#include <d2d1_1.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <wrl/client.h>

#include <cstdio>
#include <cmath>

#include "preview/frame_timing.h"

namespace {

using Microsoft::WRL::ComPtr;

constexpr wchar_t kWindowClassName[] = L"ClingfyLiveCompositorPOC";
constexpr wchar_t kWindowTitle[] = L"Clingfy Live Compositor POC";
constexpr int kDefaultWidth = 1280;
constexpr int kDefaultHeight = 720;

// Per-window state, owned by the message loop. A pointer to this is
// stashed in the HWND's GWLP_USERDATA so the WndProc can reach it.
struct DemoState {
  ComPtr<ID3D11Device> d3d_device;
  ComPtr<ID3D11DeviceContext> d3d_context;
  ComPtr<IDXGISwapChain1> swap_chain;
  ComPtr<ID2D1Factory1> d2d_factory;
  ComPtr<ID2D1Device> d2d_device;
  ComPtr<ID2D1DeviceContext> d2d_context;
  ComPtr<ID2D1Bitmap1> backbuffer_bitmap;
  ComPtr<ID2D1SolidColorBrush> brush;

  UINT width = kDefaultWidth;
  UINT height = kDefaultHeight;
  double start_time_seconds = 0.0;
  LARGE_INTEGER qpc_frequency{};
  LARGE_INTEGER qpc_start{};

  clingfy::preview::FrameTimingCollector timing;
  bool stats_printed = false;
};

double NowSeconds(const DemoState& state) {
  LARGE_INTEGER now{};
  QueryPerformanceCounter(&now);
  const double delta =
      static_cast<double>(now.QuadPart - state.qpc_start.QuadPart);
  const double freq = static_cast<double>(state.qpc_frequency.QuadPart);
  return freq > 0 ? delta / freq : 0.0;
}

void PrintStatsOnce(DemoState& state) {
  if (state.stats_printed) {
    return;
  }
  state.stats_printed = true;
  const auto stats = state.timing.ComputeStats();
  const auto line = clingfy::preview::FrameTimingCollector::FormatStats(stats);
  // Use stderr so it does not get swallowed by GUI subsystem buffering.
  std::fprintf(stderr, "STAGE1A_STATS %s\n", line.c_str());
  std::fflush(stderr);
}

// Create the D3D11 device first (BGRA support required for D2D interop),
// the DXGI swap chain second, the D2D device/context third, and finally
// the D2D bitmap that wraps the swap-chain back buffer. Splits exist so
// the resize path can rebuild just the swap-chain-dependent objects.
HRESULT CreateDeviceIndependentResources(DemoState& state) {
  D2D1_FACTORY_OPTIONS options{};
#if defined(_DEBUG)
  options.debugLevel = D2D1_DEBUG_LEVEL_INFORMATION;
#endif
  return D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,
                           __uuidof(ID2D1Factory1), &options,
                           reinterpret_cast<void**>(
                               state.d2d_factory.ReleaseAndGetAddressOf()));
}

HRESULT CreateD3DAndD2DDevices(DemoState& state) {
  UINT creation_flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
#if defined(_DEBUG)
  // Debug layer is best-effort; if it's not installed (no Graphics Tools
  // optional feature) the call falls back below to a non-debug device.
  creation_flags |= D3D11_CREATE_DEVICE_DEBUG;
#endif
  const D3D_FEATURE_LEVEL feature_levels[] = {
      D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0,
      D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0,
  };

  HRESULT hr = D3D11CreateDevice(
      nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, creation_flags,
      feature_levels, ARRAYSIZE(feature_levels), D3D11_SDK_VERSION,
      state.d3d_device.ReleaseAndGetAddressOf(), nullptr,
      state.d3d_context.ReleaseAndGetAddressOf());
#if defined(_DEBUG)
  if (FAILED(hr)) {
    // Retry without debug layer.
    creation_flags &= ~D3D11_CREATE_DEVICE_DEBUG;
    hr = D3D11CreateDevice(
        nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, creation_flags,
        feature_levels, ARRAYSIZE(feature_levels), D3D11_SDK_VERSION,
        state.d3d_device.ReleaseAndGetAddressOf(), nullptr,
        state.d3d_context.ReleaseAndGetAddressOf());
  }
#endif
  if (FAILED(hr)) {
    return hr;
  }

  ComPtr<IDXGIDevice> dxgi_device;
  hr = state.d3d_device.As(&dxgi_device);
  if (FAILED(hr)) {
    return hr;
  }
  hr = state.d2d_factory->CreateDevice(
      dxgi_device.Get(), state.d2d_device.ReleaseAndGetAddressOf());
  if (FAILED(hr)) {
    return hr;
  }
  return state.d2d_device->CreateDeviceContext(
      D2D1_DEVICE_CONTEXT_OPTIONS_NONE,
      state.d2d_context.ReleaseAndGetAddressOf());
}

HRESULT CreateSwapChainForHwnd(DemoState& state, HWND hwnd) {
  ComPtr<IDXGIDevice> dxgi_device;
  HRESULT hr = state.d3d_device.As(&dxgi_device);
  if (FAILED(hr)) {
    return hr;
  }
  ComPtr<IDXGIAdapter> dxgi_adapter;
  hr = dxgi_device->GetAdapter(dxgi_adapter.GetAddressOf());
  if (FAILED(hr)) {
    return hr;
  }
  ComPtr<IDXGIFactory2> dxgi_factory;
  hr = dxgi_adapter->GetParent(
      __uuidof(IDXGIFactory2),
      reinterpret_cast<void**>(dxgi_factory.GetAddressOf()));
  if (FAILED(hr)) {
    return hr;
  }

  DXGI_SWAP_CHAIN_DESC1 desc{};
  desc.Width = state.width;
  desc.Height = state.height;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
  desc.BufferCount = 2;
  desc.Scaling = DXGI_SCALING_NONE;
  desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
  desc.AlphaMode = DXGI_ALPHA_MODE_IGNORE;

  return dxgi_factory->CreateSwapChainForHwnd(
      state.d3d_device.Get(), hwnd, &desc, nullptr, nullptr,
      state.swap_chain.ReleaseAndGetAddressOf());
}

HRESULT BindBackBufferToD2D(DemoState& state) {
  state.backbuffer_bitmap.Reset();
  state.d2d_context->SetTarget(nullptr);

  ComPtr<IDXGISurface> dxgi_backbuffer;
  HRESULT hr = state.swap_chain->GetBuffer(
      0, __uuidof(IDXGISurface),
      reinterpret_cast<void**>(dxgi_backbuffer.GetAddressOf()));
  if (FAILED(hr)) {
    return hr;
  }
  const auto props = D2D1::BitmapProperties1(
      D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                        D2D1_ALPHA_MODE_IGNORE));
  hr = state.d2d_context->CreateBitmapFromDxgiSurface(
      dxgi_backbuffer.Get(), &props,
      state.backbuffer_bitmap.ReleaseAndGetAddressOf());
  if (FAILED(hr)) {
    return hr;
  }
  state.d2d_context->SetTarget(state.backbuffer_bitmap.Get());

  // Color brush — color is overwritten per frame to animate.
  return state.d2d_context->CreateSolidColorBrush(
      D2D1::ColorF(D2D1::ColorF::White),
      state.brush.ReleaseAndGetAddressOf());
}

HRESULT ResizeSwapChain(DemoState& state, UINT new_width, UINT new_height) {
  state.width = new_width;
  state.height = new_height;
  state.backbuffer_bitmap.Reset();
  state.d2d_context->SetTarget(nullptr);
  HRESULT hr = state.swap_chain->ResizeBuffers(
      0, new_width, new_height, DXGI_FORMAT_UNKNOWN, 0);
  if (FAILED(hr)) {
    return hr;
  }
  return BindBackBufferToD2D(state);
}

// HSV->RGB with all channels in [0, 1]. Used to smoothly cycle the fill
// color around the wheel so the human eye can confirm the pipeline is
// still drawing live frames (not a frozen image).
D2D1_COLOR_F HsvToRgb(double h, double s, double v) {
  const double c = v * s;
  const double hh = std::fmod(h, 1.0) * 6.0;
  const double x = c * (1.0 - std::fabs(std::fmod(hh, 2.0) - 1.0));
  double r = 0, g = 0, b = 0;
  if (hh < 1) { r = c; g = x; }
  else if (hh < 2) { r = x; g = c; }
  else if (hh < 3) { g = c; b = x; }
  else if (hh < 4) { g = x; b = c; }
  else if (hh < 5) { r = x; b = c; }
  else             { r = c; b = x; }
  const double m = v - c;
  return D2D1::ColorF(static_cast<float>(r + m), static_cast<float>(g + m),
                      static_cast<float>(b + m), 1.0f);
}

void RenderFrame(DemoState& state) {
  state.timing.BeginFrame();

  const double t = NowSeconds(state);

  state.d2d_context->BeginDraw();
  // Dark slate background so the animated square is unmistakable.
  state.d2d_context->Clear(D2D1::ColorF(0.10f, 0.10f, 0.12f, 1.0f));

  // Center the square, pulse its size with sin(t), rotate with elapsed
  // time. Two visible animation axes (color cycle + size pulse + spin)
  // so 60fps vs 30fps is easy to tell by eye.
  const float cx = static_cast<float>(state.width) * 0.5f;
  const float cy = static_cast<float>(state.height) * 0.5f;
  const float base_size =
      static_cast<float>(std::min(state.width, state.height)) * 0.30f;
  const float pulse =
      0.85f + 0.15f * static_cast<float>(std::sin(t * 1.8));
  const float side = base_size * pulse;

  const auto color = HsvToRgb(std::fmod(t * 0.10, 1.0), 0.75, 0.95);
  state.brush->SetColor(color);

  const float rotation_deg = static_cast<float>(std::fmod(t * 60.0, 360.0));
  const auto transform = D2D1::Matrix3x2F::Rotation(
      rotation_deg, D2D1::Point2F(cx, cy));
  state.d2d_context->SetTransform(transform);

  const D2D1_RECT_F rect = {cx - side * 0.5f, cy - side * 0.5f,
                            cx + side * 0.5f, cy + side * 0.5f};
  state.d2d_context->FillRectangle(rect, state.brush.Get());

  state.d2d_context->SetTransform(D2D1::Matrix3x2F::Identity());

  const HRESULT end_hr = state.d2d_context->EndDraw();
  if (end_hr == D2DERR_RECREATE_TARGET) {
    BindBackBufferToD2D(state);
  }

  // SyncInterval 1 = vsync to the display refresh. This caps the loop at
  // the monitor's refresh rate and keeps the frame timings meaningful.
  state.swap_chain->Present(1, 0);

  state.timing.EndFrame();
}

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
      // We render on the idle loop, not WM_PAINT, so just validate the
      // paint region to silence the message and let the loop drive
      // rendering.
      PAINTSTRUCT ps;
      ::BeginPaint(hwnd, &ps);
      ::EndPaint(hwnd, &ps);
      return 0;
    }
    case WM_CLOSE: {
      if (state) {
        PrintStatsOnce(*state);
      }
      ::DestroyWindow(hwnd);
      return 0;
    }
    case WM_DESTROY: {
      if (state) {
        PrintStatsOnce(*state);
      }
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

int RunDemo(HINSTANCE hinstance, int show_cmd) {
  WNDCLASSEXW wc{};
  wc.cbSize = sizeof(wc);
  wc.style = CS_HREDRAW | CS_VREDRAW;
  wc.lpfnWndProc = WindowProc;
  wc.hInstance = hinstance;
  wc.hCursor = ::LoadCursorW(nullptr, IDC_ARROW);
  wc.hbrBackground = nullptr;  // we paint every pixel ourselves
  wc.lpszClassName = kWindowClassName;
  if (!::RegisterClassExW(&wc)) {
    return 1;
  }

  DemoState state;
  ::QueryPerformanceFrequency(&state.qpc_frequency);
  ::QueryPerformanceCounter(&state.qpc_start);

  if (FAILED(CreateDeviceIndependentResources(state))) {
    ::MessageBoxW(nullptr, L"Failed to create D2D factory.",
                  kWindowTitle, MB_ICONERROR);
    return 2;
  }
  if (FAILED(CreateD3DAndD2DDevices(state))) {
    ::MessageBoxW(nullptr,
                  L"Failed to create D3D11 / D2D device. Stage 1A needs a "
                  L"GPU with at least D3D feature level 10.0.",
                  kWindowTitle, MB_ICONERROR);
    return 3;
  }

  // Account for window-frame chrome so the client area is the requested
  // size — that way the timing run is at a predictable resolution.
  RECT window_rect = {0, 0, kDefaultWidth, kDefaultHeight};
  ::AdjustWindowRectEx(&window_rect, WS_OVERLAPPEDWINDOW, FALSE,
                       WS_EX_APPWINDOW);
  HWND hwnd = ::CreateWindowExW(
      WS_EX_APPWINDOW, kWindowClassName, kWindowTitle, WS_OVERLAPPEDWINDOW,
      CW_USEDEFAULT, CW_USEDEFAULT, window_rect.right - window_rect.left,
      window_rect.bottom - window_rect.top, nullptr, nullptr, hinstance,
      &state);
  if (!hwnd) {
    return 4;
  }
  if (FAILED(CreateSwapChainForHwnd(state, hwnd))) {
    ::DestroyWindow(hwnd);
    ::MessageBoxW(nullptr, L"Failed to create DXGI swap chain.",
                  kWindowTitle, MB_ICONERROR);
    return 5;
  }
  if (FAILED(BindBackBufferToD2D(state))) {
    ::DestroyWindow(hwnd);
    return 6;
  }

  ::ShowWindow(hwnd, show_cmd);
  ::UpdateWindow(hwnd);

  // Idle-rendering loop. Pump messages with PeekMessage so we render
  // every iteration; the swap chain's Present(1, 0) caps the FPS to the
  // monitor refresh rate.
  MSG msg{};
  while (true) {
    while (::PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
      if (msg.message == WM_QUIT) {
        PrintStatsOnce(state);
        return static_cast<int>(msg.wParam);
      }
      ::TranslateMessage(&msg);
      ::DispatchMessageW(&msg);
    }
    if (state.backbuffer_bitmap) {
      RenderFrame(state);
    }
  }
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE hinstance,
                      _In_opt_ HINSTANCE /*hprev*/,
                      _In_ LPWSTR /*cmdline*/, _In_ int show_cmd) {
  return RunDemo(hinstance, show_cmd);
}
