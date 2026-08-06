#include "Capture/Camera/camera_dcomp_overlay.h"

#include <d2d1helper.h>

#include <algorithm>
#include <cstdio>
#include <utility>

#include "Bridge/Devices/device_probe_log.h"
#include "Bridge/native_log_publisher.h"
#include "Capture/Camera/camera_dcomp_device_loss.h"
#include "Capture/Camera/camera_overlay_drag.h"
#include "Capture/Camera/camera_overlay_geometry_store.h"
#include "Capture/Camera/camera_overlay_glow.h"
#include "Capture/Camera/camera_overlay_glow_renderer.h"
#include "Capture/Camera/camera_overlay_style_store.h"

namespace clingfy::capture {

namespace {

using Microsoft::WRL::ComPtr;

constexpr wchar_t kWindowClassName[] = L"ClingfyCameraDcompOverlay";
constexpr UINT_PTR kTickTimerId = 1;
constexpr UINT kTickIntervalMs = 33;  // ~30 fps sync/redraw.
// After this many back-to-back device losses the in-place rebuild is judged
// futile (a wedged adapter, not a one-off TDR) and the presenter stops trying,
// logging the hook the mid-session GDI fallback (P4c-c3) will act on.
constexpr int kMaxConsecutiveDeviceLosses = 3;
constexpr UINT kMsgShow = WM_APP + 1;
constexpr UINT kMsgHide = WM_APP + 2;

void EnsureClassRegistered() {
  static std::once_flag flag;
  std::call_once(flag, []() {
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = &CameraDcompOverlay::WndProc;
    wc.hInstance = ::GetModuleHandleW(nullptr);
    wc.hCursor = ::LoadCursorW(nullptr, IDC_SIZEALL);  // hints "draggable".
    wc.hbrBackground = nullptr;  // never painted — DComp owns the content.
    wc.lpszClassName = kWindowClassName;
    ::RegisterClassExW(&wc);
  });
}

// Work area + DPI scale of the monitor the window currently sits on — the
// inputs ComputeSquareFloatingRect needs. Mirrors the GDI presenter.
RECT MonitorWorkArea(HWND hwnd) {
  RECT work{0, 0, ::GetSystemMetrics(SM_CXSCREEN),
            ::GetSystemMetrics(SM_CYSCREEN)};
  if (HMONITOR mon = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
      mon != nullptr) {
    MONITORINFO mi{};
    mi.cbSize = sizeof(mi);
    if (::GetMonitorInfoW(mon, &mi) != 0) {
      work = mi.rcWork;
    }
  }
  return work;
}

}  // namespace

CameraDcompOverlay::~CameraDcompOverlay() { Stop(); }

LRESULT CALLBACK CameraDcompOverlay::WndProc(HWND hwnd, UINT msg,
                                             WPARAM wparam, LPARAM lparam) {
  if (msg == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCTW*>(lparam);
    ::SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
    return ::DefWindowProcW(hwnd, msg, wparam, lparam);
  }
  auto* self = reinterpret_cast<CameraDcompOverlay*>(
      ::GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  switch (msg) {
    case WM_NCHITTEST: {
      // Content square = drag handle; the effect-padding halo is
      // click-through so windows beneath stay interactive (macOS hitTest
      // parity). Coordinates arrive in screen space, signed.
      if (self != nullptr) {
        const int sx = static_cast<short>(LOWORD(lparam));
        const int sy = static_cast<short>(HIWORD(lparam));
        RECT wr{};
        if (::GetWindowRect(hwnd, &wr) != 0 &&
            !CameraOverlayPointInContent(sx - wr.left, sy - wr.top,
                                         self->prepared_padding_px_,
                                         self->prepared_content_side_)) {
          return HTTRANSPARENT;
        }
      }
      return HTCAPTION;
    }
    case WM_ENTERSIZEMOVE:
      // OS modal drag in progress: the sync tick must not SetWindowPos-fight
      // the user's grab (store revisions stay unconsumed until the drop).
      if (self != nullptr) {
        self->in_size_move_ = true;
      }
      return 0;
    case WM_EXITSIZEMOVE:
      if (self != nullptr) {
        self->in_size_move_ = false;
        self->OnDragEnded(hwnd);
      }
      return 0;
    case kMsgShow:
      // Last line of defense for invariant "never show an unexcluded bubble":
      // a Show posted by the engine just before a WDA-loss hide (the re-verify
      // path) must not resurrect the window after it.
      if (self == nullptr || !self->options_.apply_capture_exclusion ||
          self->wda_excluded_.load()) {
        ::ShowWindow(hwnd, SW_SHOWNA);
      }
      return 0;
    case kMsgHide:
      ::ShowWindow(hwnd, SW_HIDE);
      return 0;
    case WM_TIMER:
      if (wparam == kTickTimerId && self != nullptr) {
        self->SyncAndRender(hwnd);
      }
      return 0;
    case WM_PAINT: {
      // No GDI painting — validate so Windows stops asking.
      PAINTSTRUCT ps{};
      ::BeginPaint(hwnd, &ps);
      ::EndPaint(hwnd, &ps);
      return 0;
    }
    case WM_ERASEBKGND:
      return 1;
    default:
      return ::DefWindowProcW(hwnd, msg, wparam, lparam);
  }
}

bool CameraDcompOverlay::Start(const FloatingPlacement& placement) {
  if (running_.load()) {
    return true;
  }
  std::promise<bool> ready;
  std::future<bool> fut = ready.get_future();
  thread_ =
      std::thread(&CameraDcompOverlay::ThreadMain, this, placement, &ready);
  const bool ok = fut.get();
  if (!ok && thread_.joinable()) {
    thread_.join();
  }
  return ok;
}

void CameraDcompOverlay::ThreadMain(FloatingPlacement placement,
                                    std::promise<bool>* ready) {
  thread_id_ = ::GetCurrentThreadId();
  EnsureClassRegistered();

  // The initial placement is corrected from the geometry store below (square
  // model) before the window can ever be shown; only its monitor matters.
  //
  // WS_EX_LAYERED from birth (P4a): cross-thread click-through needs the
  // LAYERED|TRANSPARENT pair — HTTRANSPARENT alone only falls through to
  // windows of the SAME thread, so halo clicks over other apps would be
  // swallowed. DComp content bypasses the redirection surface, so LAYERED
  // costs nothing (the PowerToys crosshairs-overlay combination). Only the
  // TRANSPARENT bit ever changes after creation (cursor-tracked on the tick);
  // WDA is re-verified after every flip. Created TRANSPARENT: the cursor
  // starts off-content.
  HWND hwnd = ::CreateWindowExW(
      WS_EX_NOREDIRECTIONBITMAP | WS_EX_TOPMOST | WS_EX_TOOLWINDOW |
          WS_EX_NOACTIVATE | WS_EX_LAYERED | WS_EX_TRANSPARENT,
      kWindowClassName, L"Clingfy Camera", WS_POPUP, placement.x, placement.y,
      std::max(1, placement.width), std::max(1, placement.height), nullptr,
      nullptr, ::GetModuleHandleW(nullptr), this);
  if (hwnd == nullptr) {
    ready->set_value(false);
    return;
  }
  // A LAYERED window renders only after its attributes are set; fully opaque —
  // per-pixel alpha comes from the DComp visual, not the layered machinery.
  ::SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA);
  click_through_ = true;

  // Padded square placement per the stores, while still hidden. The style
  // store participates in sizing now (effect padding follows border/shadow/
  // glow), so its revision is consumed here too — the first camera frame's
  // dimension change still forces the initial painter Prepare.
  const RECT work = MonitorWorkArea(hwnd);
  const UINT dpi = ::GetDpiForWindow(hwnd);
  const double scale = CurrentScale(hwnd);
  auto& geometry_store = CameraOverlayGeometryStore::Instance();
  auto& style_store = CameraOverlayStyleStore::Instance();
  last_geometry_revision_ = geometry_store.revision();
  last_style_revision_ = style_store.revision();
  const PaddedSquareRect placed = ComputePaddedSquareFloatingRect(
      work.left, work.top, work.right, work.bottom, scale,
      geometry_store.Snapshot(),
      ComputeCameraEffectPadding(style_store.Snapshot()));
  ::SetWindowPos(hwnd, nullptr, placed.window.x, placed.window.y,
                 placed.window.width, placed.window.height,
                 SWP_NOZORDER | SWP_NOACTIVATE);

  if (!BuildGpuStack(hwnd, placed.window.width, placed.window.height)) {
    clingfy::bridge::devices::LogDeviceProbe(
        "CameraDcompOverlay: GPU stack build failed");
    // Release the partially-built stack HERE, on the creating thread — leaving
    // it in members would hand the release to whichever thread destroys the
    // presenter (and a retried Start would stomp live ComPtrs).
    ReleaseGpuStack();
    ::DestroyWindow(hwnd);
    ready->set_value(false);
    return;
  }
  prepared_window_side_ = placed.window.width;
  prepared_content_side_ = placed.content_side;
  prepared_padding_px_ = placed.padding_px;
  last_synced_scale_ = scale;  // seed so the first tick doesn't re-sync

  ApplyCaptureExclusion(hwnd);

  {
    char b[176];
    std::snprintf(b, sizeof(b),
                  "CameraDcompOverlay: window created at (%d,%d) side=%d "
                  "(content=%d pad=%d) dpi=%u wdaExcluded=%d",
                  placed.window.x, placed.window.y, placed.window.width,
                  placed.content_side, placed.padding_px, dpi,
                  wda_excluded_.load() ? 1 : 0);
    clingfy::bridge::devices::LogDeviceProbe(b);
  }

  // Renderer P4d default-flip guard: prove this adapter actually rasterizes
  // into the composition swapchain before the presenter goes live. A "renders
  // nothing" verdict tears the DComp stack down and reports failure — the
  // factory ladder then falls back to the safe-mode GDI bubble, so the flip is
  // safe even on hardware the cross-vendor matrix never covered.
  if (!RenderSelfCheckPasses()) {
    ReleaseGpuStack();
    ::DestroyWindow(hwnd);
    ready->set_value(false);
    return;
  }

  hwnd_.store(hwnd);
  simulated_device_losses_remaining_ = options_.simulate_device_loss_count;
  ::SetTimer(hwnd, kTickTimerId, kTickIntervalMs, nullptr);
  running_.store(true);
  ready->set_value(true);  // created HIDDEN — engine Show()s on demand.

  MSG msg{};
  while (::GetMessageW(&msg, nullptr, 0, 0) > 0) {
    ::TranslateMessage(&msg);
    ::DispatchMessageW(&msg);
  }

  running_.store(false);
  hwnd_.store(nullptr);
  ::KillTimer(hwnd, kTickTimerId);
  // Release the GPU stack on the thread that created it, then the window.
  ReleaseGpuStack();
  ::DestroyWindow(hwnd);
}

double CameraDcompOverlay::CurrentScale(HWND hwnd) const {
  const double override_scale = test_dpi_scale_.load();
  if (override_scale > 0.0) {
    return override_scale;
  }
  const UINT dpi = ::GetDpiForWindow(hwnd);
  return dpi > 0 ? dpi / 96.0 : 1.0;
}

void CameraDcompOverlay::ApplyCaptureExclusion(HWND hwnd) {
  if (!options_.apply_capture_exclusion) {
    return;
  }
  const BOOL excluded = ::SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);
  wda_excluded_.store(excluded != 0);
  if (excluded == 0) {
    // Documented Win11 defect (ChangeWindowTreeProtection) hits exactly this
    // call, disproportionately on DComp windows — the factory reacts by
    // falling back to the GDI presenter.
    char b[96];
    std::snprintf(b, sizeof(b),
                  "CameraDcompOverlay: WDA_EXCLUDEFROMCAPTURE FAILED (gle=%lu)",
                  ::GetLastError());
    clingfy::bridge::devices::LogDeviceProbe(b);
  }
}

