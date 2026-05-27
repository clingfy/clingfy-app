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
#include <filesystem>
#include <fstream>
#include <limits>
#include <system_error>

#include "Bridge/player_event_publisher.h"
#include "Bridge/workflow_event_publisher.h"
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
// Step 5.7.1: process-lifetime append-only log for PHASE5-OPEN /
// PHASE5-CYCLE structured lines. Separate from kNativeLogPath because
// that file is truncated at every Open() for crash-breadcrumb
// localisation — truncation would defeat the stress verdict tool,
// which needs cross-cycle history to compute aggregate stats.
constexpr wchar_t kPhase5CycleLogPath[] =
    L"build\\windows-poc\\phase5_cycles.log";

void EnsureLogParentDir() {
  // Both log files live under build\windows-poc\. Create the dir if it
  // doesn't exist yet — on a fresh checkout the directory is gitignored
  // and missing, which would otherwise cause `std::ofstream` to fail
  // silently and the stress verdict tool to find nothing.
  std::error_code ec;
  std::filesystem::create_directories(L"build\\windows-poc", ec);
}

// Step 5.7: process-lifetime monotonic counter incremented at every
// Open. Used as the `cycle` key in the structured PHASE5-CYCLE log
// lines that `tools/phase5_extract_verdict.ps1` aggregates. Atomic
// so the (currently single-threaded) Open path stays correct even if
// a future stress runner drives multiple Opens from worker threads.
std::atomic<std::int64_t> g_phase5_cycle_counter{0};

std::int64_t QueryQpcFrequencyHz() {
  LARGE_INTEGER freq{};
  if (!::QueryPerformanceFrequency(&freq)) return 0;
  return static_cast<std::int64_t>(freq.QuadPart);
}

std::int64_t NowQpc() {
  LARGE_INTEGER now{};
  ::QueryPerformanceCounter(&now);
  return static_cast<std::int64_t>(now.QuadPart);
}

std::int64_t QpcDeltaMs(std::int64_t start, std::int64_t end,
                         std::int64_t freq) {
  if (freq <= 0 || start <= 0 || end < start) return 0;
  return ((end - start) * 1000) / freq;
}

