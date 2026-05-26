#include "preview/preview_engine.h"

#include <windows.h>
#include <winternl.h>
#include <inspectable.h>
#include <d2d1_1.h>
#include <d3d11.h>
#include <d3d11_4.h>
#include <dxgi1_2.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <wrl/client.h>

#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <winrt/Windows.Media.Core.h>
#include <winrt/Windows.Media.Playback.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <ctime>
#include <fstream>
#include <limits>

#include "preview/frame_timing.h"
#include "preview/preview_compositor.h"

namespace clingfy::preview {

using Microsoft::WRL::ComPtr;

namespace winrt_foundation = winrt::Windows::Foundation;
namespace winrt_dxd3d = winrt::Windows::Graphics::DirectX::Direct3D11;
namespace winrt_media = winrt::Windows::Media::Core;
namespace winrt_playback = winrt::Windows::Media::Playback;

namespace {

// Shared texture size (what Flutter sees through the Texture widget).
// Video frames are letterboxed into this canvas by the compositor, so
// arbitrary source resolutions work without resizing the shared handle.
// 720p is plenty of headroom for the design-doc verdict bar and keeps
// the shared allocation small enough that Intel iGPU drivers behave.
// Step 5.3 of the Phase 5 plan replaces this fixed size with a
// Flutter-widget-sized surface.
constexpr int kTextureWidth = 1280;
constexpr int kTextureHeight = 720;
constexpr wchar_t kArtifactPath[] =
    L"build\\windows-poc\\stage2a_2_result.md";
constexpr wchar_t kNativeLogPath[] =
    L"build\\windows-poc\\stage2a_2_native.log";

// Design-doc Stage-1 pass bar (the verdict line in the artifact
// compares Flutter raster + native producer median/p99 against these).
constexpr double kPassBarMedianMs = 16.0;
constexpr double kPassBarP99Ms = 25.0;

// File-based logger because a Flutter Windows debug build is a GUI
// subsystem exe with no console; the standard streams are not
// reliably reachable from outside. The log file is overwritten each
// Open(); each line carries an HRESULT-style breadcrumb so a crash
// can be localised by inspecting the last surviving line.
void LogNative(const char* msg) {
  std::ofstream f(kNativeLogPath,
                  std::ios::out | std::ios::app | std::ios::binary);
  if (f.is_open()) {
    std::time_t now = std::time(nullptr);
    std::tm tm_utc{};
#if defined(_MSC_VER)
    ::gmtime_s(&tm_utc, &now);
#else
    tm_utc = *std::gmtime(&now);
#endif
    char ts[32];
    std::snprintf(ts, sizeof(ts), "%02d:%02d:%02d ",
                  tm_utc.tm_hour, tm_utc.tm_min, tm_utc.tm_sec);
    f << ts << msg << "\n";
  }
}

D3D11_TEXTURE2D_DESC MakeSharedTextureDesc(int w, int h) {
  D3D11_TEXTURE2D_DESC d{};
  d.Width = static_cast<UINT>(w);
  d.Height = static_cast<UINT>(h);
  d.MipLevels = 1;
  d.ArraySize = 1;
  d.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  d.SampleDesc.Count = 1;
  d.Usage = D3D11_USAGE_DEFAULT;
  d.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  // Legacy SHARED handle — see the Phase 5 ADR's "Locked technical
  // choices" item 4: NT shared handles + keyed mutex crash ANGLE's
  // import path on Intel iGPU; the only form Flutter's GpuSurface
  // bridge accepts is the legacy (non-NT) form produced by
  // IDXGIResource::GetSharedHandle.
  d.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
  return d;
}

std::string UtcTimestampNow() {
  std::time_t now = std::time(nullptr);
  std::tm tm_utc{};
#if defined(_MSC_VER)
  ::gmtime_s(&tm_utc, &now);
#else
  tm_utc = *std::gmtime(&now);
#endif
  char buf[32];
  std::snprintf(buf, sizeof(buf), "%04d-%02d-%02dT%02d:%02d:%02dZ",
                tm_utc.tm_year + 1900, tm_utc.tm_mon + 1, tm_utc.tm_mday,
                tm_utc.tm_hour, tm_utc.tm_min, tm_utc.tm_sec);
  return std::string(buf);
}

std::string WindowsVersionString() {
  using RtlGetVersionFn = NTSTATUS(WINAPI*)(PRTL_OSVERSIONINFOW);
  HMODULE ntdll = ::GetModuleHandleW(L"ntdll.dll");
  if (ntdll == nullptr) return "unknown";
  auto fn = reinterpret_cast<RtlGetVersionFn>(
      ::GetProcAddress(ntdll, "RtlGetVersion"));
  if (fn == nullptr) return "unknown";
  RTL_OSVERSIONINFOW v{};
  v.dwOSVersionInfoSize = sizeof(v);
  if (fn(&v) != 0) return "unknown";
  char buf[64];
  std::snprintf(buf, sizeof(buf), "Windows %lu.%lu build %lu",
                static_cast<unsigned long>(v.dwMajorVersion),
                static_cast<unsigned long>(v.dwMinorVersion),
                static_cast<unsigned long>(v.dwBuildNumber));
  return std::string(buf);
}

std::string WideToUtf8(const std::wstring& w) {
  if (w.empty()) return {};
  const int needed = ::WideCharToMultiByte(
      CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()), nullptr, 0,
      nullptr, nullptr);
  if (needed <= 0) return {};
  std::string out(static_cast<size_t>(needed), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()),
                        out.data(), needed, nullptr, nullptr);
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

std::int64_t CurrentPlaybackUs(winrt_playback::MediaPlayer const& player) {
  try {
    const auto pos = player.PlaybackSession().Position();
    return std::chrono::duration_cast<std::chrono::microseconds>(pos)
        .count();
  } catch (winrt::hresult_error const&) {
    return -1;
  }
}

}  // namespace