bool CameraDcompOverlay::RenderSelfCheckPasses() {
  // Test hook (P4d): force the "adapter rasterized nothing" verdict so the
  // factory ladder's GDI fallback is exercised without the hybrid-GPU scar —
  // the parity of CLINGFY_TEST_DCOMP_WDA_FAIL for the render path.
  if (options_.simulate_render_nothing) {
    clingfy::bridge::devices::LogDeviceProbe(
        "CameraDcompOverlay: render self-check SIMULATED empty (test hook)");
    return false;
  }
  if (d2d_ctx_ == nullptr || swapchain_ == nullptr || d3d_device_ == nullptr ||
      target_bitmap_ == nullptr) {
    return false;
  }

  // Rasterize a KNOWN opaque probe over the whole target. A FillRectangle (not
  // just Clear) exercises the same rasterizer the painter uses; opaque white so
  // a black / empty read-back is unambiguous.
  const D2D1_SIZE_F size = d2d_ctx_->GetSize();
  d2d_ctx_->BeginDraw();
  d2d_ctx_->Clear(D2D1::ColorF(0.0f, 0.0f, 0.0f, 0.0f));
  ComPtr<ID2D1SolidColorBrush> brush;
  if (SUCCEEDED(d2d_ctx_->CreateSolidColorBrush(
          D2D1::ColorF(1.0f, 1.0f, 1.0f, 1.0f), brush.GetAddressOf()))) {
    d2d_ctx_->FillRectangle(D2D1::RectF(0.0f, 0.0f, size.width, size.height),
                            brush.Get());
  }
  HRESULT hr = d2d_ctx_->EndDraw();
  if (FAILED(hr)) {
    char b[96];
    std::snprintf(b, sizeof(b),
                  "CameraDcompOverlay: render self-check EndDraw failed "
                  "hr=0x%08lX",
                  static_cast<unsigned long>(hr));
    clingfy::bridge::devices::LogDeviceProbe(b);
    return false;
  }

  // Read the drawn pixels back off the swapchain back buffer through a
  // CPU-readable staging copy. This is a direct D3D resource copy, NOT a screen
  // capture, so the capture exclusion applied just before does not blind it —
  // which is exactly why this check is shippable in production (the on-screen
  // magenta probe needs the exclusion OFF, so it can only ever be a dev-box
  // canary). EndDraw flushed the D2D work, so the immediate-context copy is
  // ordered after it.
  ComPtr<ID3D11Texture2D> back;
  if (FAILED(swapchain_->GetBuffer(0, IID_PPV_ARGS(back.GetAddressOf())))) {
    return false;
  }
  D3D11_TEXTURE2D_DESC desc{};
  back->GetDesc(&desc);
  desc.Usage = D3D11_USAGE_STAGING;
  desc.BindFlags = 0;
  desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  desc.MiscFlags = 0;
  ComPtr<ID3D11Texture2D> staging;
  if (FAILED(d3d_device_->CreateTexture2D(&desc, nullptr,
                                          staging.GetAddressOf()))) {
    return false;
  }
  ComPtr<ID3D11DeviceContext> ctx;
  d3d_device_->GetImmediateContext(ctx.GetAddressOf());
  ctx->CopyResource(staging.Get(), back.Get());
  D3D11_MAPPED_SUBRESOURCE mapped{};
  if (FAILED(ctx->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped))) {
    return false;
  }
  // Count non-zero pixels across a coarse grid: after an opaque-white full fill
  // a working adapter reads back ~100% non-zero; the "renders nothing" scar
  // reads back ~0%. A simple majority threshold is robust to a stray sample
  // either way.
  int sampled = 0;
  int non_empty = 0;
  const auto* base_pixels = static_cast<const std::uint8_t*>(mapped.pData);
  for (UINT y = 0; y < desc.Height; y += 16) {
    const std::uint8_t* row =
        base_pixels + static_cast<size_t>(y) * mapped.RowPitch;
    for (UINT x = 0; x < desc.Width; x += 16) {
      const std::uint8_t* px = row + static_cast<size_t>(x) * 4;
      ++sampled;
      if (px[0] != 0 || px[1] != 0 || px[2] != 0 || px[3] != 0) {
        ++non_empty;
      }
    }
  }
  ctx->Unmap(staging.Get(), 0);
  const bool passed = sampled > 0 && non_empty * 2 > sampled;

  // Leave a clean, DEFINED transparent front buffer: the moment the engine
  // Show()s the (still-hidden) window there must be no probe fill or undefined
  // garbage to composite before the first camera frame arrives. This also
  // proves the Present path drives the swapchain on this adapter — a present
  // failure here is itself a "cannot render" signal.
  d2d_ctx_->BeginDraw();
  d2d_ctx_->Clear(D2D1::ColorF(0.0f, 0.0f, 0.0f, 0.0f));
  bool present_ok = SUCCEEDED(d2d_ctx_->EndDraw());
  if (present_ok) {
    present_ok = SUCCEEDED(swapchain_->Present(0, 0));
  }

  if (!passed || !present_ok) {
    char b[152];
    std::snprintf(b, sizeof(b),
                  "CameraDcompOverlay: render self-check FAILED "
                  "(non_empty=%d/%d present_ok=%d) — adapter renders nothing, "
                  "falling back to GDI",
                  non_empty, sampled, present_ok ? 1 : 0);
    clingfy::bridge::devices::LogDeviceProbe(b);
    return false;
  }
  char b[112];
  std::snprintf(b, sizeof(b),
                "CameraDcompOverlay: render self-check PASSED (non_empty=%d/%d)",
                non_empty, sampled);
  clingfy::bridge::devices::LogDeviceProbe(b);
  return true;
}