// File-based logger because a Flutter Windows debug build is a GUI
// subsystem exe with no console; the standard streams are not
// reliably reachable from outside. The log file is overwritten each
// Open(); each line carries an HRESULT-style breadcrumb so a crash
// can be localised by inspecting the last surviving line.
void LogNative(const char* msg) {
  EnsureLogParentDir();
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

// Step 5.7.1: append-only cycle log. Lives separately from
// kNativeLogPath because that file is truncated on every Open() — a
// design constraint for crash-breadcrumb localisation but lethal for
// cross-cycle aggregation. The stress verdict tool reads from this
// file. Format-wise identical to LogNative; differences are scope
// (which file) and the no-truncate guarantee.
void LogPhase5Cycle(const char* msg) {
  EnsureLogParentDir();
  std::ofstream f(kPhase5CycleLogPath,
                  std::ios::out | std::ios::app | std::ios::binary);
  if (!f.is_open()) return;
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
  // Step 5.4 event hooks. PlaybackStateChanged + MediaEnded +
  // MediaFailed surface as playerState / playerError events. Tokens
  // captured here so Close() can unsubscribe before tearing the
  // player down.
  winrt::event_token state_changed_token{};
  winrt::event_token media_ended_token{};
  winrt::event_token media_failed_token{};

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

  // ---- Step 5.5 seek tracking ----
  // Each SeekTo() call appends a sample; the next VideoFrameAvailable
  // sets resolved_qpc on the first unresolved entry. The seek-latency
  // numbers feed the Phase 5.7 multi-GPU verdict artifact; production
  // playback doesn't read them otherwise. Guarded by render_mutex
  // (same lock the per-frame composition path takes).
  struct SeekSample {
    std::int64_t target_ms = 0;
    std::int64_t call_qpc = 0;
    std::int64_t resolved_qpc = 0;
    bool resolved = false;
  };
  std::vector<SeekSample> seek_samples;

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
  if (args.session_id.empty()) {
    LogNative("Open() abort: session_id is empty");
    result.error = "PreviewEngine requires a non-empty session_id.";
    last_error_ = result.error;
    return result;
  }
  if (args.video_path.empty()) {
    LogNative("Open() abort: video_path is empty");
    result.error =
        "PreviewEngine requires a video path.";
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
    if (active_session_id_ == args.session_id) {
      // Idempotent: report the existing registration. New paths are
      // ignored on same-session re-entry — Close+Open is the way to
      // swap inputs.
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
    // Different session id while already running — caller must Close
    // the previous session first. Surfacing a real error here is
    // safer than silently force-closing the previous session out
    // from under whichever Dart layer still holds its texture id.
    LogNative("Open() abort: another session is already active");
    result.error =
        "PreviewEngine already has an active session — Close it first.";
    last_error_ = result.error;
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
    // Production preview does NOT loop. Phase 5 wants MediaEnded to
    // surface as a "completed" playerState event in Step 5.4; looping
    // would swallow that signal. The earlier POC enabled looping as a
    // convenience so a short fixture could be measured for the full
    // 25 s auto-stop window; that convenience does not survive the
    // production previewOpen path.
    impl_->player.IsLoopingEnabled(false);

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
    // outlives the player; Close() unsubscribes every token before
    // releasing the player. Each lambda body lives in a Handle*()
    // member below; these lambdas are thin trampolines so the winrt
    // projection types don't leak into the public header.
    PreviewEngine* self = this;
    impl_->frame_token = impl_->player.VideoFrameAvailable(
        [self](winrt_playback::MediaPlayer const& sender,
               winrt_foundation::IInspectable const& /*args*/) {
          self->HandleVideoFrame(&sender);
        });

    // PlaybackStateChanged fires on transitions between Opening /
    // Buffering / Playing / Paused / None. We translate to the macOS
    // "playing" / "paused" pair (Opening + Buffering coalesce to
    // "paused" so Dart's _playerPlaying stays false during load).
    impl_->state_changed_token =
        impl_->player.PlaybackSession().PlaybackStateChanged(
            [self](winrt_playback::MediaPlaybackSession const& session,
                   winrt_foundation::IInspectable const& /*args*/) {
              self->HandlePlaybackStateChanged(&session);
            });

    // MediaEnded fires when playback runs off the end of the source
    // (IsLoopingEnabled is false in production; see Open's IsLooping
    // call above). Emit playerState "completed".
    impl_->media_ended_token = impl_->player.MediaEnded(
        [self](winrt_playback::MediaPlayer const& sender,
               winrt_foundation::IInspectable const& /*args*/) {
          self->HandleMediaEnded(&sender);
        });

    // MediaFailed fires when the source file becomes unreadable
    // mid-playback (deleted, network drop, codec failure, etc.). Map
    // to VIDEO_FILE_MISSING — matches the macOS code surface so the
    // Dart side can use the same error-handling branch.
    impl_->media_failed_token = impl_->player.MediaFailed(
        [self](winrt_playback::MediaPlayer const& sender,
               winrt_playback::MediaPlayerFailedEventArgs const& args) {
          self->HandleMediaFailed(&sender, &args);
        });

    impl_->player.Play();
    LogNative("MediaPlayer started + event subscriptions installed");
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

  active_session_id_ = args.session_id;
  active_project_path_ = args.project_path;
  emitted_preview_ready_ = false;
  running_.store(true);

  // Step 5.5.3: announce that native is warming up the preview. macOS
  // emits this from InlinePreviewView.swift right after the player is
  // created; Windows mirrors that here. Dart's `_handlePreviewPreparing`
  // is idempotent w.r.t. workflow phase (it stays in / transitions to
  // `previewLoading`), so a duplicate emit is harmless. The matching
  // `previewReady` event fires from the first VideoFrameAvailable.
  clingfy::bridge::WorkflowEventPublisher::Instance().EmitPreviewPreparing(
      args.session_id, args.project_path);

  // Step 5.4: emit CURSOR_FILE_MISSING when a cursor path was supplied
  // but parsed to zero events. The file existed (we checked above) but
  // its content was empty or malformed; non-fatal so playback keeps
  // going, but Dart wants to surface a banner.
  if (!args.cursor_path.empty() && !impl_->cursor_mode) {
    clingfy::bridge::PlayerEventPublisher::Instance().EmitPlayerWarning(
        args.session_id, "CURSOR_FILE_MISSING",
        "Cursor data is missing. Cursor effects are disabled.");
  }

  // Spawn the paused-heartbeat thread. It loops at ~100ms and emits
  // a playerTick whenever the producer hasn't ticked in the last
  // ~150ms (covers paused, buffering, and seeking states). Joined in
  // Close() before the texture lifecycle teardown. shutting_down_ is
  // already false at this point — set by the MediaPlayer setup block
  // above.
  heartbeat_thread_ = std::thread([this] { HeartbeatLoop(); });

  LogNative("Open() returning success");

  // Step 5.7: structured open-side line for the verdict tool. Pairs
  // with the PHASE5-CYCLE line emitted by OnUnregisterComplete. The
  // open-side log line carries the freshly-allocated texture_id and
  // the monotonic cycle counter so the parser can pair them.
  const std::int64_t cycle_index =
      g_phase5_cycle_counter.fetch_add(1, std::memory_order_relaxed) + 1;
  {
    char buf[256];
    std::snprintf(buf, sizeof(buf),
                  "PHASE5-OPEN cycle=%lld session=%s texture_id=%lld",
                  static_cast<long long>(cycle_index),
                  args.session_id.empty() ? "(none)"
                                          : args.session_id.c_str(),
                  static_cast<long long>(tex_id));
    LogPhase5Cycle(buf);
  }
  current_cycle_index_ = cycle_index;

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

  // Step 5.5: resolve the first unresolved seek (if any). Stage 1D
  // semantics — the QPC delta between SeekTo() and "next frame" is the
  // seek latency. Multiple SeekTo() calls between frames stack up;
  // each successive VideoFrameAvailable resolves the next sample.
  {
    LARGE_INTEGER qpc{};
    ::QueryPerformanceCounter(&qpc);
    for (auto& s : impl->seek_samples) {
      if (!s.resolved) {
        s.resolved = true;
        s.resolved_qpc = static_cast<std::int64_t>(qpc.QuadPart);
        break;
      }
    }
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

  // Step 5.4: emit playerTick AFTER the texture is marked available.
  // The session id snapshot under the singleton mutex tolerates a
  // racing Close (it would have cleared active_session_id_ before
  // joining the heartbeat / draining callbacks). NowMs() snapshot
  // here also feeds the heartbeat thread's "skip if recent" check.
  std::string session_snapshot;
  std::string project_path_snapshot;
  bool fire_preview_ready = false;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    session_snapshot = active_session_id_;
    project_path_snapshot = active_project_path_;
    // Step 5.5.3: the first successfully rendered frame is the signal
    // Dart needs to lift the "Preparing preview" overlay. Latch under
    // the singleton mutex so we emit exactly once per Open / Close
    // cycle even though the WinRT worker thread may produce multiple
    // frames concurrently with a racing Close.
    if (!emitted_preview_ready_ && !session_snapshot.empty() &&
        !shutting_down_.load()) {
      emitted_preview_ready_ = true;
      fire_preview_ready = true;
    }
  }
  if (fire_preview_ready) {
    clingfy::bridge::WorkflowEventPublisher::Instance().EmitPreviewReady(
        session_snapshot, project_path_snapshot);
  }
  if (!session_snapshot.empty() && !shutting_down_.load()) {
    const std::int64_t pos_us = CurrentPlaybackUs(sender);
    std::int64_t dur_us = 0;
    try {
      const auto d = sender.PlaybackSession().NaturalDuration();
      dur_us =
          std::chrono::duration_cast<std::chrono::microseconds>(d).count();
    } catch (winrt::hresult_error const&) {
      dur_us = 0;
    }
    const std::int64_t pos_ms = pos_us > 0 ? pos_us / 1000 : 0;
    const std::int64_t dur_ms = dur_us > 0 ? dur_us / 1000 : 0;
    last_frame_ms_.store(
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch())
            .count(),
        std::memory_order_relaxed);
    clingfy::bridge::PlayerEventPublisher::Instance().EmitPlayerTick(
        session_snapshot, pos_ms, dur_ms);
  }
}

void PreviewEngine::HandlePlaybackStateChanged(
    const void* sender_playback_session_ptr) {
  if (sender_playback_session_ptr == nullptr) return;
  if (shutting_down_.load() || !running_.load()) return;
  const auto& session =
      *static_cast<winrt_playback::MediaPlaybackSession const*>(
          sender_playback_session_ptr);

  // Map WinRT MediaPlaybackState to the macOS-compatible string set.
  // Opening / Buffering / None all coalesce to "paused" so Dart's
  // PlayerController doesn't think it's playing during load. The
  // explicit "Playing" → "playing" mapping is the only positive case.
  std::string state_str;
  try {
    switch (session.PlaybackState()) {
      case winrt_playback::MediaPlaybackState::Playing:
        state_str = "playing";
        break;
      case winrt_playback::MediaPlaybackState::Paused:
        state_str = "paused";
        break;
      case winrt_playback::MediaPlaybackState::Opening:
      case winrt_playback::MediaPlaybackState::Buffering:
      case winrt_playback::MediaPlaybackState::None:
      default:
        state_str = "paused";
        break;
    }
  } catch (winrt::hresult_error const&) {
    return;
  }

  std::string session_snapshot;
  bool should_emit = false;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    session_snapshot = active_session_id_;
    // Debounce: only emit when the state actually changed.
    if (state_str != last_emitted_state_) {
      last_emitted_state_ = state_str;
      should_emit = true;
    }
  }
  if (should_emit && !session_snapshot.empty()) {
    clingfy::bridge::PlayerEventPublisher::Instance().EmitPlayerState(
        session_snapshot, state_str);
  }
}

void PreviewEngine::HandleMediaEnded(
    const void* /*sender_media_player_ptr*/) {
  if (shutting_down_.load() || !running_.load()) return;
  std::string session_snapshot;
  bool should_emit = false;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    session_snapshot = active_session_id_;
    if (last_emitted_state_ != "completed") {
      last_emitted_state_ = "completed";
      should_emit = true;
    }
  }
  if (should_emit && !session_snapshot.empty()) {
    clingfy::bridge::PlayerEventPublisher::Instance().EmitPlayerState(
        session_snapshot, "completed");
  }
}