// ---------------------------------------------------------------------
// Impl — owns the D3D11 device, shared texture, D2D wrappers,
// PreviewCompositor, MediaPlayer + WinRT subscription, and the native
// timing collectors. Hidden in the .cpp so the header stays free of
// D3D11 / D2D / WinRT types.
// ---------------------------------------------------------------------
struct PreviewEngine::Impl {
  // ---- D3D11 / D2D ----
  ComPtr<ID3D11Device> d3d_device;
  ComPtr<ID3D11DeviceContext> d3d_context;
  ComPtr<ID3D11Texture2D> shared_texture;
  // The shared texture wrapped as a D2D bitmap render target. The D2D
  // context's SetTarget binds to this every frame; ComposeFrame draws
  // through the D2D context onto this bitmap, which is the same memory
  // Flutter samples through its imported texture.
  ComPtr<ID2D1Bitmap1> shared_bitmap;
  ComPtr<ID2D1Factory1> d2d_factory;
  ComPtr<ID2D1Device> d2d_device;
  ComPtr<ID2D1DeviceContext> d2d_context;
  // Legacy DXGI shared handle (not an NT handle — see comment on the
  // texture desc above). Does NOT get CloseHandle'd; the texture
  // owns it and releases on COM teardown.
  HANDLE shared_handle = nullptr;

  // ---- WinRT MediaPlayer ----
  winrt_dxd3d::IDirect3DDevice winrt_device{nullptr};
  winrt_playback::MediaPlayer player{nullptr};
  winrt::event_token frame_token{};

  // ---- Compositor + cursor fixture ----
  clingfy::preview::PreviewCompositor compositor;
  std::vector<clingfy::preview::CursorEvent> cursor_events;
  clingfy::preview::ZoomState zoom;
  bool cursor_mode = false;

  // ---- Stats ----
  clingfy::preview::FrameTimingCollector timing_total;   // whole VideoFrameAvailable handler
  clingfy::preview::FrameTimingCollector timing_copy;    // CopyFrameToVideoSurface
  clingfy::preview::FrameTimingCollector timing_render;  // BeginDraw → EndDraw
  clingfy::preview::FrameTimingCollector timing_handoff; // Flush + MarkExternalTextureFrameAvailable
  std::atomic<std::uint64_t> dropped_frames{0};

  // ---- Discovered after the first frame ----
  std::atomic<UINT> last_video_width{0};
  std::atomic<UINT> last_video_height{0};
  std::atomic<std::int64_t> frames_consumed{0};

  // The descriptor handed back to Flutter every callback. Pointer
  // stability matters: Flutter holds the returned pointer until it
  // imports the handle.
  FlutterDesktopGpuSurfaceDescriptor descriptor{};

  // GPU description string for the artifact.
  std::string gpu_description;
  std::wstring video_path;
  std::wstring cursor_path;

  // Serializes the per-frame composition path against the descriptor
  // callback (which Flutter can invoke from its own thread).
  std::mutex render_mutex;
};

namespace {

// Static callback the C API hands us. user_data is `Impl*`. Returns a
// pointer to the descriptor stored on the Impl; same descriptor every
// frame because texture size never changes.
const FlutterDesktopGpuSurfaceDescriptor* ObtainSurfaceDescriptor(
    size_t /*width*/, size_t /*height*/, void* user_data) {
  auto* impl = static_cast<PreviewEngine::Impl*>(user_data);
  if (impl == nullptr) {
    LogNative("ObtainSurfaceDescriptor: impl is null");
    return nullptr;
  }
  if (impl->shared_handle == nullptr) {
    LogNative("ObtainSurfaceDescriptor: shared_handle is null");
    return nullptr;
  }
  return &impl->descriptor;
}

}  // namespace

// ---------------------------------------------------------------------