void CameraDcompOverlay::ReleaseRenderResources() {
  painter_ = CameraBubblePainter();
  painter_ready_ = false;
  glow_bitmap_.Reset();
  glow_active_ = false;
  glow_bake_failed_ = false;
  camera_bitmap_.Reset();
  target_bitmap_.Reset();
  if (d2d_ctx_ != nullptr) {
    d2d_ctx_->SetTarget(nullptr);
  }
  d2d_ctx_.Reset();
  d2d_device_.Reset();
  d2d_factory_.Reset();
  swapchain_.Reset();
  d3d_device_.Reset();
  gpu_ready_.store(false);
}

bool CameraDcompOverlay::RebuildGpuStack(HWND hwnd) {
  // Device-lost recovery: rebuild ONLY the D3D-bound render resources and
  // re-point the RETAINED DComp visual at the fresh swapchain. Recreating the
  // DComp target instead (CreateTargetForHwnd) is unreliable — a target is
  // keyed to the HWND and the old one may still be composed when the new call
  // runs, so it intermittently fails. WDA affinity is a window property and
  // survives untouched, so it is not re-applied here.
  ReleaseRenderResources();
  if (!BuildRenderResources(prepared_window_side_, prepared_window_side_)) {
    return false;
  }
  if (dcomp_visual_ == nullptr || dcomp_device_ == nullptr ||
      FAILED(dcomp_visual_->SetContent(swapchain_.Get())) ||
      FAILED(dcomp_device_->Commit())) {
    return false;
  }
  gpu_ready_.store(true);
  // A rebuilt stack has no painter, no glow, and a null camera bitmap. Force
  // the next tick to re-Prepare (both revisions look new) and re-upload the
  // last frame (mark the mailbox dirty; prepared_cam_* cleared so the bitmap
  // is recreated at the current dims).
  painter_ready_ = false;
  prepared_cam_w_ = 0;
  prepared_cam_h_ = 0;
  last_style_revision_ = ~0ull;
  last_geometry_revision_ = ~0ull;
  render_failed_logged_ = false;
  first_present_logged_ = false;
  {
    std::lock_guard<std::mutex> lock(frame_mutex_);
    dirty_ = frame_w_ > 0 && frame_h_ > 0;
  }
  return true;
}