void PreviewEngine::HandleMediaFailed(
    const void* /*sender_media_player_ptr*/,
    const void* args_failed_event_args_ptr) {
  if (shutting_down_.load() || !running_.load()) return;
  const auto* failed_args =
      static_cast<winrt_playback::MediaPlayerFailedEventArgs const*>(
          args_failed_event_args_ptr);
  std::string message = "MediaPlayer reported a media failure.";
  if (failed_args != nullptr) {
    try {
      const std::wstring w = failed_args->ErrorMessage().c_str();
      if (!w.empty()) message = WideToUtf8(w);
    } catch (winrt::hresult_error const&) {
      // Best effort — keep the generic message.
    }
  }
  std::string session_snapshot;
  std::string project_path_snapshot;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    session_snapshot = active_session_id_;
    project_path_snapshot = active_project_path_;
  }
  if (!session_snapshot.empty()) {
    clingfy::bridge::PlayerEventPublisher::Instance().EmitPlayerError(
        session_snapshot, "VIDEO_FILE_MISSING", message);
    // Step 5.5.3: also emit `previewFailed` on the workflow channel so
    // Dart's RecordingController transitions out of `previewLoading` /
    // `previewReady` into the closing/error flow (matches macOS, which
    // fires this from `KVO`'d AVPlayer status observers).
    clingfy::bridge::WorkflowEventPublisher::Instance().EmitPreviewFailed(
        session_snapshot, project_path_snapshot, "VIDEO_FILE_MISSING",
        message);
  }
}