PreviewEngine* PreviewEngine::Instance() {
  static PreviewEngine instance;
  return &instance;
}

PreviewEngine::~PreviewEngine() {
  // Best-effort tear-down; in practice the singleton outlives the
  // engine so this destructor only runs at process exit.
  CloseArgs empty{};
  if (running_.load()) Close(empty);
}

void PreviewEngine::Initialize(
    FlutterDesktopPluginRegistrarRef registrar) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (registrar_ != nullptr) return;  // already initialized
  registrar_ = registrar;
  texture_registrar_ =
      registrar ? FlutterDesktopRegistrarGetTextureRegistrar(registrar)
                : nullptr;
}

std::int64_t PreviewEngine::current_texture_id() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return texture_id_;
}

OpenResult PreviewEngine::Open(const OpenArgs& args) {
  // Truncate the log file at the top of every Open() so its tail
  // localises the most recent crash if there is one.
  {
    std::ofstream f(kNativeLogPath,
                    std::ios::out | std::ios::trunc | std::ios::binary);
  }
  LogNative("Open() entered");
  std::lock_guard<std::mutex> lock(mutex_);

  OpenResult result;
  result.width = kTextureWidth;
  result.height = kTextureHeight;

  if (texture_registrar_ == nullptr) {
    LogNative("Open() abort: texture_registrar_ is null");
    result.error =
        "PreviewEngine not initialized — Flutter texture registrar is "
        "null. Did FlutterWindow::OnCreate() call Initialize()?";
    last_error_ = result.error;
    return result;
  }
  if (args.video_path.empty()) {
    LogNative("Open() abort: video_path is empty");
    result.error =
        "PreviewEngine requires a video path. Pass POC_STAGE_2A_VIDEO via "
        "--dart-define or the args map.";
    last_error_ = result.error;
    return result;
  }
  if (::GetFileAttributesW(args.video_path.c_str()) ==
      INVALID_FILE_ATTRIBUTES) {
    LogNative("Open() abort: video file not found");
    result.error =
        "Video file not found: " + WideToUtf8(args.video_path);
    last_error_ = result.error;
    return result;
  }
  if (!args.cursor_path.empty() &&
      ::GetFileAttributesW(args.cursor_path.c_str()) ==
          INVALID_FILE_ATTRIBUTES) {
    LogNative("Open() abort: cursor file not found");
    result.error =
        "Cursor file not found: " + WideToUtf8(args.cursor_path);
    last_error_ = result.error;
    return result;
  }
  if (running_.load()) {
    // Idempotent: report the existing registration. New args are
    // ignored on re-entry — Close+Open is the way to swap inputs.
    result.texture_id = texture_id_;
    result.shared_handle_ok = shared_handle_ok_;
    result.egl_extensions = egl_extensions_;
    if (impl_ != nullptr) {
      result.video_width = static_cast<int>(impl_->last_video_width.load());
      result.video_height = static_cast<int>(impl_->last_video_height.load());
      result.cursor_event_count =
          static_cast<std::int64_t>(impl_->cursor_events.size());
      result.cursor_mode = impl_->cursor_mode;
    }
    return result;
  }

  // ---- 1. Create a D3D11 device + D2D factory. ----
  impl_ = std::make_unique<Impl>();
  impl_->video_path = args.video_path;
  impl_->cursor_path = args.cursor_path;
  UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
  const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1,
                                      D3D_FEATURE_LEVEL_11_0,
                                      D3D_FEATURE_LEVEL_10_1};
  LogNative("Creating D3D11 device...");
  HRESULT hr = ::D3D11CreateDevice(
      nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags, levels,
      ARRAYSIZE(levels), D3D11_SDK_VERSION,
      impl_->d3d_device.ReleaseAndGetAddressOf(), nullptr,
      impl_->d3d_context.ReleaseAndGetAddressOf());
  {
    char buf[64];
    std::snprintf(buf, sizeof(buf),
                  "D3D11CreateDevice -> HRESULT 0x%08lX",
                  static_cast<unsigned long>(hr));
    LogNative(buf);
  }
  if (FAILED(hr)) {
    char buf[128];
    std::snprintf(buf, sizeof(buf),
                  "D3D11CreateDevice failed (HRESULT 0x%08lX)",
                  static_cast<unsigned long>(hr));
    result.error = buf;
    last_error_ = result.error;
    impl_.reset();
    return result;
  }

  // Capture GPU description for the artifact.
  ComPtr<IDXGIDevice> dxgi_device;
  if (SUCCEEDED(impl_->d3d_device.As(&dxgi_device))) {
    ComPtr<IDXGIAdapter> adapter;
    if (SUCCEEDED(dxgi_device->GetAdapter(adapter.GetAddressOf()))) {
      DXGI_ADAPTER_DESC desc{};
      if (SUCCEEDED(adapter->GetDesc(&desc))) {
        impl_->gpu_description = WideToUtf8(desc.Description);
      }
    }
  }

  // VideoFrameAvailable fires on a WinRT thread-pool worker. We do
  // the whole copy/render/handoff on that worker thread. Mandatory:
  //   * D3D11 multithread-protect (below)
  //   * D2D1_FACTORY_TYPE_MULTI_THREADED (below)
  ComPtr<ID3D11Multithread> mt;
  if (SUCCEEDED(impl_->d3d_context.As(&mt))) {
    mt->SetMultithreadProtected(TRUE);
  }

  // D2D factory + device + context.
  D2D1_FACTORY_OPTIONS d2d_opts{};
