// PreviewEngine — DXGI shared-handle texture registered with the Flutter
// Windows TextureRegistrar, fed by a WinRT MediaPlayer frame-server
// pipeline composed through `clingfy::preview::PreviewCompositor`.
//
// History (the empirical findings that shape this code live in PRs
// #96–#104; the architecture decision that locks them is recorded in
// `docs/decisions/windows-phase-5-preview-architecture.md`):
//
//   * Stage 2A-1 (#102) proved the legacy DXGI shared-handle bridge into
//     Flutter on Intel Iris Xe. NT shared handles + keyed mutex crash
//     ANGLE's import path; the constraints in MakeSharedTextureDesc() +
//     the "skip unregister" workaround in Close() are the result.
//   * Stage 2A-2 (#104) replaced the producer thread with a real
//     MediaPlayer + PreviewCompositor pipeline subscribed to
//     VideoFrameAvailable: each callback copies the decoded video onto
//     an offscreen surface, the compositor blits it (letterboxed +
//     optional cursor zoom/highlight) into the shared D3D11 texture via
//     D2D, and the texture-registrar is marked for sampling.
//   * Step 5.0 of Phase 5 production (this file) lifted that code out
//     of windows/runner/preview/poc_stage_2a/, renamed the type to
//     PreviewEngine, and moved it into the production preview/
//     directory. Behavior is unchanged — production previewOpen
//     semantics (sessionId, projectPath, manifest reader) arrive in
//     later steps; today the engine is still driven only through the
//     deprecated pocStage2aStart / pocStage2aStop aliases routed
//     through `Bridge/Routers/preview_router.cpp`.
//
// Singleton because flutter::MethodCall handlers in this project are
// stateless function pointers (see Bridge/method_router.h). Initialize
// is called once at app startup from FlutterWindow; Open/Close are
// driven by method-channel calls.

#ifndef RUNNER_PREVIEW_PREVIEW_ENGINE_H_
#define RUNNER_PREVIEW_PREVIEW_ENGINE_H_

#include <flutter_plugin_registrar.h>
#include <flutter_texture_registrar.h>

#include "Preview/preview_camera_renderer.h"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace clingfy::preview {

// Inputs to Open. Both file paths are wide-character because Windows
// file paths are wchars natively; the router converts UTF-8 from Dart
// at the channel boundary.
struct OpenArgs {
  // Required. The Dart-side session id that owns this preview. Used
  // to gate later Close / Play / Pause / Seek calls (calls targeting
  // a non-matching session id are silently no-op'd, matching macOS's
  // InlinePreviewView behavior). Empty session_id → open fails.
  std::string session_id;
  // Optional UTF-8 `.clingfyproj` path. Echoed back to Dart in the
  // workflow lifecycle events (`previewPreparing` / `previewReady` /
  // `previewClosed` / `previewFailed`) under the `path` key so the
  // Dart-side `_handlePreview*Event` handlers see the same payload
  // shape macOS produces. Empty is tolerated — Dart falls back to its
  // own state's previewPath in that case (Step 5.5.3).
  std::string project_path;
  std::wstring video_path;   // required; empty → open fails with error
  std::wstring cursor_path;  // optional; empty → video-only (no zoom/halo)
  // Phase 9.6: camera bubble compositing in the preview. The router sets
  // `camera_path` ONLY when the project has a usable camera (raw.mov +
  // camera.meta.json present, parsed, and previewBurnedIn == false). Empty →
  // no camera in the preview. `camera_start_offset_ms` is the camera.meta.json
  // sync key (cameraTime = playbackTime - startOffset).
  std::wstring camera_path;
  std::int64_t camera_start_offset_ms = 0;
};