void PreviewEngine::HeartbeatLoop() {
  // Heartbeat at 10 Hz. Skips the emit when VideoFrameAvailable
  // ticked within the last 150 ms (the producer's natural cadence
  // would otherwise double-fire ticks). The reason we don't rely
  // solely on PlaybackStateChanged + the producer loop is that
  // MediaPlayer's paused-state position can change (scrubbing,
  // user-driven seek before play resumes) and Dart's _playerReady
  // must stay updated regardless.
  using namespace std::chrono_literals;
  constexpr auto kInterval = 100ms;
  constexpr std::int64_t kStaleProducerMs = 150;

  while (!shutting_down_.load()) {
    std::this_thread::sleep_for(kInterval);
    if (shutting_down_.load()) break;

    const std::int64_t now_ms =
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch())
            .count();
    const std::int64_t last_frame = last_frame_ms_.load();
    if (last_frame > 0 && (now_ms - last_frame) < kStaleProducerMs) {
      // Producer is fresh — skip this beat.
      continue;
    }

    // Snapshot the session id + the MediaPlayer pointer under the
    // mutex; release the lock before touching the player (its API
    // is safe from any thread).
    std::string session_snapshot;
    winrt_playback::MediaPlayer player_snapshot{nullptr};
    {
      std::lock_guard<std::mutex> lock(mutex_);
      session_snapshot = active_session_id_;
      if (impl_) {
        player_snapshot = impl_->player;
      }
    }
    if (session_snapshot.empty() || player_snapshot == nullptr) continue;

    std::int64_t pos_ms = 0;
    std::int64_t dur_ms = 0;
    try {
      const auto session = player_snapshot.PlaybackSession();
      const auto pos =
          std::chrono::duration_cast<std::chrono::microseconds>(
              session.Position())
              .count();
      const auto dur =
          std::chrono::duration_cast<std::chrono::microseconds>(
              session.NaturalDuration())
              .count();
      pos_ms = pos > 0 ? pos / 1000 : 0;
      dur_ms = dur > 0 ? dur / 1000 : 0;
    } catch (winrt::hresult_error const&) {
      continue;  // Skip this beat; next loop iteration retries.
    }

    clingfy::bridge::PlayerEventPublisher::Instance().EmitPlayerTick(
        session_snapshot, pos_ms, dur_ms);
  }
}