void CameraDcompOverlay::ReleaseGpuStack() {
  painter_ = CameraBubblePainter();
  painter_ready_ = false;
  glow_bitmap_.Reset();
  glow_active_ = false;
  glow_bake_failed_ = false;
  camera_bitmap_.Reset();
  target_bitmap_.Reset();
  if (d2d_ctx_ != nullptr) {
    d2d_ctx_->SetTarget(nullptr);
  }
  dcomp_visual_.Reset();
  dcomp_target_.Reset();
  dcomp_device_.Reset();
  d2d_ctx_.Reset();
  d2d_device_.Reset();
  d2d_factory_.Reset();
  swapchain_.Reset();
  d3d_device_.Reset();
  gpu_ready_.store(false);
}

bool CameraDcompOverlay::BuildRenderResources(int width, int height) {
  // D3D11 device on the DEFAULT adapter (hybrid-GPU guidance: let DWM own the
  // cross-adapter hand-off), BGRA support for D2D interop. WARP fallback keeps
  // the stack alive on driver-less boxes.
  UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
  HRESULT hr = ::D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                   flags, nullptr, 0, D3D11_SDK_VERSION,
                                   d3d_device_.GetAddressOf(), nullptr,
                                   nullptr);
  if (FAILED(hr)) {
    hr = ::D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, flags,
                             nullptr, 0, D3D11_SDK_VERSION,
                             d3d_device_.GetAddressOf(), nullptr, nullptr);
  }
  if (FAILED(hr)) {
    return false;
  }

  ComPtr<IDXGIDevice> dxgi_device;
  if (FAILED(d3d_device_.As(&dxgi_device))) {
    return false;
  }
  ComPtr<IDXGIAdapter> adapter;
  if (FAILED(dxgi_device->GetAdapter(adapter.GetAddressOf()))) {
    return false;
  }
  ComPtr<IDXGIFactory2> dxgi_factory;
  if (FAILED(adapter->GetParent(IID_PPV_ARGS(dxgi_factory.GetAddressOf())))) {
    return false;
  }

  // Composition swapchain: premultiplied alpha, flip model, EXPLICIT pixel
  // sizes (no HWND to infer from) — the PowerToys MeasureTool configuration.
  DXGI_SWAP_CHAIN_DESC1 desc{};
  desc.Width = static_cast<UINT>(std::max(1, width));
  desc.Height = static_cast<UINT>(std::max(1, height));
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
  desc.BufferCount = 2;
  desc.Scaling = DXGI_SCALING_STRETCH;  // required for composition swapchains
  desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
  desc.AlphaMode = DXGI_ALPHA_MODE_PREMULTIPLIED;
  if (FAILED(dxgi_factory->CreateSwapChainForComposition(
          d3d_device_.Get(), &desc, nullptr, swapchain_.GetAddressOf()))) {
    return false;
  }

  // D2D on the same device. SINGLE_THREADED: every D2D object lives and is
  // used on this overlay thread only.
  if (FAILED(::D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,
                                 __uuidof(ID2D1Factory1), nullptr,
                                 reinterpret_cast<void**>(
                                     d2d_factory_.GetAddressOf())))) {
    return false;
  }
  if (FAILED(d2d_factory_->CreateDevice(dxgi_device.Get(),
                                        d2d_device_.GetAddressOf()))) {
    return false;
  }
  if (FAILED(d2d_device_->CreateDeviceContext(
          D2D1_DEVICE_CONTEXT_OPTIONS_NONE, d2d_ctx_.GetAddressOf()))) {
    return false;
  }
  // Pixel units: 1 DIP == 1 physical px; geometry already arrives in physical
  // pixels via ComputeSquareFloatingRect's dpi scale.
  d2d_ctx_->SetDpi(96.0f, 96.0f);

  return ResizeSwapchain(width, height);
}

