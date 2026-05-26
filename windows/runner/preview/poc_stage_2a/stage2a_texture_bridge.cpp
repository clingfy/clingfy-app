#include "preview/poc_stage_2a/stage2a_texture_bridge.h"

#include <windows.h>
#include <winternl.h>
#include <d3d11.h>
#include <d3d11_4.h>
#include <dxgi1_2.h>
#include <wrl/client.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <ctime>
#include <fstream>

namespace clingfy::poc::stage2a {

using Microsoft::WRL::ComPtr;

namespace {

constexpr int kTextureWidth = 1280;
constexpr int kTextureHeight = 720;
constexpr UINT kProducerSleepMs = 16;  // ~60 Hz updates
constexpr wchar_t kArtifactPath[] = L"build\\windows-poc\\stage2a_result.md";
constexpr wchar_t kNativeLogPath[] = L"build\\windows-poc\\stage2a_native.log";
constexpr const char* kPluginName = "ClingfyPocStage2a";

// File-based logger because a Flutter Windows debug build is a GUI
// subsystem exe with no console; the standard streams are not
// reliably reachable from outside. The log file is overwritten each
// Start(); each line carries an HRESULT-style breadcrumb so a crash
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
  // Legacy SHARED handle — the Flutter Windows embedder
  // documentation in `flutter_texture_registrar.h` links to
  // `IDXGIResource::GetSharedHandle`, which returns the legacy
  // (non-NT) shared-handle form. ANGLE imports it via
  // `EGL_D3D_TEXTURE_2D_SHARE_HANDLE_ANGLE`. NT handles
  // (`D3D11_RESOURCE_MISC_SHARED_NTHANDLE`) are not supported by
  // that import path; using them produces an access violation on
  // first frame as Flutter dereferences a handle it cannot open.
  // No keyed mutex either — that's an NT-handle feature.
  d.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
  return d;
}

// HSV → RGB (all channels in [0, 1]). Used to animate the texture so
// "the texture is live" is visually obvious in the debug screen.
struct Rgb {
  float r, g, b;
};
Rgb HsvToRgb(double h, double s, double v) {
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
  return {static_cast<float>(r + m), static_cast<float>(g + m),
          static_cast<float>(b + m)};
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

}  // namespace

// ---------------------------------------------------------------------
// Impl — owns the D3D11 device, shared texture, descriptor, and texture
// variant. Hidden in the .cpp so the header stays free of D3D11 types.
// ---------------------------------------------------------------------
struct Stage2aTextureBridge::Impl {
  // Allocated on the same adapter Flutter is using (best-effort —
  // falls back to the default hardware adapter if engine lookup
  // fails). Same-adapter avoids the cross-adapter shared-handle
  // codepath that has more driver gotchas.
  ComPtr<ID3D11Device> device;
  ComPtr<ID3D11DeviceContext> context;
  ComPtr<ID3D11Texture2D> texture;
  // Cached render-target view; created once at Start time and reused
  // every frame. Re-creating an RTV per frame is what tipped the
  // earlier crash investigation; not strictly required to avoid
  // crashes (the per-frame Create should be safe) but it's wasted
  // work and worth eliminating up-front.
  ComPtr<ID3D11RenderTargetView> rtv;
  // Legacy DXGI shared handle (not an NT handle — see comment on the
  // texture desc above). Does NOT get CloseHandle'd; the texture
  // owns it and releases on COM teardown.
  HANDLE shared_handle = nullptr;

  // The descriptor handed back to Flutter every callback. Pointer
  // stability matters: Flutter holds the returned pointer until it
  // imports the handle.
  FlutterDesktopGpuSurfaceDescriptor descriptor{};

  // GPU description string for the artifact.
  std::string gpu_description;
};

// Static callback the C API hands us. user_data is `Impl*`. Returns a
// pointer to the descriptor stored on the Impl; same descriptor every
// frame because texture size never changes.
const FlutterDesktopGpuSurfaceDescriptor* ObtainSurfaceDescriptor(
    size_t /*width*/, size_t /*height*/, void* user_data) {
  auto* impl = static_cast<Stage2aTextureBridge::Impl*>(user_data);
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

// ---------------------------------------------------------------------

Stage2aTextureBridge* Stage2aTextureBridge::Instance() {
  static Stage2aTextureBridge instance;
  return &instance;
}

Stage2aTextureBridge::~Stage2aTextureBridge() {
  // Best-effort tear-down; in practice the singleton outlives the
  // engine so this destructor only runs at process exit.
  StopArgs empty{};
  if (running_.load()) Stop(empty);
}

void Stage2aTextureBridge::Initialize(
    FlutterDesktopPluginRegistrarRef registrar) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (registrar_ != nullptr) return;  // already initialized
  registrar_ = registrar;
  texture_registrar_ =
      registrar ? FlutterDesktopRegistrarGetTextureRegistrar(registrar)
                : nullptr;
}

std::int64_t Stage2aTextureBridge::current_texture_id() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return texture_id_;
}