namespace {

// Carries the dying Impl alive across the async unregister round-trip.
// FlutterDesktopTextureRegistrarUnregisterExternalTexture calls
// OnUnregisterComplete (file-scope) on a Flutter thread once it has
// finished with the texture; that callback `delete`s this struct,
// which releases the Impl + drops the last reference to the D3D11 /
// D2D / WinRT resources. Doing so on Flutter's signal — instead of
// the POC's "leak forever at shutdown" — is the production texture
// lifecycle the Phase 5 ADR's "Known follow-ups" called out.
struct TearDownContext {
  std::unique_ptr<PreviewEngine::Impl> dying_impl;
  // Identifying info captured at Close time so the unregister-
  // complete log line is useful even though the Impl has been moved
  // by then.
  std::int64_t texture_id = -1;
  std::string session_id;
  // Step 5.7: capture Close's QPC tick so the
  // close-to-unregister-callback latency can be computed when the
  // Flutter side eventually fires OnUnregisterComplete. Used by the
  // PHASE5-CYCLE structured log line the verdict tool grep's for.
  std::int64_t close_qpc = 0;
  std::int64_t qpc_frequency = 0;
  std::int64_t cycle_index = 0;
  std::uint64_t frames_consumed = 0;
};

void CALLBACK OnUnregisterComplete(void* user_data) {
  // Flutter is documented to invoke this once the consumer side has
  // finished sampling the texture. From here on it is safe to drop
  // the D3D11/D2D/WinRT resources the Impl owns.
  auto* tc = static_cast<TearDownContext*>(user_data);
  if (tc == nullptr) return;
  LARGE_INTEGER now{};
  ::QueryPerformanceCounter(&now);
  const std::int64_t now_qpc = static_cast<std::int64_t>(now.QuadPart);
  std::int64_t close_to_unregister_ms = 0;
  if (tc->qpc_frequency > 0 && tc->close_qpc > 0 &&
      now_qpc >= tc->close_qpc) {
    close_to_unregister_ms =
        ((now_qpc - tc->close_qpc) * 1000) / tc->qpc_frequency;
  }
  char buf[256];
  std::snprintf(buf, sizeof(buf),
                "UnregisterExternalTexture callback fired — tex=%lld "
                "session=%s — releasing Impl",
                static_cast<long long>(tc->texture_id),
                tc->session_id.empty() ? "(none)" : tc->session_id.c_str());
  LogNative(buf);
  // Step 5.7: structured cycle-end line for the verdict tool. The
  // PHASE5-CYCLE prefix is what `tools/phase5_extract_verdict.ps1`
  // grep's for — keep the key=value layout stable. Routed through
  // LogPhase5Cycle (Step 5.7.1) so it lands in the append-only cycle
  // log instead of the truncated-per-Open native log.
  std::snprintf(buf, sizeof(buf),
                "PHASE5-CYCLE cycle=%lld session=%s frames=%llu "
                "close_to_unregister_ms=%lld",
                static_cast<long long>(tc->cycle_index),
                tc->session_id.empty() ? "(none)" : tc->session_id.c_str(),
                static_cast<unsigned long long>(tc->frames_consumed),
                static_cast<long long>(close_to_unregister_ms));
  LogPhase5Cycle(buf);
  delete tc;
}

}  // namespace