#if defined(_DEBUG)
  d2d_opts.debugLevel = D2D1_DEBUG_LEVEL_INFORMATION;
#endif
  hr = D2D1CreateFactory(
      D2D1_FACTORY_TYPE_MULTI_THREADED, __uuidof(ID2D1Factory1), &d2d_opts,
      reinterpret_cast<void**>(impl_->d2d_factory.ReleaseAndGetAddressOf()));
  if (FAILED(hr)) {
    result.error = "D2D1CreateFactory failed";
    last_error_ = result.error;
    impl_.reset();
    return result;
  }
  hr = impl_->d2d_factory->CreateDevice(
      dxgi_device.Get(), impl_->d2d_device.ReleaseAndGetAddressOf());
  if (FAILED(hr)) {
    result.error = "ID2D1Factory1::CreateDevice failed";
    last_error_ = result.error;
    impl_.reset();
    return result;
  }
  hr = impl_->d2d_device->CreateDeviceContext(
      D2D1_DEVICE_CONTEXT_OPTIONS_NONE,
      impl_->d2d_context.ReleaseAndGetAddressOf());
  if (FAILED(hr)) {
    result.error = "ID2D1Device::CreateDeviceContext failed";
    last_error_ = result.error;
    impl_.reset();
    return result;
  }

  // WinRT IDirect3DDevice (MediaPlayer.CopyFrameToVideoSurface needs
  // it via the IDirect3DSurface the compositor owns).
  {
    ComPtr<::IInspectable> inspectable;
    hr = ::CreateDirect3D11DeviceFromDXGIDevice(
        dxgi_device.Get(),
        reinterpret_cast<::IInspectable**>(inspectable.GetAddressOf()));
    if (FAILED(hr)) {
      result.error = "CreateDirect3D11DeviceFromDXGIDevice failed";
      last_error_ = result.error;
      impl_.reset();
      return result;
    }
    winrt::com_ptr<::IInspectable> winrt_inspectable;
    winrt_inspectable.attach(inspectable.Detach());
    impl_->winrt_device =
        winrt_inspectable.as<winrt_dxd3d::IDirect3DDevice>();
  }

  // ---- 2. Allocate the shared texture. ----
  LogNative("Allocating D3D11_RESOURCE_MISC_SHARED texture...");
  const auto td = MakeSharedTextureDesc(kTextureWidth, kTextureHeight);
  hr = impl_->d3d_device->CreateTexture2D(
      &td, nullptr, impl_->shared_texture.ReleaseAndGetAddressOf());
  if (FAILED(hr)) {
    char buf[128];
    std::snprintf(buf, sizeof(buf),
                  "CreateTexture2D (shared) failed (HRESULT 0x%08lX)",
                  static_cast<unsigned long>(hr));
    result.error = buf;
    last_error_ = result.error;
    impl_.reset();
    return result;
  }

  // ---- 3. Obtain the legacy DXGI shared handle. ----
  LogNative("Querying IDXGIResource + GetSharedHandle...");
  ComPtr<IDXGIResource> dxgi_resource;
  hr = impl_->shared_texture.As(&dxgi_resource);
  if (FAILED(hr)) {
    result.error = "Texture does not expose IDXGIResource";
    last_error_ = result.error;
    impl_.reset();
    return result;
  }
  hr = dxgi_resource->GetSharedHandle(&impl_->shared_handle);
  if (FAILED(hr) || impl_->shared_handle == nullptr) {
    char buf[128];
    std::snprintf(buf, sizeof(buf),
                  "IDXGIResource::GetSharedHandle failed (HRESULT 0x%08lX). "
                  "Likely an Intel iGPU driver issue.",
                  static_cast<unsigned long>(hr));
    result.error = buf;
    last_error_ = result.error;
    impl_.reset();
    return result;
  }
  shared_handle_ok_ = true;

  // Wrap the shared texture as a D2D bitmap render target. Same target
  // every frame — bind once at Open, SetTarget once, reuse.
  {
    ComPtr<IDXGISurface> dxgi_surface;
    hr = impl_->shared_texture.As(&dxgi_surface);
    if (FAILED(hr)) {
      result.error = "Shared texture does not expose IDXGISurface";
      last_error_ = result.error;
      impl_->shared_handle = nullptr;
      impl_.reset();
      shared_handle_ok_ = false;
      return result;
    }
    const auto props = D2D1::BitmapProperties1(
        D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                          D2D1_ALPHA_MODE_IGNORE));
    hr = impl_->d2d_context->CreateBitmapFromDxgiSurface(
        dxgi_surface.Get(), &props,
        impl_->shared_bitmap.ReleaseAndGetAddressOf());
    if (FAILED(hr)) {
      result.error = "CreateBitmapFromDxgiSurface (shared) failed";
      last_error_ = result.error;
      impl_->shared_handle = nullptr;
      impl_.reset();
      shared_handle_ok_ = false;
      return result;
    }
  }
  impl_->d2d_context->SetTarget(impl_->shared_bitmap.Get());

  // ---- 4. Build the descriptor. The same struct is handed back to
  //         Flutter every callback (texture size doesn't change).
  impl_->descriptor.struct_size = sizeof(FlutterDesktopGpuSurfaceDescriptor);
  impl_->descriptor.handle = impl_->shared_handle;
  impl_->descriptor.width = static_cast<size_t>(kTextureWidth);
  impl_->descriptor.height = static_cast<size_t>(kTextureHeight);
  impl_->descriptor.visible_width = static_cast<size_t>(kTextureWidth);
  impl_->descriptor.visible_height = static_cast<size_t>(kTextureHeight);
  impl_->descriptor.format = kFlutterDesktopPixelFormatBGRA8888;
  impl_->descriptor.release_callback = nullptr;
  impl_->descriptor.release_context = nullptr;

  // ---- 5. Load cursor JSONL (if provided). ----
  if (!args.cursor_path.empty()) {
    impl_->cursor_events =
        clingfy::preview::LoadCursorJsonl(args.cursor_path);
    impl_->cursor_mode = !impl_->cursor_events.empty();
    char buf[96];
    std::snprintf(buf, sizeof(buf),
                  "cursor_events parsed: %zu  (cursor_mode=%d)",
                  impl_->cursor_events.size(), impl_->cursor_mode ? 1 : 0);
    LogNative(buf);
  }

  // ---- 6. Register the external texture. ----
  LogNative("Registering external texture via C API...");
  FlutterDesktopTextureInfo info{};
  info.type = kFlutterDesktopGpuSurfaceTexture;
  info.gpu_surface_config.struct_size =
      sizeof(FlutterDesktopGpuSurfaceTextureConfig);
  info.gpu_surface_config.type =
      kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle;
  info.gpu_surface_config.callback = &ObtainSurfaceDescriptor;
  info.gpu_surface_config.user_data = impl_.get();
  const int64_t tex_id =
      FlutterDesktopTextureRegistrarRegisterExternalTexture(
          texture_registrar_, &info);
  {
    char buf[64];
    std::snprintf(buf, sizeof(buf), "RegisterExternalTexture -> id=%lld",
                  static_cast<long long>(tex_id));
    LogNative(buf);
  }
  if (tex_id < 0) {
    result.error =
        "FlutterDesktopTextureRegistrarRegisterExternalTexture returned -1";
    last_error_ = result.error;
    impl_->shared_handle = nullptr;
    impl_.reset();
    shared_handle_ok_ = false;
    return result;
  }
  texture_id_ = tex_id;
  texture_width_ = kTextureWidth;
  texture_height_ = kTextureHeight;
  egl_extensions_.clear();
  last_error_.clear();

  // ---- 7. Set up MediaPlayer in frame-server mode. ----
  shutting_down_.store(false);
  try {
    impl_->player = winrt_playback::MediaPlayer();
    impl_->player.IsVideoFrameServerEnabled(true);
    impl_->player.IsLoopingEnabled(true);

    wchar_t full[MAX_PATH * 2] = {};
    const DWORD n = ::GetFullPathNameW(args.video_path.c_str(),
                                       ARRAYSIZE(full), full, nullptr);
    if (n == 0 || n >= ARRAYSIZE(full)) {
      result.error = "Could not resolve video path to an absolute URI.";
      last_error_ = result.error;
      // Unwind partial state.
      impl_->player = nullptr;
      impl_->shared_handle = nullptr;
      impl_.reset();
      shared_handle_ok_ = false;
      return result;
    }
    std::wstring uri = L"file:///";
    for (DWORD i = 0; i < n; ++i) {
      uri.push_back(full[i] == L'\\' ? L'/' : full[i]);
    }
    const winrt_foundation::Uri winrt_uri{uri};
    impl_->player.Source(
        winrt_media::MediaSource::CreateFromUri(winrt_uri));

    // Capturing `this` (the singleton) is safe because the singleton
    // outlives the player; Close() unsubscribes the token before
    // releasing the player. The frame body lives in HandleVideoFrame()
    // below; this lambda is a thin trampoline so the winrt projection
    // types don't leak into the public header.
    PreviewEngine* self = this;
    impl_->frame_token = impl_->player.VideoFrameAvailable(
        [self](winrt_playback::MediaPlayer const& sender,
               winrt_foundation::IInspectable const& /*args*/) {
          self->HandleVideoFrame(&sender);
        });
    impl_->player.Play();
    LogNative("MediaPlayer started + VideoFrameAvailable subscribed");
  } catch (winrt::hresult_error const& e) {
    result.error =
        "MediaPlayer setup failed: " + WideToUtf8(e.message().c_str());
    last_error_ = result.error;
    impl_->player = nullptr;
    impl_->shared_handle = nullptr;
    impl_.reset();
    shared_handle_ok_ = false;
    return result;
  }

  running_.store(true);
  LogNative("Open() returning success");

  result.texture_id = tex_id;
  result.shared_handle_ok = true;
  result.egl_extensions = egl_extensions_;
  result.video_width = 0;  // discovered on first frame
  result.video_height = 0;
  result.cursor_event_count =
      static_cast<std::int64_t>(impl_->cursor_events.size());
  result.cursor_mode = impl_->cursor_mode;
  result.error.clear();
  return result;
}