struct OpenResult {
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
  // VideoFrameAvailable. Zero until the first frame arrives — Open
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

struct CloseArgs {
  // Session id that owns this Close. If the engine's active session
  // does not match (stale call from a previous session), Close is a
  // silent no-op. Mirrors the macOS contract documented in the Phase 5
  // ADR §macOS gotcha #2. Empty session_id is treated as a wildcard
  // and force-closes whatever is open — used by the singleton's
  // destructor at process exit.
  std::string session_id;
};

// Phase 9.7: seek plan for the paused-preview camera nudge. A paused
// MediaPlayer emits no frame-server callbacks, so reflecting a camera
// settings change requires a seek — but a same-position seek can be
// coalesced to a no-op, and naively seeking to current-1 on every call
// drifts the playhead 1ms further back per camera edit (a bubble drag is
// ~60 calls/sec). The plan instead alternates between an anchor (the
// position where the user actually parked the playhead) and its 1ms
// neighbor, so any number of consecutive nudges stays within 1ms of the
// anchor. Any external seek (current position no longer at the anchor or
// its neighbor) re-anchors. Pure and lock-free for unit testing; the
// engine persists anchor_ms between calls.
struct CameraNudgePlan {
  std::int64_t anchor_ms = 0;  // remember as the next call's previous anchor
  std::int64_t target_ms = 0;  // position to seek to for this nudge
};
CameraNudgePlan ResolveCameraNudgeTarget(std::int64_t current_ms,
                                         std::int64_t previous_anchor_ms);

class PreviewEngine {
 public:
  // Process-wide singleton accessor used by the bridge router handlers.
  static PreviewEngine* Instance();

  // Initialize against the engine's plugin registrar ref (C API).
  // Called once from FlutterWindow::OnCreate(). Safe to call multiple
  // times; only the first call wires up state.
  void Initialize(FlutterDesktopPluginRegistrarRef registrar);

  // Allocate the shared D3D11 texture + register it with the Flutter
  // TextureRegistrar, then start the MediaPlayer frame-server feeding
  // the compositor. Returns immediately after registration; the first
  // VideoFrameAvailable callback later fills in video_width /
  // video_height via the OpenResult's cached state.
  //
  // Re-entry behavior:
  //   * Open with the SAME session_id while already running →
  //     idempotent, returns the existing state.
  //   * Open with a DIFFERENT session_id while already running →
  //     returns error (caller must Close first). This is stricter
  //     than macOS's "queue the request" model, but Flutter has no
  //     analogous gate for us to wait on — failing loudly is safer
  //     than silently swapping inputs out from under the Dart layer.
  OpenResult Open(const OpenArgs& args);

  // Tear down the MediaPlayer + compositor and release the Flutter
  // texture via FlutterDesktopTextureRegistrarUnregisterExternalTexture
  // with the documented async-completion callback. The Impl owning
  // the shared D3D11 / D2D / WinRT resources is kept alive until
  // Flutter's callback fires, then released. This is the production
  // replacement for the POC's "leak forever" workaround — the
  // earlier crash investigation found the unregister itself works
  // when the process keeps running; the POC was crashing at process
  // exit, not on a normal Close. See the Phase 5 ADR's "Known
  // follow-ups" entry on texture unregister.
  //
  // Stale-session calls (session_id mismatches active_session_id_)
  // are silent no-ops, matching macOS gotcha #2. An empty session_id
  // is the wildcard the destructor uses at process exit.
  void Close(const CloseArgs& args);

  // ---- Step 5.5 transport ----------------------------------------
  //
  // Play / Pause / SeekTo all take a session_id. When it mismatches
  // active_session_id_ the call is a silent no-op (matches the macOS
  // InlinePreviewView contract — previewPlay / previewPause /
  // previewSeekTo with a stale session id never report an error, they
  // just don't do anything). On a matching session_id, the MediaPlayer
  // transport API is driven directly; the next playerTick / playerState
  // events from `player/events` are how Dart confirms the result.
  //
  // SeekTo additionally queues a SeekSample so the next
  // VideoFrameAvailable resolves the seek's QPC latency. The data is
  // collected unconditionally but only exposed through future telemetry
  // (Phase 5.7 multi-GPU verdict artifact) so the production fast path
  // pays nothing user-visible.
  void Play(const std::string& session_id);
  void Pause(const std::string& session_id);
  void SeekTo(const std::string& session_id, std::int64_t position_ms);

  // Phase 9.6: update the live camera-bubble composition for the inline preview
  // (visibility, placement, shape, and 9.5 styling). Driven by Dart's
  // processVideo / previewSetCameraPlacement on open and on every editor change.
  // A stale session_id (mismatching the active preview) is a silent no-op. Cheap
  // and thread-safe; the actual D2D rebuild happens on the next composited frame.
  void SetCameraComposition(const std::string& session_id,
                            const PreviewCameraComposition& composition);

  // For tests / observability.
  std::int64_t current_texture_id() const;

 private:
  PreviewEngine() = default;
  ~PreviewEngine();
  PreviewEngine(const PreviewEngine&) = delete;
  PreviewEngine& operator=(const PreviewEngine&) = delete;