void PreviewEngine::Close(const CloseArgs& args) {
  LogNative("Close() entered");
  if (!running_.load()) {
    LogNative("Close() abort: not running");
    return;
  }

  // Stale-session no-op. Empty session_id is a wildcard the destructor
  // uses to force-close at process exit (matches macOS gotcha #2 for
  // the play/pause/seek path; we extend the same rule to Close so a
  // racy late Close from a previous session can't tear down the
  // current one).
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!args.session_id.empty() &&
        args.session_id != active_session_id_) {
      char buf[160];
      std::snprintf(buf, sizeof(buf),
                    "Close() stale-session no-op: incoming=%s active=%s",
                    args.session_id.c_str(),
                    active_session_id_.c_str());
      LogNative(buf);
      return;
    }
  }

  // Step 5.5.3: snapshot the project path + emit `previewClosed`
  // before we tear anything down. Doing it here (rather than after the
  // unregister callback) keeps the Dart-side state machine in sync
  // with native — Dart waits on `previewClosed` to leave the
  // `closingPreview` phase, and the unregister callback can land
  // hundreds of ms later.
  std::string closing_session_id;
  std::string closing_project_path;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    closing_session_id = active_session_id_;
    closing_project_path = active_project_path_;
  }

  shutting_down_.store(true);
  running_.store(false);

  // Join the heartbeat thread before we touch impl_ — the thread
  // reads impl_->player under the singleton mutex, and we don't want
  // its next iteration to race with the move below. The sleep_for in
  // HeartbeatLoop is bounded at 100ms so this join is fast.
  if (heartbeat_thread_.joinable()) {
    heartbeat_thread_.join();
  }
  LogNative("Close() heartbeat thread joined");

  if (!closing_session_id.empty()) {
    clingfy::bridge::WorkflowEventPublisher::Instance().EmitPreviewClosed(
        closing_session_id, closing_project_path,
        // `flutterRequest` mirrors the macOS reason string for a
        // Dart-initiated close (vs. native error cleanup, which uses
        // `failureCleanup`). The bridge-level close handler does not
        // currently distinguish those two cases, so we always send
        // `flutterRequest` here — recording-failure paths run through
        // `EmitPreviewFailed` first, which Dart treats as an error
        // close anyway.
        "flutterRequest");
  }

  // ---- 1. Unsubscribe + tear down the MediaPlayer FIRST. ----
  // Doing this before we touch impl_ avoids a callback racing the
  // unique_ptr move below. MediaPlayer::Close() waits for the last
  // pending callback to drain.
  std::unique_ptr<Impl> dying_impl;
  std::int64_t tex_id_to_unregister = -1;
  std::string closing_session;
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
  // Step 5.7.2: snapshot the cycle index INSIDE the lock, before the
  // cleanup clears it to zero. The earlier Step 5.7 code populated the
  // TearDownContext after the lock was released, by which point
  // current_cycle_index_ had been reset — so every PHASE5-CYCLE line
  // ended up reporting cycle=0, breaking the verdict tool's pairing.
  std::int64_t closing_cycle_index = 0;

  {
    std::lock_guard<std::mutex> lock(mutex_);
    tex_id_to_unregister = texture_id_;
    closing_session = active_session_id_;
    handle_ok = shared_handle_ok_;
    err = last_error_;
    tw = texture_width_;
    th_h = texture_height_;
    closing_cycle_index = current_cycle_index_;
    dying_impl = std::move(impl_);
    texture_id_ = -1;
    shared_handle_ok_ = false;
    egl_extensions_.clear();
    active_session_id_.clear();
    active_project_path_.clear();
    emitted_preview_ready_ = false;
    current_cycle_index_ = 0;
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

    // Drain the MediaPlayer: unsubscribe every event token first (so
    // no callback can fire on a half-torn impl), then Pause + Close.
    // MediaPlayer::Close() waits for the last pending callback to
    // return.
    try {
      if (dying_impl->player) {
        if (dying_impl->frame_token.value) {
          dying_impl->player.VideoFrameAvailable(dying_impl->frame_token);
        }
        if (dying_impl->media_ended_token.value) {
          dying_impl->player.MediaEnded(dying_impl->media_ended_token);
        }
        if (dying_impl->media_failed_token.value) {
          dying_impl->player.MediaFailed(dying_impl->media_failed_token);
        }
        if (dying_impl->state_changed_token.value) {
          try {
            dying_impl->player.PlaybackSession().PlaybackStateChanged(
                dying_impl->state_changed_token);
          } catch (winrt::hresult_error const&) {
            // PlaybackSession may already be torn down.
          }
        }
        dying_impl->player.Pause();
        dying_impl->player.Close();
        dying_impl->player = nullptr;
      }
    } catch (winrt::hresult_error const&) {
      // Best-effort.
    }
  }

  // Reset state-debounce tracker so the next Open starts with a
  // blank slate (next emitted state — typically "paused" during
  // Opening — will fire even though it equals what we just torn
  // down).
  last_emitted_state_.clear();
  last_frame_ms_.store(0);

  // ---- 2. Production unregister via the documented async callback.
  // FlutterDesktopTextureRegistrarUnregisterExternalTexture is
  // explicitly async; the optional callback fires from a Flutter
  // thread once the consumer side has finished with the texture.
  // We hand it a heap-allocated TearDownContext that owns the dying
  // Impl, so the Impl (and the D3D11/D2D/WinRT resources it owns)
  // outlives the round-trip. The callback `delete`s the context,
  // releasing everything.
  //
  // The earlier POC's "leak forever" was a process-exit workaround,
  // not a fundamental unregister bug: the crash was the Impl being
  // freed before Flutter's ANGLE consumer was done sampling. With
  // the TearDownContext holding the Impl alive, the documented
  // pattern works.
  if (texture_registrar_ && tex_id_to_unregister >= 0 && dying_impl) {
    // Step 5.7: copy the frames-consumed counter out of dying_impl
    // *before* moving the unique_ptr — once moved we can't read it,
    // and the OnUnregisterComplete log line needs the cycle's frame
    // count to compute the consume rate.
    const std::uint64_t frames_captured =
        static_cast<std::uint64_t>(
            dying_impl->frames_consumed.load(std::memory_order_relaxed));
    auto* teardown = new TearDownContext{};
    teardown->dying_impl = std::move(dying_impl);
    teardown->texture_id = tex_id_to_unregister;
    teardown->session_id = closing_session;
    teardown->close_qpc = NowQpc();
    teardown->qpc_frequency = QueryQpcFrequencyHz();
    teardown->cycle_index = closing_cycle_index;
    teardown->frames_consumed = frames_captured;
    LogNative("Calling FlutterDesktopTextureRegistrarUnregisterExternalTexture");
    FlutterDesktopTextureRegistrarUnregisterExternalTexture(
        texture_registrar_, tex_id_to_unregister, &OnUnregisterComplete,
        teardown);
    // dying_impl was moved into the TearDownContext; nothing more
    // for this thread to do — the callback will release everything.
  } else if (dying_impl) {
    // Defensive: if the texture_registrar_ is unexpectedly null or
    // we never got a real texture id, fall back to direct teardown
    // here. We won't be calling Flutter, so there's no async to wait
    // for. This branch should not happen in practice — Initialize
    // sets the registrar at app startup and Open only succeeds when
    // the registration returned a valid id.
    LogNative("Close() direct teardown — no Flutter registrar or texture id");
    dying_impl.reset();
  }

  // ---- 3. Write the artifact (debug-only). ----
  // Production callers (users) get a clean Close that touches the
  // disk only for the engine's own log. The Stage 2A-2 producer
  // timing report is still useful for triage but only when the
  // developer opts in by setting `CLINGFY_POC_TIMING_VERBOSE=true`
  // in the environment. dart-define values don't reach native, so
  // this is OS env var only.
  bool write_artifact = false;
  {
    wchar_t buf[16] = {};
    const DWORD n = ::GetEnvironmentVariableW(
        L"CLINGFY_POC_TIMING_VERBOSE", buf, ARRAYSIZE(buf));
    if (n > 0 && n < ARRAYSIZE(buf)) {
      // Anything other than "0" / "false" / empty is treated as true.
      const std::wstring v(buf);
      if (v != L"0" && v != L"false" && v != L"False" && v != L"FALSE") {
        write_artifact = true;
      }
    }
  }
  std::ofstream f;
  if (write_artifact) {
    f.open(kArtifactPath,
           std::ios::out | std::ios::trunc | std::ios::binary);
  }
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

    // The Flutter SchedulerBinding timings + verdict line are gone in
    // Step 5.3 because production previewClose has no Dart-side timing
    // payload (CloseArgs is just {session_id}). Step 5.4 wires real
    // Flutter timings back through the player/events channel and
    // brings the verdict line back behind a `POC_TIMING_VERBOSE`
    // dart-define. The native producer-side table above continues to
    // be the lifecycle-validation signal in the interim.
    f << "Closed session: " << closing_session << "\n";
    std::fprintf(stderr, "STAGE2A_2_ARTIFACT wrote %ls\n", kArtifactPath);
    std::fflush(stderr);
  }
}