bool CameraDcompOverlay::BuildGpuStack(HWND hwnd, int width, int height) {
  if (!BuildRenderResources(width, height)) {
    return false;
  }
  ComPtr<IDXGIDevice> dxgi_device;
  if (FAILED(d3d_device_.As(&dxgi_device))) {
    return false;
  }

  // DComp: device -> target(hwnd, topmost) -> visual(swapchain) -> commit.
  // Created ONCE per window and RETAINED across device-lost rebuilds — a
  // composition target is keyed to the HWND and CreateTargetForHwnd cannot run
  // twice for one window, so the rebuild re-SetContents this visual instead.
  if (FAILED(::DCompositionCreateDevice(
          dxgi_device.Get(), IID_PPV_ARGS(dcomp_device_.GetAddressOf())))) {
    return false;
  }
  if (FAILED(dcomp_device_->CreateTargetForHwnd(
          hwnd, TRUE, dcomp_target_.GetAddressOf()))) {
    return false;
  }
  if (FAILED(dcomp_device_->CreateVisual(dcomp_visual_.GetAddressOf()))) {
    return false;
  }
  if (FAILED(dcomp_visual_->SetContent(swapchain_.Get()))) {
    return false;
  }
  if (FAILED(dcomp_target_->SetRoot(dcomp_visual_.Get()))) {
    return false;
  }
  if (FAILED(dcomp_device_->Commit())) {
    return false;
  }

  gpu_ready_.store(true);
  return true;
}

bool CameraDcompOverlay::ResizeSwapchain(int width, int height) {
  if (swapchain_ == nullptr || d2d_ctx_ == nullptr) {
    return false;
  }
  // Every backbuffer reference must drop before ResizeBuffers.
  d2d_ctx_->SetTarget(nullptr);
  target_bitmap_.Reset();
  const HRESULT hr = swapchain_->ResizeBuffers(
      0, static_cast<UINT>(std::max(1, width)),
      static_cast<UINT>(std::max(1, height)), DXGI_FORMAT_UNKNOWN, 0);
  if (FAILED(hr)) {
    return false;
  }
  ComPtr<IDXGISurface> surface;
  if (FAILED(swapchain_->GetBuffer(0,
                                   IID_PPV_ARGS(surface.GetAddressOf())))) {
    return false;
  }
  const D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
      D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                        D2D1_ALPHA_MODE_PREMULTIPLIED),
      96.0f, 96.0f);
  if (FAILED(d2d_ctx_->CreateBitmapFromDxgiSurface(
          surface.Get(), props, target_bitmap_.GetAddressOf()))) {
    return false;
  }
  d2d_ctx_->SetTarget(target_bitmap_.Get());
  return true;
}

bool CameraDcompOverlay::PreparePainter(int content_side, int padding_px) {
  if (d2d_ctx_ == nullptr || d2d_factory_ == nullptr ||
      prepared_cam_w_ <= 0 || prepared_cam_h_ <= 0) {
    return false;
  }
  const ResolvedBubbleStyle resolved =
      ResolveOverlayBubbleStyle(CameraOverlayStyleStore::Instance().Snapshot());

  // Content square offset into the padded window: border/shadow/glow spill
  // into the halo instead of getting clipped at the swapchain edge (P4a).
  CameraBubbleRect bubble;
  bubble.x = static_cast<double>(padding_px);
  bubble.y = static_cast<double>(padding_px);
  bubble.width = static_cast<double>(content_side);
  bubble.height = static_cast<double>(content_side);

  // Prepare bakes the shadow via SetTarget round-trips and leaves the target
  // null — call OUTSIDE BeginDraw, then re-bind the swapchain target (the
  // preview engine's exact contract, preview_engine.cpp).
  const bool ok = painter_.Prepare(
      d2d_factory_.Get(), d2d_ctx_.Get(), bubble, resolved.shape,
      resolved.corner_radius, resolved.content_mode, resolved.style,
      static_cast<UINT>(prepared_cam_w_), static_cast<UINT>(prepared_cam_h_));
  d2d_ctx_->SetTarget(target_bitmap_.Get());
  if (!ok) {
    // Field diagnostic: a failed Prepare silently blanks the bubble, so say
    // so (once per attempt cadence — Prepare only reruns on style changes).
    char b[112];
    std::snprintf(b, sizeof(b),
                  "CameraDcompOverlay: painter Prepare FAILED (content=%d "
                  "pad=%d cam=%dx%d shape=%s)",
                  content_side, padding_px, prepared_cam_w_, prepared_cam_h_,
                  resolved.shape.c_str());
    clingfy::bridge::devices::LogDeviceProbe(b);
  }
  return ok;
}

void CameraDcompOverlay::PrepareGlow(int content_side, int padding_px) {
  if (d2d_ctx_ == nullptr || d2d_factory_ == nullptr) {
    return;
  }
  const CameraOverlayLiveStyle snap =
      CameraOverlayStyleStore::Instance().Snapshot();
  if (!snap.glow_enabled) {
    glow_bitmap_.Reset();
    glow_active_ = false;
    glow_bake_failed_ = false;
    return;
  }
  const bool was_active = glow_active_;
  const double prev_strength = glow_strength_;
  const ResolvedBubbleStyle resolved = ResolveOverlayBubbleStyle(snap);
  glow_bitmap_ = BakeCameraGlowBitmap(
      d2d_factory_.Get(), d2d_ctx_.Get(), resolved.shape,
      resolved.corner_radius, content_side, padding_px, snap.glow_strength);
  d2d_ctx_->SetTarget(target_bitmap_.Get());
  glow_active_ = glow_bitmap_ != nullptr;
  glow_strength_ = snap.glow_strength;
  const float dim = static_cast<float>(content_side + 2 * padding_px);
  glow_dest_ = D2D1::RectF(0.0f, 0.0f, dim, dim);
  if (glow_active_ &&
      (!was_active || snap.glow_strength != prev_strength)) {
    // Phase origin: the pulse (re)starts at its LOW value when the glow turns
    // on AND on every strength change — macOS re-adds the CABasicAnimation
    // from its fromValue in both cases. Recomputing the phase against a stale
    // epoch with the new strength-dependent period would teleport the opacity
    // to an arbitrary point of the waveform on every slider tick. Shape or
    // size re-bakes with the same strength keep the phase (macOS only swaps
    // the layer path there).
    glow_epoch_ = std::chrono::steady_clock::now();
  }
  // A transiently failed bake must not blank the recording ring for the whole
  // session: the style revision is already consumed by the caller, so flag a
  // per-tick retry, and say so in the field log (the painter-Prepare parity).
  glow_bake_failed_ = !glow_active_;
  if (glow_bake_failed_ && !glow_bake_failed_logged_) {
    glow_bake_failed_logged_ = true;
    char b[96];
    std::snprintf(b, sizeof(b),
                  "CameraDcompOverlay: glow bake FAILED (content=%d pad=%d "
                  "shape=%s) — retrying per tick",
                  content_side, padding_px, resolved.shape.c_str());
    clingfy::bridge::devices::LogDeviceProbe(b);
  }
}

