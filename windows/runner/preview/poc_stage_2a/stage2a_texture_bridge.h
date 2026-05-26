// Stage 2A-1 (bridge-only) — DXGI shared-handle texture registered with
// the Flutter Windows TextureRegistrar, surfacing a Texture widget on
// the Dart side. The texture is filled with an animated solid color
// (HSV hue cycle) so live updates are visible. Real video / cursor /
// zoom composition arrives in Stage 2A-2.
//
// Singleton because flutter::MethodCall handlers in this project are
// stateless function pointers (see Bridge/method_router.h). The
// singleton is Initialized once at app startup from FlutterWindow,
// after the engine + plugin registrar exist; Start/Stop are driven by
// the POC method-channel calls from the debug-only Dart screen.

#ifndef RUNNER_PREVIEW_POC_STAGE_2A_STAGE2A_TEXTURE_BRIDGE_H_
#define RUNNER_PREVIEW_POC_STAGE_2A_STAGE2A_TEXTURE_BRIDGE_H_

#include <flutter_plugin_registrar.h>
#include <flutter_texture_registrar.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace clingfy::poc::stage2a {

struct StartResult {
  // The Flutter texture id the Dart Texture widget should mount. -1
  // when allocation or registration failed (check `error`).
  std::int64_t texture_id = -1;
  // Whether the shared NT handle was successfully created. False means
  // the GpuSurfaceTexture callback will hand Flutter a null handle and
  // the Texture widget will likely render black. Useful debugging
  // signal for Intel-iGPU driver issues.
  bool shared_handle_ok = false;
  // List of any ANGLE / EGL extension strings the bridge could read
  // out of the Flutter engine's adapter. Empty when not reachable.
  std::vector<std::string> egl_extensions;
  // Texture surface size (width / height in pixels).
  int width = 0;
  int height = 0;
  // First-frame error string, if anything failed. Empty on success.
  std::string error;
};

struct StopArgs {
  // Flutter SchedulerBinding timings, passed back from the Dart side
  // so the native artifact writer can include them in the Markdown.
  // Each pair is (median_ms, p99_ms) for a bucket. Buckets are
  // {build, raster, total}.
  double build_median_ms = 0.0;
  double build_p99_ms = 0.0;
  double raster_median_ms = 0.0;
  double raster_p99_ms = 0.0;
  double total_median_ms = 0.0;
  double total_p99_ms = 0.0;
  std::int64_t flutter_frames_observed = 0;
};

class Stage2aTextureBridge {
 public:
  // Process-wide singleton accessor used by the POC router handlers.
  static Stage2aTextureBridge* Instance();

  // Initialize against the engine's plugin registrar ref (C API).
  // Called once from FlutterWindow::OnCreate(). Safe to call multiple
  // times; only the first call wires up state.
  void Initialize(FlutterDesktopPluginRegistrarRef registrar);

  // Allocate the shared D3D11 texture + register it with the Flutter
  // TextureRegistrar. Spins up the producer thread that updates the
  // texture content. Idempotent: calling Start when already running
  // returns the same texture id.
  StartResult Start();

  // Unregister + tear down the texture + stop the producer thread.
  // Also writes `build/windows-poc/stage2a_result.md` from `args`.
  // Idempotent.
  void Stop(const StopArgs& args);

  // For tests / observability.
  std::int64_t current_texture_id() const;

 private:
  Stage2aTextureBridge() = default;
  ~Stage2aTextureBridge();
  Stage2aTextureBridge(const Stage2aTextureBridge&) = delete;
  Stage2aTextureBridge& operator=(const Stage2aTextureBridge&) = delete;

  void ProducerThreadMain();

 public:
  // Forward declaration. The actual definition lives in the .cpp at
  // file scope so the static GpuSurface callback (also at file scope)
  // can reach its members without being a class member or friend.
  // Public so the .cpp's anonymous-namespace callback can refer to it
  // by qualified name; the header surface is just the forward decl.
  struct Impl;

 private:
  std::unique_ptr<Impl> impl_;

  // Plugin registrar + texture registrar are owned by the engine and
  // outlive this singleton in practice (Stop tears the registration
  // down before the engine shuts). C API refs to avoid pulling in
  // the flutter_wrapper_plugin library (which would conflict on
  // core_implementations.cc with flutter_wrapper_app).
  FlutterDesktopPluginRegistrarRef registrar_ = nullptr;
  FlutterDesktopTextureRegistrarRef texture_registrar_ = nullptr;

  // Lifecycle state.
  std::atomic<bool> running_{false};
  std::atomic<bool> shutting_down_{false};
  std::thread producer_thread_;

  // Stats / IDs returned by Start.
  std::int64_t texture_id_ = -1;
  bool shared_handle_ok_ = false;
  int texture_width_ = 0;
  int texture_height_ = 0;
  std::vector<std::string> egl_extensions_;
  std::string last_error_;

  // Wall-clock anchor for the animation (HSV hue cycle).
  std::chrono::steady_clock::time_point start_time_;

  mutable std::mutex mutex_;
};

}  // namespace clingfy::poc::stage2a

#endif  // RUNNER_PREVIEW_POC_STAGE_2A_STAGE2A_TEXTURE_BRIDGE_H_