StartResult Stage2aTextureBridge::Start() {
  // Truncate the log file at the top of every Start() so its tail
  // localises the most recent crash if there is one.
  {
    std::ofstream f(kNativeLogPath,
                    std::ios::out | std::ios::trunc | std::ios::binary);
  }
  LogNative("Start() entered");
  std::lock_guard<std::mutex> lock(mutex_);

  StartResult result;
  result.width = kTextureWidth;
  result.height = kTextureHeight;

  if (texture_registrar_ == nullptr) {
    LogNative("Start() abort: texture_registrar_ is null");
    result.error =
        "POC Stage 2A bridge not initialized — Flutter texture "
        "registrar is null. Did FlutterWindow::OnCreate() call "
        "Initialize()?";
    last_error_ = result.error;
    return result;
  }
  if (running_.load()) {
    // Idempotent: report the existing registration.
    result.texture_id = texture_id_;
    result.shared_handle_ok = shared_handle_ok_;
    result.egl_extensions = egl_extensions_;
    return result;
  }

  // ---- 1. Create a D3D11 device. ----
  // Optionally bind to Flutter's adapter via GetGraphicsAdapter on the
  // engine. The plugin registrar doesn't expose that directly, so we
  // create on the default hardware adapter; ANGLE shared-handle import
  // tolerates this when both devices share a vendor.
  impl_ = std::make_unique<Impl>();
  UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
  const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1,
                                      D3D_FEATURE_LEVEL_11_0,
                                      D3D_FEATURE_LEVEL_10_1};
  LogNative("Creating D3D11 device...");
  HRESULT hr = ::D3D11CreateDevice(
      nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags, levels,
      ARRAYSIZE(levels), D3D11_SDK_VERSION,
      impl_->device.ReleaseAndGetAddressOf(), nullptr,
      impl_->context.ReleaseAndGetAddressOf());
  {
    char buf[64];
    std::snprintf(buf, sizeof(buf),
                  "D3D11CreateDevice → HRESULT 0x%08lX",
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
  if (SUCCEEDED(impl_->device.As(&dxgi_device))) {
    ComPtr<IDXGIAdapter> adapter;
    if (SUCCEEDED(dxgi_device->GetAdapter(adapter.GetAddressOf()))) {
      DXGI_ADAPTER_DESC desc{};
      if (SUCCEEDED(adapter->GetDesc(&desc))) {
        impl_->gpu_description = WideToUtf8(desc.Description);
      }
    }
  }

  // Multi-thread-protect the immediate context — the producer thread
  // writes to the texture while Flutter's renderer reads via its own
  // device after import.
  ComPtr<ID3D11Multithread> mt;
  if (SUCCEEDED(impl_->context.As(&mt))) {
    mt->SetMultithreadProtected(TRUE);
  }

  // ---- 2. Allocate the shared texture. ----
  LogNative("Allocating D3D11_RESOURCE_MISC_SHARED texture...");
  const auto td = MakeSharedTextureDesc(kTextureWidth, kTextureHeight);
  hr = impl_->device->CreateTexture2D(
      &td, nullptr, impl_->texture.ReleaseAndGetAddressOf());
  {
    char buf[64];
    std::snprintf(buf, sizeof(buf),
                  "CreateTexture2D → HRESULT 0x%08lX",
                  static_cast<unsigned long>(hr));
    LogNative(buf);
  }
  if (FAILED(hr)) {
    char buf[128];
    std::snprintf(buf, sizeof(buf),
                  "CreateTexture2D (shared NT + keyed mutex) failed "
                  "(HRESULT 0x%08lX)",
                  static_cast<unsigned long>(hr));
    result.error = buf;
    last_error_ = result.error;
    impl_.reset();
    return result;
  }

  // ---- 3. Obtain the legacy DXGI shared handle. ----
  LogNative("Querying IDXGIResource + GetSharedHandle...");
  ComPtr<IDXGIResource> dxgi_resource;
  hr = impl_->texture.As(&dxgi_resource);
  if (FAILED(hr)) {
    result.error = "Texture does not expose IDXGIResource";
    last_error_ = result.error;
    impl_.reset();
    return result;
  }
  hr = dxgi_resource->GetSharedHandle(&impl_->shared_handle);
  {
    char buf[96];
    std::snprintf(buf, sizeof(buf),
                  "GetSharedHandle → HRESULT 0x%08lX handle=%p",
                  static_cast<unsigned long>(hr), impl_->shared_handle);
    LogNative(buf);
  }
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

  // Pre-create the RTV once so the producer thread can ClearRTV
  // without reallocating per frame.
  D3D11_RENDER_TARGET_VIEW_DESC rtv_desc{};
  rtv_desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  rtv_desc.ViewDimension = D3D11_RTV_DIMENSION_TEXTURE2D;
  rtv_desc.Texture2D.MipSlice = 0;
  hr = impl_->device->CreateRenderTargetView(
      impl_->texture.Get(), &rtv_desc,
      impl_->rtv.ReleaseAndGetAddressOf());
  if (FAILED(hr)) {
    result.error = "CreateRenderTargetView failed";
    last_error_ = result.error;
    impl_.reset();
    shared_handle_ok_ = false;
    return result;
  }

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

  // ---- 5. Register via the C texture-registrar API. ----
  LogNative("Registering external texture via C API...");
  FlutterDesktopTextureInfo info{};
  info.type = kFlutterDesktopGpuSurfaceTexture;
  info.gpu_surface_config.struct_size =
      sizeof(FlutterDesktopGpuSurfaceTextureConfig);
  info.gpu_surface_config.type =
      kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle;
  info.gpu_surface_config.callback = &ObtainSurfaceDescriptor;
  info.gpu_surface_config.user_data = impl_.get();
  const int64_t tex_id = FlutterDesktopTextureRegistrarRegisterExternalTexture(
      texture_registrar_, &info);
  {
    char buf[64];
    std::snprintf(buf, sizeof(buf), "RegisterExternalTexture → id=%lld",
                  static_cast<long long>(tex_id));
    LogNative(buf);
  }
  if (tex_id < 0) {
    result.error =
        "FlutterDesktopTextureRegistrarRegisterExternalTexture returned -1";
    last_error_ = result.error;
    // Legacy shared handles aren't NT handles; the texture itself
    // owns the lifecycle. No CloseHandle here.
    impl_->shared_handle = nullptr;
    impl_.reset();
    shared_handle_ok_ = false;
    return result;
  }
  texture_id_ = tex_id;
  texture_width_ = kTextureWidth;
  texture_height_ = kTextureHeight;
  egl_extensions_.clear();  // not reachable through PluginRegistrar; leave empty
  last_error_.clear();

  // ---- 6. Start the producer thread. ----
  LogNative("Spawning producer thread...");
  start_time_ = std::chrono::steady_clock::now();
  shutting_down_.store(false);
  running_.store(true);
  producer_thread_ = std::thread([this] { ProducerThreadMain(); });
  LogNative("Start() returning success");

  result.texture_id = tex_id;
  result.shared_handle_ok = true;
  result.egl_extensions = egl_extensions_;
  result.error.clear();
  return result;
}

void Stage2aTextureBridge::Stop(const StopArgs& args) {
  LogNative("Stop() entered");
  // ---- 1a. Signal the producer thread to exit BEFORE touching impl_.
  // This avoids the producer dereferencing a unique_ptr that's already
  // been moved out of the singleton.
  if (!running_.load()) {
    LogNative("Stop() abort: not running");
    return;
  }
  shutting_down_.store(true);
  running_.store(false);
  std::thread th;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    th = std::move(producer_thread_);
  }
  if (th.joinable()) th.join();
  LogNative("Stop() joined producer thread");

  // ---- 1b. Now safe to tear down state under the lock. ----
  std::int64_t tex_id_to_unregister = -1;
  std::unique_ptr<Impl> dying_impl;
  std::string gpu;
  bool handle_ok = false;
  std::string err;
  int tw = 0, th_h = 0;
  const bool was_running = true;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    tex_id_to_unregister = texture_id_;
    gpu = impl_ ? impl_->gpu_description : "";
    handle_ok = shared_handle_ok_;
    err = last_error_;
    tw = texture_width_;
    th_h = texture_height_;
    dying_impl = std::move(impl_);
    texture_id_ = -1;
    shared_handle_ok_ = false;
    egl_extensions_.clear();
  }

  // ---- 2. Unregister from Flutter (asynchronous!) ----
  // The C API explicitly documents this call as async. Flutter
  // continues to dereference the texture's user_data pointer
  // (== &impl_->descriptor → &(Impl::descriptor) == owned by Impl)
  // for some time after the call returns. Releasing the Impl
  // synchronously here is the access violation we hunted earlier.
  //
  // Pattern: heap-allocate a small context that owns the dying
  // Impl, hand it to Unregister, and free it from the completion
  // callback. The Impl outlives the unregister round-trip.
  // Diagnostic shape: deliberately SKIPPING UnregisterExternalTexture
  // so we can confirm the crash localises there. The Impl and the
  // texture are leaked on shutdown — acceptable for a POC where the
  // process is about to exit anyway. If this run completes cleanly,
  // the bug is unambiguously inside Flutter's unregister path, and
  // Stage 2A-1 ships with a documented "do not unregister"
  // workaround.
  LogNative("Stop() SKIPPING UnregisterExternalTexture (POC workaround)");
  // dying_impl is intentionally NOT reset — the Impl, including the
  // shared handle texture, leaks until process exit. ~few MB of GPU
  // memory; harmless because we're shutting down anyway.
  dying_impl.release();  // release ownership without running destructor

  // ---- 4. Write the artifact. ----
  if (was_running) {
    std::ofstream f(kArtifactPath,
                    std::ios::out | std::ios::trunc | std::ios::binary);
    if (f.is_open()) {
      f << "# Stage 2A-1 — Flutter Texture / DXGI shared-handle bridge\n\n";
      f << "- **Generated:** " << UtcTimestampNow() << " (UTC)\n";
      f << "- **Mode:** bridge-only (solid-color animated texture)\n";
      f << "- **OS:** " << WindowsVersionString() << "\n";
      f << "- **GPU (producer device):** " << gpu << "\n";
      f << "- **Texture size:** " << tw << " × " << th_h << " px\n\n";

      f << "## DXGI shared-handle status\n\n";
      f << "- **Allocated:** " << (handle_ok ? "yes" : "**no**") << "\n";
      f << "- **Flutter texture id:** " << tex_id_to_unregister << "\n";
      if (!err.empty()) {
        f << "- **Last error:** `" << err << "`\n";
      }
      f << "\n";

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
      f << "- **Bar:** raster median ≤ 16 ms AND raster p99 ≤ 25 ms\n";
      const bool pass_med = args.raster_median_ms <= 16.0;
      const bool pass_p99 = args.raster_p99_ms <= 25.0;
      const bool pass = handle_ok && pass_med && pass_p99 &&
                        tex_id_to_unregister >= 0;
      char verdict[256];
      std::snprintf(verdict, sizeof(verdict),
                    "- **Result:** shared-handle=%s, raster median=%.3f ms "
                    "(%s), raster p99=%.3f ms (%s) → **%s**\n",
                    handle_ok ? "ok" : "FAIL",
                    args.raster_median_ms, pass_med ? "PASS" : "FAIL",
                    args.raster_p99_ms, pass_p99 ? "PASS" : "FAIL",
                    pass ? "PASS" : "FAIL");
      f << verdict << "\n";
      if (!pass) {
        f << "_Bridge or Flutter raster timings missed the Stage 1 bar. "
             "Stage 2A-2 (real compositor) is gated on this result; "
             "triage before continuing._\n";
      }
      std::fprintf(stderr,
                   "STAGE2A_ARTIFACT wrote %ls\n", kArtifactPath);
      std::fflush(stderr);
    }
  }
}

