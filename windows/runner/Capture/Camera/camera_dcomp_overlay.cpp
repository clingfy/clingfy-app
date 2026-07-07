#include "Capture/Camera/camera_dcomp_overlay.h"

#include <d2d1helper.h>

#include <algorithm>
#include <cstdio>
#include <utility>

#include "Bridge/Devices/device_probe_log.h"
#include "Capture/Camera/camera_overlay_drag.h"
#include "Capture/Camera/camera_overlay_geometry_store.h"
#include "Capture/Camera/camera_overlay_style_store.h"

namespace clingfy::capture {

namespace {

using Microsoft::WRL::ComPtr;

constexpr wchar_t kWindowClassName[] = L"ClingfyCameraDcompOverlay";
constexpr UINT_PTR kTickTimerId = 1;
constexpr UINT kTickIntervalMs = 33;  // ~30 fps sync/redraw.
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
    case WM_NCHITTEST:
      // Whole bubble drags (P4 adds the click-through halo once effect
      // padding exists).
      return HTCAPTION;
    case WM_EXITSIZEMOVE:
      if (self != nullptr) {
        self->OnDragEnded(hwnd);
      }
      return 0;
    case kMsgShow:
      ::ShowWindow(hwnd, SW_SHOWNA);
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
  HWND hwnd = ::CreateWindowExW(
      WS_EX_NOREDIRECTIONBITMAP | WS_EX_TOPMOST | WS_EX_TOOLWINDOW |
          WS_EX_NOACTIVATE,
      kWindowClassName, L"Clingfy Camera", WS_POPUP, placement.x, placement.y,
      std::max(1, placement.width), std::max(1, placement.height), nullptr,
      nullptr, ::GetModuleHandleW(nullptr), this);
  if (hwnd == nullptr) {
    ready->set_value(false);
    return;
  }

  // Square placement per the store, while still hidden.
  const RECT work = MonitorWorkArea(hwnd);
  const UINT dpi = ::GetDpiForWindow(hwnd);
  const double scale = dpi > 0 ? dpi / 96.0 : 1.0;
  auto& geometry_store = CameraOverlayGeometryStore::Instance();
  last_geometry_revision_ = geometry_store.revision();
  const FloatingRect rect =
      ComputeSquareFloatingRect(work.left, work.top, work.right, work.bottom,
                                scale, geometry_store.Snapshot());
  ::SetWindowPos(hwnd, nullptr, rect.x, rect.y, rect.width, rect.height,
                 SWP_NOZORDER | SWP_NOACTIVATE);

  if (!BuildGpuStack(hwnd, rect.width, rect.height)) {
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
  prepared_side_ = rect.width;

  if (options_.apply_capture_exclusion) {
    const BOOL excluded =
        ::SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);
    wda_excluded_.store(excluded != 0);
    if (excluded == 0) {
      // Documented Win11 defect (ChangeWindowTreeProtection) hits exactly
      // this call, disproportionately on DComp windows — the factory reacts
      // by falling back to the GDI presenter.
      char b[96];
      std::snprintf(b, sizeof(b),
                    "CameraDcompOverlay: WDA_EXCLUDEFROMCAPTURE FAILED "
                    "(gle=%lu)",
                    ::GetLastError());
      clingfy::bridge::devices::LogDeviceProbe(b);
    }
  }

  {
    char b[160];
    std::snprintf(b, sizeof(b),
                  "CameraDcompOverlay: window created at (%d,%d) side=%d "
                  "dpi=%u wdaExcluded=%d",
                  rect.x, rect.y, rect.width, dpi,
                  wda_excluded_.load() ? 1 : 0);
    clingfy::bridge::devices::LogDeviceProbe(b);
  }