// ---------------------------------------------------------------------
// Step 5.5 transport — Play / Pause / SeekTo.
//
// All three mirror the macOS InlinePreviewView contract: silent no-op
// on stale session_id (matches ADR gotcha #2). MediaPlayer's transport
// API is documented as safe-from-any-thread; we still hold the
// singleton mutex while reading impl_->player to avoid a race with a
// concurrent Close moving the unique_ptr away.
// ---------------------------------------------------------------------

void PreviewEngine::Play(const std::string& session_id) {
  winrt_playback::MediaPlayer player_snapshot{nullptr};
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!running_.load() || session_id != active_session_id_) {
      return;  // Stale or pre-Open call — silent no-op.
    }
    if (impl_) player_snapshot = impl_->player;
  }
  if (player_snapshot == nullptr) return;
  try {
    player_snapshot.Play();
  } catch (winrt::hresult_error const&) {
    // Best-effort. MediaPlayer errors surface separately via the
    // MediaFailed event subscription installed in Open().
  }
}

void PreviewEngine::Pause(const std::string& session_id) {
  winrt_playback::MediaPlayer player_snapshot{nullptr};
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!running_.load() || session_id != active_session_id_) {
      return;
    }
    if (impl_) player_snapshot = impl_->player;
  }
  if (player_snapshot == nullptr) return;
  try {
    player_snapshot.Pause();
  } catch (winrt::hresult_error const&) {
    // Best-effort.
  }
}