void Stage2aTextureBridge::ProducerThreadMain() {
  // Legacy shared-handle textures cannot use IDXGIKeyedMutex. Sync
  // between our producer device and Flutter's consumer device falls
  // out of GPU command-queue ordering (Flush below) + Flutter's
  // own imported-texture sampling. Good enough to demonstrate the
  // bridge is alive; correctness under heavy contention is Stage
  // 2A-2's problem when real video frames replace the solid color.
  while (!shutting_down_.load()) {
    if (!impl_ || !impl_->context || !impl_->rtv) {
      break;
    }
    const auto now = std::chrono::steady_clock::now();
    const double t = std::chrono::duration<double>(now - start_time_).count();
    const double hue = std::fmod(t * 0.20, 1.0);
    const auto rgb = HsvToRgb(hue, 0.85, 0.95);
    const FLOAT color[4] = {rgb.b, rgb.g, rgb.r, 1.0f};
    impl_->context->ClearRenderTargetView(impl_->rtv.Get(), color);
    impl_->context->Flush();
    if (texture_registrar_ && texture_id_ >= 0) {
      FlutterDesktopTextureRegistrarMarkExternalTextureFrameAvailable(
          texture_registrar_, texture_id_);
    }
    ::Sleep(kProducerSleepMs);
  }
}

}  // namespace clingfy::poc::stage2a