  // Implementation lives in the .cpp where the winrt projection
  // headers are visible. The trampoline lambdas in Open() pass an
  // opaque `void*` to the actual winrt event-args; the implementation
  // reinterpret-casts back. Opaque `void*` keeps the header free of
  // `winrt/...` includes so router consumers don't have to pull in
  // C++/WinRT.
  void HandleVideoFrame(const void* sender_media_player_ptr);
  void HandlePlaybackStateChanged(const void* sender_playback_session_ptr);
  void HandleMediaEnded(const void* sender_media_player_ptr);
  void HandleMediaFailed(const void* sender_media_player_ptr,
                         const void* args_failed_event_args_ptr);

  // Paused heartbeat thread body. Loops until shutting_down_; while
  // running, emits a playerTick at ~10 Hz, but only when the player
  // is not actively producing frames (paused / scrubbing). When the
  // VideoFrameAvailable callback is firing, the heartbeat skips so
  // Dart doesn't see double-ticks.
  void HeartbeatLoop();

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
  // outlive this singleton in practice (Close tears the registration
  // down before the engine shuts). C API refs to avoid pulling in
  // the flutter_wrapper_plugin library (which would conflict on
  // core_implementations.cc with flutter_wrapper_app).
  FlutterDesktopPluginRegistrarRef registrar_ = nullptr;
  FlutterDesktopTextureRegistrarRef texture_registrar_ = nullptr;

  // Lifecycle state.
  std::atomic<bool> running_{false};
  std::atomic<bool> shutting_down_{false};

  // Stats / IDs returned by Open.
  std::int64_t texture_id_ = -1;
  bool shared_handle_ok_ = false;
  int texture_width_ = 0;
  int texture_height_ = 0;
  std::vector<std::string> egl_extensions_;
  std::string last_error_;

  // Session id from the active Open. Empty when no preview is open.
  // Compared against incoming Close/Play/Pause/Seek calls to enforce
  // the stale-session no-op contract.
  std::string active_session_id_;

  // Step 5.5.3: project path echoed back to Dart in the workflow
  // lifecycle events. Set in Open; cleared in Close. Empty is
  // tolerated — Dart falls back to its own state's previewPath.
  std::string active_project_path_;

  // Step 5.5.3: first-frame gate for the `previewReady` workflow
  // event. Set true the first time HandleVideoFrame emits the event;
  // reset in Open / Close. Without this gate Dart would receive a
  // `previewReady` event for every VideoFrameAvailable (~30Hz),
  // wedging the workflow state machine.
  bool emitted_preview_ready_ = false;

  // Step 5.7: monotonic open/close cycle index assigned in Open and
  // copied into TearDownContext at Close so the
  // PHASE5-OPEN / PHASE5-CYCLE log pair can be matched by the verdict
  // tool. Zero when no Open has occurred yet.
  std::int64_t current_cycle_index_ = 0;

  // Step 5.4 event-emission tracking.
  //
  // last_emitted_state_ debounces playerState so multiple
  // PlaybackStateChanged callbacks for the same logical state (which
  // MediaPlayer can fire) only produce one Dart-side event. Empty
  // means "no state has been emitted yet" — the next emit always
  // fires regardless of value.
  std::string last_emitted_state_;
  // ms-since-epoch of the most recent VideoFrameAvailable. Used by
  // the heartbeat thread to skip when the producer is already firing
  // ticks naturally. Atomic so the heartbeat can read without taking
  // the singleton mutex.
  std::atomic<std::int64_t> last_frame_ms_{0};

  // Phase 9.7: anchor for the paused-preview camera nudge (see
  // CameraNudgePlan above). -1 = no nudge has happened yet. Never reset:
  // a stale anchor is self-correcting (the plan re-anchors as soon as the
  // current position is not the anchor or its 1ms neighbor), and the
  // worst case is a single 1ms-off seek. Guarded by mutex_.
  std::int64_t camera_nudge_anchor_ms_ = -1;

  // Heartbeat thread + its lifecycle flag. Heartbeat runs while
  // running_ is true and emits a playerTick every ~100ms when the
  // producer thread hasn't ticked recently. shutting_down_ stops it.
  std::thread heartbeat_thread_;

  mutable std::mutex mutex_;
};

}  // namespace clingfy::preview

#endif  // RUNNER_PREVIEW_PREVIEW_ENGINE_H_