void PreviewEngine::SeekTo(const std::string& session_id,
                           std::int64_t position_ms) {
  winrt_playback::MediaPlayer player_snapshot{nullptr};
  Impl* impl_snapshot = nullptr;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!running_.load() || session_id != active_session_id_) {
      return;
    }
    if (impl_) {
      player_snapshot = impl_->player;
      impl_snapshot = impl_.get();
    }
  }
  if (player_snapshot == nullptr || impl_snapshot == nullptr) return;

  // Clamp negative positions to 0 — Dart can emit them during
  // optimistic scrubs (e.g. user drags below the timeline minimum
  // briefly). MediaPlayer accepts any TimeSpan but Position < 0 is
  // not meaningful for preview.
  if (position_ms < 0) position_ms = 0;

  // Capture call_qpc BEFORE issuing the seek so the next-frame
  // resolution measures the round-trip from "user-issued seek" to
  // "next frame produced." Append the sample under render_mutex
  // (same lock HandleVideoFrame's ResolvePendingSeeks would take).
  LARGE_INTEGER qpc{};
  ::QueryPerformanceCounter(&qpc);
  {
    std::lock_guard<std::mutex> render_lock(impl_snapshot->render_mutex);
    Impl::SeekSample sample;
    sample.target_ms = position_ms;
    sample.call_qpc = static_cast<std::int64_t>(qpc.QuadPart);
    impl_snapshot->seek_samples.push_back(sample);
  }

  try {
    // MediaPlayer.Position is deprecated since Windows 10 1607; use
    // PlaybackSession.Position. TimeSpan is 100ns ticks; build it
    // from std::chrono::milliseconds so we don't fight the WinRT
    // duration plumbing.
    player_snapshot.PlaybackSession().Position(
        std::chrono::duration_cast<winrt_foundation::TimeSpan>(
            std::chrono::milliseconds(position_ms)));
  } catch (winrt::hresult_error const&) {
    // Best-effort. MediaFailed will report deeper issues; routine
    // seek failures (e.g. past end of stream) just no-op.
  }
}

}  // namespace clingfy::preview