void PreviewEngine::HandleVideoFrame(
    const void* sender_media_player_ptr) {
  if (sender_media_player_ptr == nullptr) return;
  // The lambda in Open() passes `&sender`; sender is a
  // `MediaPlayer const&` from the WinRT callback. Reinterpret back
  // to the concrete type for the per-frame work.
  const auto& sender =
      *static_cast<winrt_playback::MediaPlayer const*>(sender_media_player_ptr);
  if (shutting_down_.load()) {
    if (impl_) impl_->dropped_frames.fetch_add(1, std::memory_order_relaxed);
    return;
  }
  // Snapshot pointer under lock so a concurrent Close can't drop impl_
  // mid-frame. The render path itself doesn't need the singleton-level
  // mutex; impl_->render_mutex serializes frames against each other.
  Impl* impl = nullptr;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    impl = impl_.get();
    if (impl == nullptr) return;
  }

  std::lock_guard<std::mutex> render_lock(impl->render_mutex);
  if (shutting_down_.load() || impl_ == nullptr) {
    impl->dropped_frames.fetch_add(1, std::memory_order_relaxed);
    return;
  }

  impl->timing_total.BeginFrame();

  const auto session = sender.PlaybackSession();
  const UINT vw = session.NaturalVideoWidth();
  const UINT vh = session.NaturalVideoHeight();
  if (vw == 0 || vh == 0) {
    impl->dropped_frames.fetch_add(1, std::memory_order_relaxed);
    impl->timing_total.EndFrame();
    return;
  }
  impl->last_video_width.store(vw);
  impl->last_video_height.store(vh);

  if (FAILED(impl->compositor.EnsureResources(impl->d3d_device.Get(),
                                              impl->d2d_context.Get(),
                                              vw, vh))) {
    impl->dropped_frames.fetch_add(1, std::memory_order_relaxed);
    impl->timing_total.EndFrame();
    return;
  }

  // ---- copy bucket ----
  impl->timing_copy.BeginFrame();
  try {
    sender.CopyFrameToVideoSurface(impl->compositor.winrt_video_surface());
  } catch (winrt::hresult_error const&) {
    impl->dropped_frames.fetch_add(1, std::memory_order_relaxed);
    impl->timing_copy.EndFrame();
    impl->timing_total.EndFrame();
    return;
  }
  impl->timing_copy.EndFrame();

  // ---- render bucket ----
  // The shared texture IS the destination — no slider strip. Letterbox
  // the natural video into the full canvas.
  const D2D1_RECT_F dest = clingfy::preview::LetterboxRect(
      static_cast<UINT>(kTextureWidth), static_cast<UINT>(kTextureHeight),
      impl->compositor.video_width(), impl->compositor.video_height());
  const std::int64_t playback_us =
      impl->cursor_mode ? CurrentPlaybackUs(sender) : -1;

  impl->timing_render.BeginFrame();
  impl->d2d_context->BeginDraw();
  impl->compositor.ComposeFrame(impl->d2d_context.Get(), dest,
                                impl->cursor_events, playback_us,
                                NowSeconds(), impl->zoom);
  const HRESULT end_hr = impl->d2d_context->EndDraw();
  impl->timing_render.EndFrame();
  if (FAILED(end_hr)) {
    // D2DERR_RECREATE_TARGET would be the typical failure here; we
    // don't recover yet (the descriptor + bitmap are bound once at
    // Open). Production recovery lands in Step 5.3 along with the
    // texture-unregister fix. Drop the frame and move on.
    impl->dropped_frames.fetch_add(1, std::memory_order_relaxed);
    impl->timing_total.EndFrame();
    return;
  }

  // ---- handoff bucket ----
  // Flush the D3D11 command queue so the writes against the shared
  // texture land before Flutter's consumer device samples it. Without
  // this you get intermittent torn / stale frames on Intel iGPUs.
  impl->timing_handoff.BeginFrame();
  impl->d3d_context->Flush();
  if (texture_registrar_ && texture_id_ >= 0) {
    FlutterDesktopTextureRegistrarMarkExternalTextureFrameAvailable(
        texture_registrar_, texture_id_);
  }
  impl->timing_handoff.EndFrame();

  impl->frames_consumed.fetch_add(1, std::memory_order_relaxed);
  impl->timing_total.EndFrame();
}