  hwnd_.store(hwnd);
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

void CameraDcompOverlay::ReleaseGpuStack() {
  painter_ = CameraBubblePainter();
  painter_ready_ = false;
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

bool CameraDcompOverlay::BuildGpuStack(HWND hwnd, int width, int height) {
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

  if (!ResizeSwapchain(width, height)) {
    return false;
  }

  // DComp: device -> target(hwnd, topmost) -> visual(swapchain) -> commit.
  // Committed ONCE — per-frame updates are swapchain Presents, not visual-tree
  // changes.
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

bool CameraDcompOverlay::PreparePainter(int side) {
  if (d2d_ctx_ == nullptr || d2d_factory_ == nullptr ||
      prepared_cam_w_ <= 0 || prepared_cam_h_ <= 0) {
    return false;
  }
  const ResolvedBubbleStyle resolved =
      ResolveOverlayBubbleStyle(CameraOverlayStyleStore::Instance().Snapshot());

  CameraBubbleRect bubble;
  bubble.x = 0.0;
  bubble.y = 0.0;
  bubble.width = static_cast<double>(side);
  bubble.height = static_cast<double>(side);

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
    char b[96];
    std::snprintf(b, sizeof(b),
                  "CameraDcompOverlay: painter Prepare FAILED (side=%d cam=%dx%d "
                  "shape=%s)",
                  side, prepared_cam_w_, prepared_cam_h_,
                  resolved.shape.c_str());
    clingfy::bridge::devices::LogDeviceProbe(b);
  }
  return ok;
}

void CameraDcompOverlay::SyncAndRender(HWND hwnd) {
  if (!gpu_ready_.load()) {
    return;
  }
  auto& geometry_store = CameraOverlayGeometryStore::Instance();
  auto& style_store = CameraOverlayStyleStore::Instance();

  bool needs_prepare = false;
  bool needs_draw = false;

  // Geometry: move/resize the SQUARE window, resize the swapchain with it.
  if (const std::uint64_t rev = geometry_store.revision();
      rev != last_geometry_revision_) {
    const RECT work = MonitorWorkArea(hwnd);
    const UINT dpi = ::GetDpiForWindow(hwnd);
    const double scale = dpi > 0 ? dpi / 96.0 : 1.0;
    const FloatingRect rect =
        ComputeSquareFloatingRect(work.left, work.top, work.right, work.bottom,
                                  scale, geometry_store.Snapshot());
    ::SetWindowPos(hwnd, nullptr, rect.x, rect.y, rect.width, rect.height,
                   SWP_NOZORDER | SWP_NOACTIVATE);
    if (rect.width != prepared_side_) {
      if (!ResizeSwapchain(rect.width, rect.height)) {
        // Leave the revision UNCONSUMED so the next tick retries: consuming it
        // here would strand a target-less context (ResizeSwapchain already
        // dropped the D2D target) burning a dead BeginDraw/EndDraw every tick
        // until the user happens to change geometry again.
        return;
      }
      prepared_side_ = rect.width;
      needs_prepare = true;
    }
    last_geometry_revision_ = rev;
    needs_draw = true;
  }

  // Style: any change re-Prepares the painter (loop-invariant resources).
  if (const std::uint64_t rev = style_store.revision();
      rev != last_style_revision_) {
    last_style_revision_ = rev;
    needs_prepare = true;
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
    painter_ready_ = PreparePainter(prepared_side_);
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
  const HRESULT hr = d2d_ctx_->EndDraw();
  if (FAILED(hr)) {
    if (!render_failed_logged_) {
      render_failed_logged_ = true;
      char b[96];
      std::snprintf(b, sizeof(b),
                    "CameraDcompOverlay: EndDraw failed hr=0x%08lX "
                    "(device-lost rebuild lands in P4)",
                    static_cast<unsigned long>(hr));
      clingfy::bridge::devices::LogDeviceProbe(b);
    }
    return;
  }
  const HRESULT present_hr = swapchain_->Present(0, 0);
  if (!first_present_logged_) {
    first_present_logged_ = true;
    char b[112];
    std::snprintf(b, sizeof(b),
                  "CameraDcompOverlay: first present hr=0x%08lX side=%d "
                  "cam=%dx%d",
                  static_cast<unsigned long>(present_hr), prepared_side_,
                  prepared_cam_w_, prepared_cam_h_);
    clingfy::bridge::devices::LogDeviceProbe(b);
  }
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