void CameraDcompOverlay::UpdateHaloClickThrough(HWND hwnd) {
  POINT pt{};
  RECT wr{};
  if (::GetCursorPos(&pt) == 0 || ::GetWindowRect(hwnd, &wr) == 0) {
    return;
  }
  const bool over_content =
      ::PtInRect(&wr, pt) != 0 &&
      CameraOverlayPointInContent(pt.x - wr.left, pt.y - wr.top,
                                  prepared_padding_px_,
                                  prepared_content_side_);
  // Click-through whenever the cursor is NOT over the content square, so the
  // halo never intercepts input meant for the apps beneath it. Only the
  // TRANSPARENT bit flips, and only on boundary crossings.
  const bool want_transparent = !over_content;
  if (want_transparent == click_through_) {
    return;
  }
  const LONG_PTR ex = ::GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
  ::SetWindowLongPtrW(hwnd, GWL_EXSTYLE,
                      want_transparent ? (ex | WS_EX_TRANSPARENT)
                                       : (ex & ~WS_EX_TRANSPARENT));
  click_through_ = want_transparent;

  // Electron #47834 lesson: window mutations can silently drop the capture
  // exclusion on some builds. Re-verify after every flip; if it cannot be
  // restored, hide — an unexcluded bubble must never stay on screen.
  ReverifyCaptureExclusion(hwnd, "click-through flip");
}

bool CameraDcompOverlay::ReverifyCaptureExclusion(HWND hwnd,
                                                  const char* where) {
  // A session that never got exclusion, or already lost it, is not re-probed:
  // wda_excluded_ is a ONE-WAY latch and the kMsgShow gate already refuses
  // every Show once it is false. Re-probing could only widen the blast radius
  // of a spurious failure.
  if (!options_.apply_capture_exclusion || !wda_excluded_.load()) {
    return true;
  }
  DWORD affinity = 0;
  if (::GetWindowDisplayAffinity(hwnd, &affinity) != 0 &&
      affinity == WDA_EXCLUDEFROMCAPTURE) {
    return true;
  }
  if (::SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE) != 0) {
    return true;  // restored
  }
  wda_excluded_.store(false);
  ::ShowWindow(hwnd, SW_HIDE);
  char b[160];
  std::snprintf(b, sizeof(b),
                "CameraDcompOverlay: WDA lost after %s and could not be "
                "restored — bubble hidden",
                where);
  clingfy::bridge::devices::LogDeviceProbe(b);
  // WARN as well as probe. This is a mid-recording degradation on a machine
  // where exclusion SUCCEEDED at start, and the bubble vanishes from the user's
  // screen — but the probe log sits behind the verbose diagnostics toggle, so
  // it was the only camera degradation path with NO release-visible line at
  // all. Support could not see it in logs or Sentry.
  clingfy::bridge::NativeLogPublisher::Instance().Warn("Camera", b);
  return false;
}