void PreviewEngine::Close(const CloseArgs& args) {
  LogNative("Close() entered");
  if (!running_.load()) {
    LogNative("Close() abort: not running");
    return;
  }
  shutting_down_.store(true);
  running_.store(false);

  // ---- 1. Unsubscribe + tear down the MediaPlayer FIRST. ----
  // Doing this before we touch impl_ avoids a callback racing the
  // unique_ptr move below. MediaPlayer::Close() is documented to
  // wait for the last pending callback to drain.
  std::unique_ptr<Impl> dying_impl;
  std::int64_t tex_id_to_unregister = -1;
  std::string gpu;
  bool handle_ok = false;
  std::string err;
  int tw = 0, th_h = 0;
  std::wstring video_path;
  std::wstring cursor_path;
  std::uint64_t dropped = 0;
  std::int64_t frames_consumed = 0;
  UINT video_w = 0, video_h = 0;
  std::size_t cursor_events_size = 0;
  bool cursor_mode = false;
  clingfy::preview::FrameTimingStats stats_total{};
  clingfy::preview::FrameTimingStats stats_copy{};
  clingfy::preview::FrameTimingStats stats_render{};
  clingfy::preview::FrameTimingStats stats_handoff{};

  {
    std::lock_guard<std::mutex> lock(mutex_);
    tex_id_to_unregister = texture_id_;
    handle_ok = shared_handle_ok_;
    err = last_error_;
    tw = texture_width_;
    th_h = texture_height_;
    dying_impl = std::move(impl_);
    texture_id_ = -1;
    shared_handle_ok_ = false;
    egl_extensions_.clear();
  }
  if (dying_impl) {
    gpu = dying_impl->gpu_description;
    video_path = dying_impl->video_path;
    cursor_path = dying_impl->cursor_path;
    dropped = dying_impl->dropped_frames.load();
    frames_consumed = dying_impl->frames_consumed.load();
    video_w = dying_impl->last_video_width.load();
    video_h = dying_impl->last_video_height.load();
    cursor_events_size = dying_impl->cursor_events.size();
    cursor_mode = dying_impl->cursor_mode;
    stats_total = dying_impl->timing_total.ComputeStats();
    stats_copy = dying_impl->timing_copy.ComputeStats();
    stats_render = dying_impl->timing_render.ComputeStats();
    stats_handoff = dying_impl->timing_handoff.ComputeStats();

    // Drain the MediaPlayer under render_mutex so no in-flight
    // callback is touching the compositor when we proceed.
    try {
      if (dying_impl->player) {
        if (dying_impl->frame_token.value) {
          dying_impl->player.VideoFrameAvailable(dying_impl->frame_token);
        }
        dying_impl->player.Pause();
        dying_impl->player.Close();
        dying_impl->player = nullptr;
      }
    } catch (winrt::hresult_error const&) {
      // Best-effort.
    }
  }

  // ---- 2. SKIP UnregisterExternalTexture — see PR #102 writeup.
  // Async unregister + Intel iGPU + Flutter ANGLE consumer = 0xC0000005
  // crash on shutdown. We intentionally leak the texture; process is
  // about to exit anyway. Step 5.3 (Phase 5 implementation plan)
  // replaces this with a production-grade lifecycle.
  LogNative("Close() SKIPPING UnregisterExternalTexture (POC workaround)");
  if (dying_impl) dying_impl.release();

  // ---- 3. Write the artifact. ----
  std::ofstream f(kArtifactPath,
                  std::ios::out | std::ios::trunc | std::ios::binary);
  if (f.is_open()) {
    f << "# Stage 2A-2 — MediaPlayer + PreviewCompositor through Flutter Texture\n\n";
    f << "- **Generated:** " << UtcTimestampNow() << " (UTC)\n";
    f << "- **Mode:** "
      << (cursor_mode ? "video + cursor (zoom/highlight)"
                      : "video-only")
      << "\n";
    f << "- **OS:** " << WindowsVersionString() << "\n";
    f << "- **GPU (producer device):** " << gpu << "\n";
    f << "- **Texture size (Flutter samples):** " << tw << " x " << th_h
      << " px\n";
    f << "- **Video natural size:** " << video_w << " x " << video_h
      << " px\n";
    f << "- **Video path:** `" << WideToUtf8(video_path) << "`\n";
    if (!cursor_path.empty()) {
      f << "- **Cursor path:** `" << WideToUtf8(cursor_path) << "` ("
        << cursor_events_size << " events)\n";
    }
    f << "\n";

    f << "## DXGI shared-handle status\n\n";
    f << "- **Allocated:** " << (handle_ok ? "yes" : "**no**") << "\n";
    f << "- **Flutter texture id:** " << tex_id_to_unregister << "\n";
    if (!err.empty()) {
      f << "- **Last error:** `" << err << "`\n";
    }
    f << "\n";

    f << "## Native producer timings (per VideoFrameAvailable, ms)\n\n";
    f << "| bucket   | frames |    min  | median  |   p99   |   max   |\n";
    f << "|----------|-------:|--------:|--------:|--------:|--------:|\n";
    auto fmt_bucket = [&](const char* name,
                          const clingfy::preview::FrameTimingStats& s) {
      char buf[256];
      std::snprintf(
          buf, sizeof(buf),
          "| %-8s | %6zu | %7.3f | %7.3f | %7.3f | %7.3f |\n", name,
          s.frame_count, s.min_ms, s.median_ms, s.p99_ms, s.max_ms);
      f << buf;
    };
    fmt_bucket("total", stats_total);
    fmt_bucket("copy", stats_copy);
    fmt_bucket("render", stats_render);
    fmt_bucket("handoff", stats_handoff);
    f << "\nFrames consumed by producer: " << frames_consumed
      << " (dropped: " << dropped << ")\n\n";

    f << "## Flutter SchedulerBinding timings\n\n";
    f << "| bucket | median (ms) | p99 (ms) |\n";
    f << "|--------|------------:|---------:|\n";
    char row[128];
    std::snprintf(row, sizeof(row), "| build  | %11.3f | %8.3f |\n",
                  args.build_median_ms, args.build_p99_ms);
    f << row;
    std::snprintf(row, sizeof(row), "| raster | %11.3f | %8.3f |\n",
                  args.raster_median_ms, args.raster_p99_ms);
    f << row;
    std::snprintf(row, sizeof(row), "| total  | %11.3f | %8.3f |\n",
                  args.total_median_ms, args.total_p99_ms);
    f << row;
    f << "\nFrames observed by Dart: " << args.flutter_frames_observed
      << "\n\n";

    f << "## Verdict vs design-doc Stage 1 bar\n\n";
    f << "- **Bar:** Flutter raster median <= " << kPassBarMedianMs
      << " ms AND raster p99 <= " << kPassBarP99Ms << " ms,\n";
    f << "  AND native producer total median <= " << kPassBarMedianMs
      << " ms AND p99 <= " << kPassBarP99Ms << " ms,\n";
    f << "  AND shared-handle ok, AND >= 1 frame consumed.\n";
    const bool pass_handle = handle_ok && tex_id_to_unregister >= 0;
    const bool pass_frames = frames_consumed > 0;
    const bool pass_flutter_med = args.raster_median_ms <= kPassBarMedianMs;
    const bool pass_flutter_p99 = args.raster_p99_ms <= kPassBarP99Ms;
    const bool pass_native_med = stats_total.median_ms <= kPassBarMedianMs;
    const bool pass_native_p99 = stats_total.p99_ms <= kPassBarP99Ms;
    const bool pass = pass_handle && pass_frames && pass_flutter_med &&
                      pass_flutter_p99 && pass_native_med &&
                      pass_native_p99;
    char verdict[512];
    std::snprintf(verdict, sizeof(verdict),
                  "- **Result:** handle=%s, frames=%lld, "
                  "flutter raster median=%.3f (%s), p99=%.3f (%s), "
                  "native total median=%.3f (%s), p99=%.3f (%s) -> "
                  "**%s**\n",
                  pass_handle ? "ok" : "FAIL",
                  static_cast<long long>(frames_consumed),
                  args.raster_median_ms, pass_flutter_med ? "PASS" : "FAIL",
                  args.raster_p99_ms, pass_flutter_p99 ? "PASS" : "FAIL",
                  stats_total.median_ms,
                  pass_native_med ? "PASS" : "FAIL",
                  stats_total.p99_ms, pass_native_p99 ? "PASS" : "FAIL",
                  pass ? "PASS" : "FAIL");
    f << verdict << "\n";
    if (!pass) {
      f << "_Stage 2A-2 missed the Stage 1 bar. The architecture decision "
           "should NOT lock in Approach A until the failing bucket is "
           "explained and remediated._\n";
    }
    std::fprintf(stderr, "STAGE2A_2_ARTIFACT wrote %ls\n", kArtifactPath);
    std::fflush(stderr);
  }
}

}  // namespace clingfy::preview
