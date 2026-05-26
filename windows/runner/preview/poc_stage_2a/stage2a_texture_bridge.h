// Stage 2A-2 (Phase B+) — DXGI shared-handle texture registered with the
// Flutter Windows TextureRegistrar, this time fed by a real MediaPlayer
// frame-server pipeline composed through `clingfy::preview::PreviewCompositor`.
//
// Stage 2A-1 (PR #102) proved the bridge works with a solid-color animated
// texture. Stage 2A-2 replaces the producer thread with a WinRT MediaPlayer
// subscribed to VideoFrameAvailable: each callback copies the decoded video
// onto an offscreen surface, the compositor blits it (letterboxed +
// optional cursor zoom/highlight) into the shared D3D11 texture via D2D,
// and the texture-registrar is marked for sampling. This is the exact
// shape Phase 5 production preview wants — only the wire-up to
// previewOpen/previewPlay/previewSeekTo is still missing, and that's
// deliberately out of scope until the architecture decision is signed.
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
#include <vector>

namespace clingfy::poc::stage2a {

// Inputs to Start. Both paths are wide-character because Windows file
// paths are wchars natively; the router converts UTF-8 from Dart at the
// channel boundary.
struct StartArgs {
  std::wstring video_path;   // required; empty → start fails with error
  std::wstring cursor_path;  // optional; empty → video-only (no zoom/halo)
};

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
  // Natural video size pulled from MediaPlayer after the first
  // VideoFrameAvailable. Zero until the first frame arrives — Start
  // returns before that, so callers should treat 0 as "not yet known."
  int video_width = 0;
  int video_height = 0;
  // Number of cursor events parsed from the JSONL fixture; 0 when
  // cursor_path was empty or the file parsed to no events.
  std::int64_t cursor_event_count = 0;
  // Whether cursor compositing is active (cursor_event_count > 0).
  bool cursor_mode = false;
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
  // TextureRegistrar, then start the MediaPlayer frame-server feeding
  // the compositor. Idempotent: calling Start when already running
  // returns the same texture id (but ignores the new args).
  StartResult Start(const StartArgs& args);

  // Unsubscribe from VideoFrameAvailable, tear down the MediaPlayer +
  // compositor, and write `build/windows-poc/stage2a_2_result.md`
  // from `args` plus the native producer timings collected during the
  // run. Texture stays leaked (see #102 workaround for Intel iGPU
  // shutdown crash inside Flutter's unregister path).
  void Stop(const StopArgs& args);

  // For tests / observability.
  std::int64_t current_texture_id() const;

 private:
  Stage2aTextureBridge() = default;
  ~Stage2aTextureBridge();
  Stage2aTextureBridge(const Stage2aTextureBridge&) = delete;
  Stage2aTextureBridge& operator=(const Stage2aTextureBridge&) = delete;

  // Implementation lives in the .cpp where the winrt projection
  // headers are visible. The trampoline lambda in Start() passes a
  // pointer to the `MediaPlayer const&` it received from WinRT; the
  // implementation reinterpret-casts back. Opaque `void*` keeps the
  // header free of `winrt/...` includes so router consumers don't
  // have to pull in C++/WinRT.
  void HandleVideoFrame(const void* sender_media_player_ptr);

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

  // Stats / IDs returned by Start.
  std::int64_t texture_id_ = -1;
  bool shared_handle_ok_ = false;
  int texture_width_ = 0;
  int texture_height_ = 0;
  std::vector<std::string> egl_extensions_;
  std::string last_error_;

  mutable std::mutex mutex_;
};

}  // namespace clingfy::poc::stage2a

#endif  // RUNNER_PREVIEW_POC_STAGE_2A_STAGE2A_TEXTURE_BRIDGE_H_