void CameraDcompOverlay::SyncAndRender(HWND hwnd) {
  if (!gpu_ready_.load()) {
    // The stack is down after a device loss; keep retrying the rebuild here
    // (the draw path can't, it never runs without gpu_ready_) until it
    // succeeds or the budget is spent and the fallback hook fires.
    if (device_loss_retry_pending_ && !device_loss_gave_up_.load()) {
      AttemptDeviceLossRecovery(hwnd, "retry");
    }
    return;
  }
  UpdateHaloClickThrough(hwnd);
  auto& geometry_store = CameraOverlayGeometryStore::Instance();
  auto& style_store = CameraOverlayStyleStore::Instance();

  bool needs_prepare = false;
  bool needs_draw = false;

  // Geometry AND style drive the padded window rect (P4a: effect padding
  // follows border/shadow/glow), so either revision re-syncs sizing and any
  // style change also re-Prepares the painter (loop-invariant resources).
  // Deferred while the user holds an OS modal drag — SetWindowPos would yank
  // the window out of their grab; the unconsumed revisions apply on drop.
  const std::uint64_t grev = geometry_store.revision();
  const std::uint64_t srev = style_store.revision();
  const double scale = CurrentScale(hwnd);
  const bool geometry_changed = grev != last_geometry_revision_;
  const bool style_changed = srev != last_style_revision_;
  // DPI self-detection (P4c): a monitor scale change — a Settings scale change
  // mid-recording, or a move to a different-DPI monitor that didn't come
  // through the store — bumps no revision, so the tick watches the scale
  // directly (GetDpiForWindow reflects the current monitor). Covers every
  // DPI-change cause without depending on WM_DPICHANGED delivery, which the OS
  // gates on per-monitor awareness.
  const bool dpi_changed = scale != last_synced_scale_;
  if (!in_size_move_ && (geometry_changed || style_changed || dpi_changed)) {
    const RECT work = MonitorWorkArea(hwnd);
    const PaddedSquareRect placed = ComputePaddedSquareFloatingRect(
        work.left, work.top, work.right, work.bottom, scale,
        geometry_store.Snapshot(),
        ComputeCameraEffectPadding(style_store.Snapshot()));
    // Re-place only when placement inputs actually moved: geometry changes
    // (pre-P4a semantics) or a padding change (window must grow/shrink). A
    // style-only revision with unchanged padding — opacity, mirror, colors —
    // must NOT re-derive the position: the store's clamped placement would
    // teleport a bubble the user dropped partially past the work-area edge.
    const bool padding_changed = placed.padding_px != prepared_padding_px_;
    if (geometry_changed || padding_changed || dpi_changed ||
        target_bitmap_ == nullptr) {
      ::SetWindowPos(hwnd, nullptr, placed.window.x, placed.window.y,
                     placed.window.width, placed.window.height,
                     SWP_NOZORDER | SWP_NOACTIVATE);
      // Keep the hit-test split consistent with the rect just applied even if
      // the resize below fails and this tick bails out.
      prepared_content_side_ = placed.content_side;
      prepared_padding_px_ = placed.padding_px;
      // AFTER the prepared_* writes, not before: the unrepairable branch calls
      // ShowWindow(SW_HIDE), which synchronously re-enters this WndProc, and
      // the comment above exists precisely so those fields are never stale
      // relative to the rect just applied.
      //
      // Cost: this is NOT per tick. The two enclosing gates mean an idle bubble
      // reaches it zero times; it fires on a store revision or a DPI change,
      // i.e. one thin win32k syscall per actual placement change.
      ReverifyCaptureExclusion(hwnd, "placement sync");
    }
    // Also retry when a previous failed resize left the context target-less:
    // a side-REVERTING revision (style toggled back off; the glow flip at
    // recording stop) reproduces the old side exactly, and skipping here
    // would consume it with a null target — freezing the bubble for good.
    if (placed.window.width != prepared_window_side_ ||
        target_bitmap_ == nullptr) {
      if (!ResizeSwapchain(placed.window.width, placed.window.height)) {
        // Leave BOTH revisions UNCONSUMED so the next tick retries: consuming
        // here would strand a target-less context (ResizeSwapchain already
        // dropped the D2D target) burning a dead BeginDraw/EndDraw every tick
        // until the user happens to change geometry or style again.
        return;
      }
      prepared_window_side_ = placed.window.width;
      needs_prepare = true;
    }
    prepared_content_side_ = placed.content_side;
    prepared_padding_px_ = placed.padding_px;
    if (style_changed || dpi_changed) {
      // A scale change resizes the content square, so the painter's cover rect
      // and baked shadow/glow must be re-Prepared at the new dimensions.
      needs_prepare = true;
    }
    last_geometry_revision_ = grev;
    last_style_revision_ = srev;
    last_synced_scale_ = scale;
    needs_draw = true;
  }

  // Frame: copy the mailbox out; (re)create the camera bitmap on dim change.
  std::vector<std::uint8_t> frame;
  int fw = 0;
  int fh = 0;
  {
    std::lock_guard<std::mutex> lock(frame_mutex_);
    if (dirty_ && frame_w_ > 0 && frame_h_ > 0 &&
        frame_bgra_.size() >=
            static_cast<size_t>(frame_w_) * frame_h_ * 4) {
      frame = frame_bgra_;
      fw = frame_w_;
      fh = frame_h_;
      dirty_ = false;
      needs_draw = true;
    }
  }
  if (fw > 0 && fh > 0) {
    if (fw != prepared_cam_w_ || fh != prepared_cam_h_ ||
        camera_bitmap_ == nullptr) {
      camera_bitmap_.Reset();
      const D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
          D2D1_BITMAP_OPTIONS_NONE,
          D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                            D2D1_ALPHA_MODE_IGNORE));
      if (FAILED(d2d_ctx_->CreateBitmap(
              D2D1::SizeU(static_cast<UINT32>(fw), static_cast<UINT32>(fh)),
              nullptr, 0, props, camera_bitmap_.GetAddressOf()))) {
        return;
      }
      prepared_cam_w_ = fw;
      prepared_cam_h_ = fh;
      needs_prepare = true;  // cover/contain rect depends on the camera dims.
    }
    if (FAILED(camera_bitmap_->CopyFromMemory(
            nullptr, frame.data(), static_cast<UINT32>(fw) * 4u))) {
      return;
    }
  }

  if (needs_prepare && prepared_cam_w_ > 0) {
    painter_ready_ =
        PreparePainter(prepared_content_side_, prepared_padding_px_);
    PrepareGlow(prepared_content_side_, prepared_padding_px_);
  } else if (glow_bake_failed_ && prepared_cam_w_ > 0) {
    // The revision that enabled the glow is consumed; keep retrying the bake
    // until it succeeds (or the glow is disabled) so a transient GPU hiccup
    // cannot blank the recording ring for the whole session.
    PrepareGlow(prepared_content_side_, prepared_padding_px_);
  }
  // An active glow pulses: redraw every tick while visible so the animation
  // runs even when camera frames stall (macOS CAAnimation parity).
  if (glow_active_ && ::IsWindowVisible(hwnd)) {
    needs_draw = true;
  }
  if (!needs_draw || !painter_ready_ || camera_bitmap_ == nullptr) {
    return;
  }

  d2d_ctx_->BeginDraw();
  d2d_ctx_->Clear(D2D1::ColorF(0.0f, 0.0f, 0.0f, 0.0f));
  // Identity Frame: byte-identical static path unless chroma is enabled (then
  // the painter routes through its keyed path) — full style for free.
  painter_.Draw(d2d_ctx_.Get(), camera_bitmap_.Get(),
                CameraBubblePainter::Frame{});
  if (glow_active_ && glow_bitmap_ != nullptr) {
    const double elapsed =
        std::chrono::duration<double>(std::chrono::steady_clock::now() -
                                      glow_epoch_)
            .count();
    d2d_ctx_->DrawBitmap(
        glow_bitmap_.Get(), glow_dest_,
        static_cast<float>(CameraGlowPulseOpacity(glow_strength_, elapsed)),
        D2D1_BITMAP_INTERPOLATION_MODE_LINEAR, nullptr);
  }
  HRESULT hr = d2d_ctx_->EndDraw();
  // Test fault injection (P4c): pretend this frame hit device loss so the
  // rebuild path is exercised without real GPU removal.
  if (SUCCEEDED(hr) && simulated_device_losses_remaining_ > 0) {
    --simulated_device_losses_remaining_;
    hr = DXGI_ERROR_DEVICE_REMOVED;
  } else if (SUCCEEDED(hr) && simulate_one_loss_.exchange(false)) {
    hr = DXGI_ERROR_DEVICE_REMOVED;
  }
  if (FAILED(hr)) {
    if (IsDeviceLostHResult(hr)) {
      AttemptDeviceLossRecovery(hwnd, "EndDraw");
    } else if (!render_failed_logged_) {
      render_failed_logged_ = true;
      char b[96];
      std::snprintf(b, sizeof(b),
                    "CameraDcompOverlay: EndDraw failed hr=0x%08lX (not device "
                    "loss — no rebuild)",
                    static_cast<unsigned long>(hr));
      clingfy::bridge::devices::LogDeviceProbe(b);
    }
    return;
  }
  const HRESULT present_hr = swapchain_->Present(0, 0);
  if (FAILED(present_hr)) {
    if (IsDeviceLostHResult(present_hr)) {
      AttemptDeviceLossRecovery(hwnd, "Present");
    }
    return;
  }
  // A clean present clears the device-loss streak — an isolated TDR recovered.
  consecutive_device_losses_ = 0;
  if (!first_present_logged_) {
    first_present_logged_ = true;
    char b[112];
    std::snprintf(b, sizeof(b),
                  "CameraDcompOverlay: first present hr=0x%08lX side=%d "
                  "cam=%dx%d",
                  static_cast<unsigned long>(present_hr), prepared_window_side_,
                  prepared_cam_w_, prepared_cam_h_);
    clingfy::bridge::devices::LogDeviceProbe(b);
  }
}

void CameraDcompOverlay::AttemptDeviceLossRecovery(HWND hwnd,
                                                   const char* where) {
  device_loss_retry_pending_ = false;
  ++consecutive_device_losses_;
  ++total_device_losses_;
  {
    char b[144];
    std::snprintf(b, sizeof(b),
                  "CameraDcompOverlay: device loss at %s (attempt=%d) — "
                  "rebuilding GPU stack",
                  where, consecutive_device_losses_);
    clingfy::bridge::devices::LogDeviceProbe(b);
  }
  if (consecutive_device_losses_ > kMaxConsecutiveDeviceLosses) {
    // The adapter is wedged, not recovering from an isolated TDR. Stop
    // rebuilding and PARK: drop the render stack so no tick draws against it,
    // keeping the thread alive for the mid-session GDI fallback (P4c-c3).
    device_loss_gave_up_.store(true);
    ReleaseRenderResources();  // sets gpu_ready_ false
    if (!device_loss_fallback_logged_) {
      device_loss_fallback_logged_ = true;
      clingfy::bridge::devices::LogDeviceProbe(
          "CameraDcompOverlay: device loss persists past the rebuild budget — "
          "mid-session GDI fallback lands in P4c-c3");
    }
    return;
  }
  if (RebuildGpuStack(hwnd)) {
    return;  // gpu_ready_ is true again; the next tick draws a fresh frame.
  }
  // The rebuild itself failed (gpu_ready_ false via ReleaseGpuStack). Arm a
  // retry: the tick top re-enters this path next WM_TIMER until it succeeds or
  // the budget is spent.
  device_loss_retry_pending_ = true;
  clingfy::bridge::devices::LogDeviceProbe(
      "CameraDcompOverlay: GPU stack rebuild FAILED after device loss — "
      "retrying next tick");
}

void CameraDcompOverlay::Show() {
  HWND hwnd = hwnd_.load();
  if (hwnd != nullptr) {
    ::PostMessageW(hwnd, kMsgShow, 0, 0);
  }
}

void CameraDcompOverlay::Hide() {
  HWND hwnd = hwnd_.load();
  if (hwnd != nullptr) {
    ::PostMessageW(hwnd, kMsgHide, 0, 0);
  }
}

void CameraDcompOverlay::PublishBgra(const std::uint8_t* bgra, int width,
                                     int height) {
  if (!running_.load() || bgra == nullptr || width <= 0 || height <= 0) {
    return;
  }
  std::lock_guard<std::mutex> lock(frame_mutex_);
  const size_t bytes = static_cast<size_t>(width) * height * 4;
  frame_bgra_.assign(bgra, bgra + bytes);
  frame_w_ = width;
  frame_h_ = height;
  dirty_ = true;
}

void CameraDcompOverlay::OnDragEnded(HWND hwnd) {
  // Adopt the write-back revision as seen only when it directly follows the
  // last-synced one (see AdoptDragRevision) — unconditional adoption could
  // skip a platform-thread mutation that landed since the last sync tick.
  // Revision 0 = rect read failed, nothing written, nothing to suppress.
  const std::uint64_t revision = WriteBackOverlayDragEnd(hwnd);
  if (revision != 0) {
    last_geometry_revision_ =
        AdoptDragRevision(last_geometry_revision_, revision);
  }
  // A drag is the LARGEST window mutation this overlay undergoes, and the one
  // the user actually triggers: WM_NCHITTEST returns HTCAPTION, so
  // DefWindowProc runs a real SC_MOVE modal loop that moves the HWND
  // continuously. It is also invisible to the placement-sync re-verify — the
  // outer gate skips the whole block while in_size_move_, and AdoptDragRevision
  // above marks the drag's own revision as already-seen, so the next tick's
  // geometry_changed is false and SetWindowPos never runs. Re-verify here,
  // once per drop, or every same-monitor drag goes unchecked.
  //
  // After the write-back, so the user's drop is persisted even if the bubble is
  // then hidden.
  ReverifyCaptureExclusion(hwnd, "drag end");
}

void CameraDcompOverlay::Stop() {
  if (thread_.joinable()) {
    if (thread_id_ != 0) {
      ::PostThreadMessageW(thread_id_, WM_QUIT, 0, 0);
    }
    thread_.join();
  }
  running_.store(false);
  hwnd_.store(nullptr);
  thread_id_ = 0;
}

}  // namespace clingfy::capture
