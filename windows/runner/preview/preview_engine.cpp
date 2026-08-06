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
#include <atomic>
#include <cctype>
#include <filesystem>
#include <fstream>
#include <limits>
#include <system_error>
#include <thread>

#include "Bridge/native_error_codes.h"
#include "Bridge/native_log_publisher.h"
#include "Bridge/platform_thread_dispatcher.h"
#include "Bridge/player_event_publisher.h"
#include "Bridge/workflow_event_publisher.h"
#include "Capture/Background/background_image_cache.h"
#include "Capture/Background/preset_bitmap_cache.h"
#include "Capture/Export/export_geometry.h"
#include "Capture/Export/audio_sidecar_probe.h"
#include "Capture/Export/mic_cleanup.h"
#include "Services/log_locations.h"
#include "preview/frame_timing.h"
#include "preview/preview_audio_renderer.h"
#include "preview/preview_compositor.h"
#include "preview/preview_source_reader.h"

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

// The stress-harness measurement artifacts stay in
// %LOCALAPPDATA%\Clingfy\Logs (see Services/log_locations.h) — they are
// benchmark outputs consumed by tools/phase5_*.ps1, not logging:
//   * phase5_cycles.log — append-only across the process lifetime;
//     truncation would defeat the stress verdict tool, which needs
//     cross-cycle history to compute aggregate stats.
//   * stage2a_2_result.md — the Stage 2A-2 verdict artifact.
// (The old stage2a_2_native.log breadcrumb file is gone: LogNative now
// forwards into the unified log pipeline instead.)
std::wstring NativeLogFilePath(const wchar_t* file_name) {
  const std::wstring dir = clingfy::storage::NativeLogsDirectory();
  if (dir.empty()) {
    return {};
  }
  return dir + L"\\" + file_name;
}

std::wstring ArtifactPath() {
  return NativeLogFilePath(L"stage2a_2_result.md");
}
std::wstring Phase5CycleLogPath() {
  return NativeLogFilePath(L"phase5_cycles.log");
}

void EnsureLogParentDir() {
  // Create the resolved logs dir if it doesn't exist yet — on a fresh
  // profile it is missing, which would otherwise cause `std::ofstream`
  // to fail silently and the stress verdict tool to find nothing.
  const std::wstring dir = clingfy::storage::NativeLogsDirectory();
  if (dir.empty()) {
    return;
  }
  std::error_code ec;
  std::filesystem::create_directories(dir, ec);
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

// Preview-engine lifecycle breadcrumbs (Open/Close aborts, D3D device
// creation, texture registration). Forwards into the unified log pipeline
// as DEBUG "Preview" lines — the Settings "verbose logging" toggle (or
// CLINGFY_LOG_LEVEL=debug for the stress harness) turns them on. Failures
// that matter in release are dual-logged at ERROR by their call sites.
void LogNative(const char* msg) {
  if (msg == nullptr) {
    return;
  }
  clingfy::bridge::NativeLogPublisher::Instance().Debug("Preview", msg);
}

// Step 5.7.1: append-only cycle measurements for the stress verdict tool
// (tools/phase5_extract_verdict.ps1) — a harness data artifact, deliberately
// NOT part of the unified log pipeline: the tool needs a stable key=value
// file it can aggregate across cycles, independent of log levels.
void LogPhase5Cycle(const char* msg) {
  const std::wstring log_path = Phase5CycleLogPath();
  if (log_path.empty()) {
    return;
  }
  EnsureLogParentDir();
  std::ofstream f(std::filesystem::path(log_path),
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

  // ---- Phase 9.6 camera bubble (null when the project has no usable camera).
  std::unique_ptr<clingfy::preview::PreviewCameraRenderer> camera_renderer;

  // ---- Stats ----
  clingfy::preview::FrameTimingCollector timing_total;   // whole VideoFrameAvailable handler
  clingfy::preview::FrameTimingCollector timing_copy;    // CopyFrameToVideoSurface
  clingfy::preview::FrameTimingCollector timing_render;  // BeginDraw → EndDraw
  clingfy::preview::FrameTimingCollector timing_handoff; // Flush + MarkExternalTextureFrameAvailable
  std::atomic<std::uint64_t> dropped_frames{0};
  // Phase 10.4: consecutive per-frame failures (EnsureResources / copy /
  // EndDraw). Reset to 0 by every successful frame; when it crosses the
  // threshold the engine emits PREVIEW_RENDER_ERROR once (see
  // NoteRenderFailure).
  std::atomic<std::uint32_t> consecutive_render_failures{0};
  // The HRESULT of the most recent per-frame failure, folded into the
  // PREVIEW_RENDER_ERROR log line. Discriminates device loss (Modern Standby
  // resume / TDR — DXGI_ERROR_DEVICE_REMOVED) from out-of-memory; a 55-min
  // session's frame_copy death was undiagnosable without it.
  std::atomic<std::int32_t> last_render_failure_hr{0};

  // ---- Discovered after the first frame ----
  std::atomic<UINT> last_video_width{0};
  std::atomic<UINT> last_video_height{0};
  std::atomic<std::int64_t> frames_consumed{0};

  // Decoded background image, keyed by path + mtime. Lives next to the canvas
  // state it serves; dropped on device loss with the rest of the D2D resources.
  capture::background::BackgroundImageCache background_images;
  // Rendered preset pixels — disposable, regenerated from the preset data.
  capture::background::PresetBitmapCache preset_bitmaps;

  // ---- Canvas framing (render_mutex) ----
  // Resolution-independent, so the same authored padding renders proportionally
  // the same here as it does in the export (see Core/canvas_composition.h).
  // Written by SetCanvasComposition on the platform thread, read by the frame
  // thread while compositing.
  core::CanvasComposition canvas{};

  // ---- Last composed frame's timeline position (render_mutex) ----
  // Replayed verbatim by RepaintRetainedFrame so a settings change on a PAUSED
  // preview re-composites the frame that is already on screen: same timestamp,
  // so cursor / zoom / camera resolve identically and only the edited setting
  // moves. Also keeps the re-emitted playerTick from nudging Dart's playhead.
  std::int64_t last_playback_us = -1;
  std::int64_t last_emit_pos_ms = 0;
  std::int64_t last_emit_dur_ms = 0;

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

  // ---- Editing port (clips, step 4-1/4-3) ----
  // The edited-timeline kept ranges (TIMELINE order) set via SetClips. Empty /
  // passthrough = no cuts, so the preview plays the source 1:1 as today. Guarded
  // by render_mutex (4-3b: the pacer thread reads it off the platform thread, so
  // the SetClips write MUST share render_mutex with those reads).
  std::vector<capture::export_::clip_planner::ClipKeptRange> clip_ranges;
  // Step 4-3 stitched-preview state (guarded by render_mutex — touched by the
  // edited render path and read by the frame-server guard). When the ranges are
  // a real edit the MediaPlayer is paused and frames come from `edited_reader`
  // instead; `edited_pos_ms` is the current edited-timeline position (the
  // paused / scrubbed frame). Continuous playback (a pacer) lands in 4-3b.
  std::unique_ptr<PreviewSourceReader> edited_reader;
  bool edited_mode = false;
  std::int64_t edited_pos_ms = 0;
  // Step 4-3b: continuous-playback flag for the pacer thread. Set true by Play
  // on an edited session, cleared by Pause / passthrough / EOS. Guarded by
  // render_mutex (set on the platform thread, read by the pacer thread).
  bool edited_playing = false;
  // Step 4-4: reorder-playback state (render_mutex). When the ranges are NOT
  // source-monotonic the pacer reads each range's source window in TIMELINE
  // order via per-range backward seeks (like the export reorder path); these
  // track the current timeline range + the cumulative edited-ms of the earlier
  // ranges. Primed by Play / SeekTo from edited_pos_ms; unused for the monotonic
  // (forward-decode) path.
  int edited_range_idx = 0;
  std::int64_t edited_reorder_base_ms = 0;
  // Monotonic gap-seek lead-in floor (render_mutex): after the pacer SEEKS
  // across a large cut gap, MF resumes at the PRIOR keyframe — which can sit
  // in the pre-gap KEPT region, and re-emitting one of those frames would
  // snap the playhead backward. Frames with ts below this floor are
  // discarded. Every transport reposition resets it
  // (RenderEditedFrameLocked seeks and sets it to its target).
  std::int64_t edited_min_source_ms = 0;
  // Zero-decode-margin chase state (render_mutex) — see DecidePacerChase
  // for the policy these feed. `stale_streak` counts consecutive stale
  // discards (decimation); `last_chase_seek` spaces repositions;
  // `awaiting_chase_frame` makes the first frame after a reposition emit
  // unconditionally, so a long keyframe lead-in can't trigger another
  // chase and starve the picture forever. All three reset on any transport
  // reposition (RenderEditedFrameLocked).
  int stale_streak = 0;
  std::chrono::steady_clock::time_point last_chase_seek{};
  bool awaiting_chase_frame = false;
  // Adaptive frame budget (atomic — the pacer reads it outside
  // render_mutex, before sleeping). Measured from the edited-time delta
  // between presented frames, so a 60 fps recording paces at ~16 ms
  // instead of the historical fixed 33 ms (which played such sources at
  // half speed). Seeded at 33 ms and clamped to a sane range so a cut
  // boundary or a decode hiccup can't produce a runaway budget.
  std::atomic<int> paced_budget_ms{33};
  std::int64_t last_presented_edited_ms = -1;

  // Step 4-7c: the edited-session sound output (design D1/D5/D7). Created on
  // the stitched-mode transition in SetClips, reset on the passthrough
  // transition and in Close (explicitly, before impl teardown). Guarded by
  // render_mutex like the rest of the edited state; the renderer's own API
  // is thread-safe and its PositionEditedMs() read is lock-free, so the
  // pacer may consult it every step. nullptr = this session has no audio
  // (no track / no endpoint / renderer failed) — silent-video preview (D7).
  std::unique_ptr<PreviewAudioRenderer> audio_renderer;
  // One WARN per session when the renderer could not be built (D7): the
  // fallback is deliberate, but a beta log must say why a preview is silent.
  bool audio_open_failure_logged = false;
  // D7 mid-stream failure hand-off: the renderer's one-shot error callback
  // fires on ITS render thread, which must not act inline or touch engine
  // locks — it only records here. The platform-thread handlers (Play /
  // SetClips, already under render_mutex) consume the flag and perform the
  // one WARN + one rebuild attempt (HandleAudioRenderErrorLocked).
  std::atomic<bool> audio_render_error_pending{false};
  std::atomic<std::int32_t> audio_render_error_hr{0};
  // One rebuild per session (D7): a second failure degrades to logged
  // silent video.
  bool audio_rebuild_attempted = false;
  // 4-7d: the session's live mix (render_mutex). Defaults are the identity
  // values; SetAudioMix stores clamped values and pushes resolved stages to
  // the renderer; a renderer opened later starts from these (the macOS
  // pending-open override semantics).
  double audio_gain_db = 0.0;
  double audio_volume_percent = 100.0;
  // Audio separation (D9): the PROBED-decodable sidecar paths (empty when
  // absent or undecodable) and whether this session's edited audio runs
  // separated. Probed ONCE at Open; immutable afterwards, so the error-
  // rebuild path reopens the same mode without re-probing.
  std::wstring mic_audio_path;
  std::wstring system_audio_path;
  bool audio_separated = false;

  // Voice cleanup (Phase 4 preview WYSIWYG, render_mutex-guarded except the
  // cancel atomic). `enabled` is the user's toggle; `use_cleaned_mic` gates
  // OpenPreviewAudioRendererLocked onto `cleaned_mic_path` once the background
  // RNNoise pass has produced it (`cleaned_mic_ready`). `computing` guards a
  // single in-flight worker; `cleanup_thread` is joined (after signalling
  // `cleanup_cancel`) at Close so a long denoise never outlives the session.
  bool voice_cleanup_enabled = false;
  // The requested strength (VoiceCleanupWetMix) and the strength the cached
  // cleaned file was actually produced with — a mode change (light<->balanced)
  // makes them differ, which invalidates the cache and re-runs the worker.
  float voice_cleanup_wet_mix = 1.0f;
  float cleaned_wet_mix = -1.0f;
  // Bumped per spawned worker; the completion applies only its own generation,
  // so a superseded worker (mode toggled again mid-compute) can't touch the
  // live one's state or temp file even when the two share a strength value.
  std::uint64_t voice_cleanup_generation = 0;
  bool voice_cleanup_computing = false;
  bool cleaned_mic_ready = false;
  bool use_cleaned_mic = false;
  std::wstring cleaned_mic_path;
  std::thread cleanup_thread;
  std::atomic<bool> cleanup_cancel{false};

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

// ---- Step 4-7c: edited-preview audio helpers (all callers hold render_mutex
// ---- on the platform thread — the engine's serialized transport paths) -----

// The audio extent passed to AudioSlots is the ranges' own upper bound — a
// shorter real track just early-EOSes in the pump, which silence-fills the
// shortfall (§5.2), so no MediaPlayer duration query is needed.
std::vector<capture::export_::clip_planner::AudioSlot> BuildPreviewAudioSlots(
    const std::vector<capture::export_::clip_planner::ClipKeptRange>& ranges) {
  std::int64_t audio_extent_ms = 0;
  for (const auto& r : ranges) {
    audio_extent_ms = std::max(audio_extent_ms, r.source_out_ms);
  }
  return capture::export_::clip_planner::AudioSlots(ranges, audio_extent_ms);
}

// Open the renderer for the current ranges and wire the mid-stream failure
// hook (D7). The callback fires on the RENDERER's thread: record-only — the
// raw Impl* capture is safe because every audio_renderer.reset() (rebuild,
// passthrough transition, Close) joins the renderer thread first, so the
// callback can never outlive `impl`.
void OpenPreviewAudioRendererLocked(PreviewEngine::Impl* impl) {
  const auto slots = BuildPreviewAudioSlots(impl->clip_ranges);
  // Audio separation (D9): a session whose sidecars passed the Open-time
  // decode probe goes dual-pump (mic-only gain); everything else keeps the
  // premix whole-track path. No cross-fallback — a probed sidecar that
  // fails here failed on device/endpoint grounds the premix shares.
  // Voice cleanup: play the RNNoise-cleaned mic when the background pass has
  // produced it and the toggle is on; otherwise the raw sidecar. The system
  // track is never cleaned (voice cleanup targets the mic alone).
  const std::wstring& mic_for_renderer =
      (impl->use_cleaned_mic && !impl->cleaned_mic_path.empty())
          ? impl->cleaned_mic_path
          : impl->mic_audio_path;
  impl->audio_renderer =
      impl->audio_separated
          ? PreviewAudioRenderer::OpenSeparated(mic_for_renderer,
                                                impl->system_audio_path, slots)
          : PreviewAudioRenderer::Open(impl->video_path, slots);
  if (impl->audio_renderer == nullptr) {
    if (!impl->audio_open_failure_logged) {
      impl->audio_open_failure_logged = true;
      clingfy::bridge::NativeLogPublisher::Instance().Warn(
          "Preview",
          "edited-preview audio unavailable (no audio track, no output "
          "device, or an incompatible endpoint format) — the stitched "
          "preview stays silent video");
    }
    return;
  }
  impl->audio_renderer->SetOnRenderError([impl](HRESULT hr) {
    impl->audio_render_error_hr.store(static_cast<std::int32_t>(hr),
                                      std::memory_order_relaxed);
    impl->audio_render_error_pending.store(true, std::memory_order_release);
  });
  // 4-7d: a renderer opened after the mix was set starts from the stored
  // values (macOS pending-open override semantics). Identity defaults
  // resolve to identity stages — a no-op. Normalize stays export-only on
  // both platforms, so the separated resolver never sees a peak here.
  if (impl->audio_separated) {
    impl->audio_renderer->SetSeparatedGainStages(
        capture::export_::ResolveSeparatedAudioStages(
            impl->audio_gain_db, impl->audio_volume_percent,
            /*normalize=*/false, /*target_loudness_dbfs=*/-16.0,
            /*mic_peak_linear=*/0.0));
  } else {
    impl->audio_renderer->SetGainStages(
        capture::export_::ResolveAudioGainStages(
            impl->audio_gain_db, impl->audio_volume_percent,
            /*normalize=*/false, /*target_loudness_dbfs=*/-16.0,
            /*source_peak_linear=*/0.0));
  }
}

// Rebuild the audio renderer in place for the current mic selection (voice
// cleanup swaps between the raw and RNNoise-cleaned mic). If the session was
// playing, resume audio at the current edited position so the master clock —
// and the video pacer that chases it — keeps running across the swap instead
// of stalling on a reset renderer.
void RebuildPreviewAudioRendererLocked(PreviewEngine::Impl* impl) {
  impl->audio_renderer.reset();
  OpenPreviewAudioRendererLocked(impl);
  if (impl->edited_playing && impl->audio_renderer != nullptr) {
    impl->audio_renderer->Play(impl->edited_pos_ms);
  }
}

// Per-session, per-GENERATION temp path for the RNNoise-cleaned preview mic.
// Session-scoped so concurrent sessions never collide; the generation makes it
// unique per worker, so a superseded worker never shares a path with the live
// one (two same-strength workers would otherwise collide). `.mp4` so MF picks
// the MPEG-4 container.
std::filesystem::path PreviewCleanedMicPath(const std::string& session_id,
                                            std::uint64_t generation) {
  std::string name = "clingfy-preview-miccleanup-";
  for (const char c : session_id) {
    name += std::isalnum(static_cast<unsigned char>(c)) ? c : '_';
  }
  name += "-g" + std::to_string(generation) + ".mp4";
  return std::filesystem::temp_directory_path() / name;
}

// D7 mid-stream failure recovery: one WARN naming the HRESULT, ONE rebuild
// attempt (a fresh renderer re-Activates the default endpoint — the only way
// back from AUDCLNT_E_DEVICE_INVALIDATED, e.g. a headset unplug or standby
// resume), then logged silent-video degradation. Consumed on the platform
// thread before Play/SetClips act on the renderer.
void HandleAudioRenderErrorLocked(PreviewEngine::Impl* impl) {
  if (!impl->audio_render_error_pending.exchange(false,
                                                 std::memory_order_acquire)) {
    return;
  }
  char detail[48];
  std::snprintf(detail, sizeof(detail), " (hr=0x%08lX)",
                static_cast<unsigned long>(static_cast<HRESULT>(
                    impl->audio_render_error_hr.load(
                        std::memory_order_relaxed))));
  if (!impl->audio_rebuild_attempted) {
    impl->audio_rebuild_attempted = true;
    clingfy::bridge::NativeLogPublisher::Instance().Warn(
        "Preview", std::string("edited-preview audio device lost") + detail +
                       " — rebuilding the renderer once");
    impl->audio_renderer.reset();
    OpenPreviewAudioRendererLocked(impl);
    if (impl->audio_renderer == nullptr) {
      clingfy::bridge::NativeLogPublisher::Instance().Warn(
          "Preview",
          "edited-preview audio rebuild failed — silent video for this "
          "session");
    }
    return;
  }
  clingfy::bridge::NativeLogPublisher::Instance().Warn(
      "Preview", std::string("edited-preview audio failed again") + detail +
                     " — silent video for this session");
  impl->audio_renderer.reset();
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

bool PreviewEngine::ShouldReconcileStaleSession(
    bool running, const std::string& active_session_id,
    const std::string& incoming_session_id) {
  return running && !incoming_session_id.empty() &&
         active_session_id != incoming_session_id;
}

bool PreviewEngine::ShouldInvalidateOnSystemResume(
    bool running, const std::string& active_session_id) {
  return running && !active_session_id.empty();
}

PreviewEngine::TextureSize PreviewEngine::ComputePreviewTextureSize(
    int video_width_hint, int video_height_hint) {
  if (video_width_hint <= 0 || video_height_hint <= 0) {
    return {kTextureWidth, kTextureHeight};
  }
  const double aspect =
      static_cast<double>(video_width_hint) / video_height_hint;
  int w = kTextureWidth;
  int h = static_cast<int>(kTextureWidth / aspect);
  if (h > kTextureHeight) {
    h = kTextureHeight;
    w = static_cast<int>(kTextureHeight * aspect);
  }
  // Even-align (keeps any half-resolution math downstream sane); floor so a
  // degenerate hint can never produce a zero-sized texture.
  w &= ~1;
  h &= ~1;
  w = std::max(w, 16);
  h = std::max(h, 16);
  return {w, h};
}

PreviewEngine::TextureSize PreviewEngine::ComputeCanvasTextureSize(
    int video_width_hint, int video_height_hint,
    const std::string& layout_preset, const std::string& resolution_preset) {
  // No usable source: nothing to derive a canvas from, so keep the budget.
  if (video_width_hint <= 0 || video_height_hint <= 0) {
    return {kTextureWidth, kTextureHeight};
  }
  // No presets yet (previewOpen before Dart has pushed canvas state): behave
  // exactly as the video-aspect sizing did, so this is a no-op until the
  // presets are known.
  if (layout_preset.empty() && resolution_preset.empty()) {
    return ComputePreviewTextureSize(video_width_hint, video_height_hint);
  }

  const capture::export_::SizeF target = capture::export_::ResolveTargetSize(
      capture::export_::SizeF{static_cast<double>(video_width_hint),
                              static_cast<double>(video_height_hint)},
      layout_preset, resolution_preset);
  if (!(target.width > 0.0) || !(target.height > 0.0)) {
    return ComputePreviewTextureSize(video_width_hint, video_height_hint);
  }

  // Only the ASPECT matters: the texture stays inside the 1280x720 budget no
  // matter which export resolution the user picked, and the canvas contract
  // carries padding/radius as fractions so they scale to whatever size lands
  // here.
  return ComputePreviewTextureSize(static_cast<int>(std::lround(target.width)),
                                   static_cast<int>(std::lround(target.height)));
}

bool PreviewEngine::DecideCanvasAspectRebuild(
    int source_width, int source_height, int current_texture_width,
    int current_texture_height, const std::string& layout_preset,
    const std::string& resolution_preset) {
  // Nothing to compare against, or nothing to compute from. Both cases mean
  // "we cannot know", and the safe answer to that is never to rebuild — see
  // the loop guard in the header.
  if (source_width <= 0 || source_height <= 0 || current_texture_width <= 0 ||
      current_texture_height <= 0) {
    return false;
  }
  const TextureSize required = ComputeCanvasTextureSize(
      source_width, source_height, layout_preset, resolution_preset);
  return required.width != current_texture_width ||
         required.height != current_texture_height;
}

bool PreviewEngine::ShouldRestartEditedPlaybackFromEnd(
    std::int64_t edited_pos_ms, std::int64_t edited_duration_ms) {
  // One-frame tolerance: the pacer stamps the LAST kept frame's edited time,
  // which lands up to a frame short of the exact duration.
  constexpr std::int64_t kToleranceMs = 40;
  return edited_duration_ms > 0 &&
         edited_pos_ms >= edited_duration_ms - kToleranceMs;
}

void PreviewEngine::OnSystemResumed() {
  // Snapshot-then-release, same rule as Open()'s reconcile block: never
  // publish (or do anything else that can re-enter the engine) while
  // holding mutex_.
  std::string session_snapshot;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (shutting_down_.load() ||
        !ShouldInvalidateOnSystemResume(running_.load(),
                                        active_session_id_)) {
      return;
    }
    session_snapshot = active_session_id_;
    // Disarm the render loop's own reporter for this session: post-resume
    // the frame server keeps failing every frame on the removed device, and
    // ~90 failures (~1.5-3 s) later NoteRenderFailure would emit a loud
    // PREVIEW_RENDER_ERROR + previewFailed for the very session Dart is
    // silently rebuilding — the previewFailed handler then tears the phase
    // down mid-rebuild and the user sees a blocking error instead of a
    // silent recovery. Open() re-arms the latch for the rebuilt session, so
    // the loud path stays available after recovery.
    render_error_emitted_ = true;
  }
  clingfy::bridge::NativeLogPublisher::Instance().Warn(
      "Preview",
      "system resumed from standby with preview session " + session_snapshot +
          " open — the D3D device may be invalid; asking Dart for a silent "
          "rebuild (previewInvalidated)");
  clingfy::bridge::PlayerEventPublisher::Instance().EmitPreviewInvalidated(
      session_snapshot, "systemResume");
}

OpenResult PreviewEngine::Open(const OpenArgs& args) {
  LogNative("Open() entered");

  // Reconcile an orphaned session BEFORE taking mutex_ (Close() locks it
  // internally — calling it under the lock would self-deadlock). Dart is the
  // engine's single, serialized driver: an Open for a DIFFERENT session while
  // one is running means the previous session's owner is gone — a Dart hot
  // restart (the native process and this singleton survive it) or a
  // watchdog-abandoned close. Refusing used to wedge every future preview
  // until a full app restart; close the stale session and proceed instead
  // (last-open-wins, matching macOS). Same-session re-entry keeps the
  // idempotent reply below. No interleave risk: Open/Close are both
  // dispatched on the platform thread.
  {
    std::string stale_session_id;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (ShouldReconcileStaleSession(running_.load(), active_session_id_,
                                      args.session_id)) {
        stale_session_id = active_session_id_;
      }
    }
    if (!stale_session_id.empty()) {
      clingfy::bridge::NativeLogPublisher::Instance().Warn(
          "Preview",
          "closing orphaned preview session " + stale_session_id +
              " to open " + args.session_id +
              " — the previous session's owner is gone (Dart hot restart or "
              "an abandoned close)");
      CloseArgs close_args;
      close_args.session_id = stale_session_id;
      Close(close_args);
    }
  }

  std::lock_guard<std::mutex> lock(mutex_);

  // Polish: aspect-matched texture (see ComputePreviewTextureSize) — the
  // compositor letterbox becomes an exact fit and Flutter's AspectRatio is
  // the ONLY letterbox, so non-16:9 recordings no longer get double bars.
  const TextureSize tex =
      ComputeCanvasTextureSize(args.video_width_hint, args.video_height_hint,
                               args.layout_preset, args.resolution_preset);

  OpenResult result;
  result.width = tex.width;
  result.height = tex.height;

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
    // Different session id while already running. The orphan reconcile at
    // the top of Open() closes a stale session before we get here, so this
    // is a pure backstop — reachable only if that close failed to stop the
    // engine. Surfacing an error beats silently proceeding into a corrupt
    // double-session state.
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
  // Audio separation (D9): run the ONE decode probe per sidecar now, so
  // every later renderer (re)open — including the error-rebuild path —
  // reuses the same verdict. An undecodable sidecar degrades to the premix
  // (D7); a few ms of MF reader open is fine on this path (Open already
  // builds a device + reader).
  if (!args.mic_audio_path.empty() &&
      capture::export_::ProbeDecodableAudio(args.mic_audio_path)) {
    impl_->mic_audio_path = args.mic_audio_path;
  }
  if (!args.system_audio_path.empty() &&
      capture::export_::ProbeDecodableAudio(args.system_audio_path)) {
    impl_->system_audio_path = args.system_audio_path;
  }
  impl_->audio_separated =
      !impl_->mic_audio_path.empty() || !impl_->system_audio_path.empty();
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
  const auto td = MakeSharedTextureDesc(tex.width, tex.height);
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
  impl_->descriptor.width = static_cast<size_t>(tex.width);
  impl_->descriptor.height = static_cast<size_t>(tex.height);
  impl_->descriptor.visible_width = static_cast<size_t>(tex.width);
  impl_->descriptor.visible_height = static_cast<size_t>(tex.height);
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

  // ---- 5b. Phase 9.6: camera bubble. The router only sets camera_path when the
  //         project has a usable, non-burned-in camera. The composition (visible,
  //         placement, styling) arrives separately via SetCameraComposition.
  if (!args.camera_path.empty()) {
    impl_->camera_renderer = clingfy::preview::PreviewCameraRenderer::Create(
        args.camera_path, args.camera_start_offset_ms);
    if (impl_->camera_renderer != nullptr) {
      LogNative("PreviewCameraRenderer: created for camera/raw.mov");
    } else {
      // WARN (not the DEBUG breadcrumb): Open() still succeeds, so this is
      // the only trace explaining why the editor preview shows no camera
      // bubble while the export would include it.
      clingfy::bridge::NativeLogPublisher::Instance().Warn(
          "Preview",
          "PreviewCameraRenderer create failed — preview stays camera-free "
          "though the project has a camera track");
    }
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
  texture_width_ = tex.width;
  texture_height_ = tex.height;
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
      // Unwind partial state. Phase 10.4: the texture is already
      // registered at this point — release it through the async-unregister
      // path (a bare impl_.reset() left Flutter holding a descriptor
      // callback whose user_data pointed at the freed Impl).
      impl_->player = nullptr;
      impl_->shared_handle = nullptr;
      UnwindFailedOpenTexture(args.session_id);
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
    // Phase 10.4: same async-unregister unwind as the path-resolution
    // failure above — see UnwindFailedOpenTexture.
    impl_->player = nullptr;
    impl_->shared_handle = nullptr;
    UnwindFailedOpenTexture(args.session_id);
    return result;
  }

  // These assignments are already protected: Open() holds `mutex_` for its
  // entire body (the lock_guard at the top of the function), so the live
  // MediaPlayer callbacks — which take mutex_ before reading these fields —
  // serialize against the remainder of Open.
  active_session_id_ = args.session_id;
  active_project_path_ = args.project_path;
  emitted_preview_ready_ = false;
  render_error_emitted_ = false;
  media_failed_emitted_ = false;
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
  // Step 4-3b: the edited-playback pacer. Idle until an edited session plays;
  // joined in Close() before the impl_ teardown, exactly like the heartbeat.
  pacer_thread_ = std::thread([this] { PacerLoop(); });

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

  // Editing port (clips, 4-3): in stitched-preview mode the edited render path
  // owns the shared texture. The MediaPlayer is paused, but a frame can already
  // be in flight — drop it so it cannot overwrite the edited frame with uncut
  // content. (Guard here, before timing_total.BeginFrame, to avoid unbalancing
  // the frame timer.)
  if (impl->edited_mode) {
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

  if (const HRESULT ensure_hr = impl->compositor.EnsureResources(
          impl->d3d_device.Get(), impl->d2d_context.Get(), vw, vh);
      FAILED(ensure_hr)) {
    impl->dropped_frames.fetch_add(1, std::memory_order_relaxed);
    impl->last_render_failure_hr.store(static_cast<std::int32_t>(ensure_hr),
                                       std::memory_order_relaxed);
    NoteRenderFailure(impl, "ensure_resources");
    impl->timing_total.EndFrame();
    return;
  }

  // ---- copy bucket ----
  impl->timing_copy.BeginFrame();
  try {
    sender.CopyFrameToVideoSurface(impl->compositor.winrt_video_surface());
  } catch (winrt::hresult_error const& e) {
    impl->dropped_frames.fetch_add(1, std::memory_order_relaxed);
    impl->last_render_failure_hr.store(static_cast<std::int32_t>(e.code()),
                                       std::memory_order_relaxed);
    NoteRenderFailure(impl, "frame_copy");
    impl->timing_copy.EndFrame();
    impl->timing_total.EndFrame();
    return;
  }
  impl->timing_copy.EndFrame();

  // ---- render + handoff (shared with the edited stitched path, 4-3) ----
  // The frame is now in the compositor's video surface; the position/duration
  // reported to Dart are the RAW source values on this (MediaPlayer) path.
  const bool need_playback_us = impl->cursor_mode || impl->camera_renderer;
  const std::int64_t playback_us =
      need_playback_us ? CurrentPlaybackUs(sender) : -1;
  const std::int64_t pos_us = CurrentPlaybackUs(sender);
  std::int64_t dur_us = 0;
  try {
    dur_us = std::chrono::duration_cast<std::chrono::microseconds>(
                 sender.PlaybackSession().NaturalDuration())
                 .count();
  } catch (winrt::hresult_error const&) {
    dur_us = 0;
  }
  ComposeAndHandoffLocked(impl, playback_us, pos_us > 0 ? pos_us / 1000 : 0,
                          dur_us > 0 ? dur_us / 1000 : 0);
}

void PreviewEngine::ComposeAndHandoffLocked(Impl* impl,
                                            std::int64_t playback_us,
                                            std::int64_t emit_pos_ms,
                                            std::int64_t emit_dur_ms) {
  // Remember where this frame sits so a paused settings change can re-compose
  // the same instant instead of seeking for a fresh one (RepaintRetainedFrame).
  impl->last_playback_us = playback_us;
  impl->last_emit_pos_ms = emit_pos_ms;
  impl->last_emit_dur_ms = emit_dur_ms;

  // ---- render bucket ----
  // The shared texture IS the destination — no slider strip. Letterbox
  // the natural video into the full canvas.
  // Canvas framing, resolved from the wire contract's resolution-independent
  // fractions onto THIS surface. The same authored padding therefore covers the
  // same proportion of the frame here as it does in the export, instead of ~3x
  // more (this texture is capped at kTextureWidth x kTextureHeight while the
  // export renders at the user's chosen resolution).
  const double surface_short = std::min(static_cast<double>(texture_width_),
                                        static_cast<double>(texture_height_));
  const double padding_px = core::DenormalizeFromShortSide(
      impl->canvas.padding_fraction, surface_short);
  const double radius_px = core::DenormalizeFromShortSide(
      impl->canvas.corner_radius_fraction, surface_short);

  // Decoded once and cached; a second lookup for an unchanged file does no
  // decode, which is what keeps a static background off the per-frame path.
  // A preset outranks an image: the UI offers one background KIND at a time,
  // and both end up as a bitmap drawn to cover, so they share the draw path.
  ID2D1Bitmap* bg_image = nullptr;
  if (impl->canvas.has_preset) {
    bg_image = impl->preset_bitmaps.Get(
        impl->d2d_context.Get(), impl->canvas.preset,
        static_cast<UINT>(texture_width_), static_cast<UINT>(texture_height_));
  } else {
    bg_image = impl->background_images.Get(
        impl->d2d_context.Get(), impl->canvas.background_image_path);
  }
  impl->compositor.SetCanvasFraming(
      capture::export_::ResolveBackgroundColor(impl->canvas.background_argb),
      static_cast<float>(radius_px), bg_image);

  // The video lands in the padded content rect, not the full surface. Reuses
  // the export's own fit/fill block so both consumers inset identically.
  const capture::export_::RectF content = capture::export_::ComputeContentRect(
      capture::export_::SizeF{static_cast<double>(texture_width_),
                              static_cast<double>(texture_height_)},
      capture::export_::SizeF{
          static_cast<double>(impl->compositor.video_width()),
          static_cast<double>(impl->compositor.video_height())},
      capture::export_::FitMode::kFit, padding_px);
  const D2D1_RECT_F dest =
      D2D1::RectF(static_cast<float>(content.x), static_cast<float>(content.y),
                  static_cast<float>(content.x + content.width),
                  static_cast<float>(content.y + content.height));

  // Phase 9.6: advance/seek the camera frame BEFORE BeginDraw (the painter's
  // shadow bake does SetTarget round-trips, illegal inside BeginDraw).
  if (impl->camera_renderer) {
    // Same reasoning as the padding/radius denormalize above, for the values
    // that are not fractions: the authored border width, the shadow table and
    // the bubble's min-side floor are all EXPORT-canvas pixels, so on this
    // smaller texture they must be resolved by the short-side ratio or the
    // preview shows a ~3x-too-thick border and a floored-oversized bubble.
    const double camera_effect_scale = PreviewCameraEffectScale(
        surface_short, impl->canvas.export_short_side);
    impl->camera_renderer->PrepareAndAdvance(
        impl->d2d_context.Get(), static_cast<UINT>(texture_width_),
        static_cast<UINT>(texture_height_), playback_us, camera_effect_scale);
  }

  impl->timing_render.BeginFrame();
  // Re-bind the shared target every frame. The target is bound once at Open, but
  // the camera painter's shadow bake (PrepareAndAdvance, above) does SetTarget
  // round-trips that leave the context target = nullptr; without this re-bind the
  // BeginDraw below would draw to no target and EndDraw would fail permanently.
  // (The export pipeline re-binds per frame for the same reason.)
  impl->d2d_context->SetTarget(impl->shared_bitmap.Get());
  impl->d2d_context->BeginDraw();
  impl->compositor.ComposeFrame(impl->d2d_context.Get(), dest,
                                impl->cursor_events, playback_us,
                                NowSeconds(), impl->zoom);
  // Camera bubble draws on top of the composited screen frame, in canvas space.
  // The intro/outro clock is the EDITED position + edited duration, not
  // `playback_us` (source time, used above to advance the camera VIDEO frame).
  // The export splits the two the same way — see "camera_clock_ms" in
  // export_pipeline.cpp — because on a trimmed project the source origin may sit
  // inside a cut, so a source-keyed intro would fire where the user never looks.
  if (impl->camera_renderer) {
    impl->camera_renderer->Draw(impl->d2d_context.Get(), emit_pos_ms,
                                emit_dur_ms, impl->zoom.current_zoom);
  }
  const HRESULT end_hr = impl->d2d_context->EndDraw();
  impl->timing_render.EndFrame();
  if (FAILED(end_hr)) {
    // D2DERR_RECREATE_TARGET would be the typical failure here; we don't
    // recover the target (the descriptor + bitmap are bound at Open), but
    // Phase 10.4 at least makes a PERMANENT failure loud: NoteRenderFailure
    // emits PREVIEW_RENDER_ERROR after a run of consecutive failures
    // instead of freezing the image under a moving playhead forever.
    impl->dropped_frames.fetch_add(1, std::memory_order_relaxed);
    impl->last_render_failure_hr.store(static_cast<std::int32_t>(end_hr),
                                       std::memory_order_relaxed);
    NoteRenderFailure(impl, "end_draw");
    impl->timing_total.EndFrame();
    return;
  }
  impl->consecutive_render_failures.store(0, std::memory_order_relaxed);

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
    last_frame_ms_.store(
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch())
            .count(),
        std::memory_order_relaxed);
    clingfy::bridge::PlayerEventPublisher::Instance().EmitPlayerTick(
        session_snapshot, emit_pos_ms, emit_dur_ms);
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
  // Phase 10.4: map the MediaPlayerError cause to a meaningful code. The
  // pre-10.4 handler hardcoded VIDEO_FILE_MISSING for everything, so a
  // codec/decode failure told the user their file was "missing".
  std::string code = clingfy::bridge::error::kVideoFileMissing;
  if (failed_args != nullptr) {
    try {
      const std::wstring w = failed_args->ErrorMessage().c_str();
      if (!w.empty()) message = WideToUtf8(w);
      switch (failed_args->Error()) {
        case winrt_playback::MediaPlayerError::DecodingError:
        case winrt_playback::MediaPlayerError::SourceNotSupported:
          code = clingfy::bridge::error::kAssetInvalid;
          break;
        case winrt_playback::MediaPlayerError::NetworkError:
          // The source became unreachable mid-playback (file deleted,
          // share dropped) — the closest existing semantic.
          code = clingfy::bridge::error::kVideoFileMissing;
          break;
        case winrt_playback::MediaPlayerError::Aborted:
        case winrt_playback::MediaPlayerError::Unknown:
        default:
          code = clingfy::bridge::error::kPreviewRenderError;
          break;
      }
    } catch (winrt::hresult_error const&) {
      // Best effort — keep the generic message + legacy code.
    }
  }
  std::string session_snapshot;
  std::string project_path_snapshot;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    // Phase 10.4: MediaPlayer can fire MediaFailed repeatedly; each emit
    // used to re-run Dart's whole close flow and overwrite the errorCode.
    if (media_failed_emitted_) return;
    media_failed_emitted_ = true;
    session_snapshot = active_session_id_;
    project_path_snapshot = active_project_path_;
  }
  if (!session_snapshot.empty()) {
    // ERROR (not the DEBUG LogNative breadcrumb) so release users' logs and
    // Sentry see the failure regardless of the verbose toggle.
    clingfy::bridge::NativeLogPublisher::Instance().Error(
        "Preview", "MediaFailed (" + code + "): " + message);
    clingfy::bridge::PlayerEventPublisher::Instance().EmitPlayerError(
        session_snapshot, code, message);
    // Step 5.5.3: also emit `previewFailed` on the workflow channel so
    // Dart's RecordingController transitions out of `previewLoading` /
    // `previewReady` into the closing/error flow (matches macOS, which
    // fires this from `KVO`'d AVPlayer status observers).
    clingfy::bridge::WorkflowEventPublisher::Instance().EmitPreviewFailed(
        session_snapshot, project_path_snapshot, code, message);
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

    // Snapshot the session id + the MediaPlayer pointer + impl under the
    // mutex; release the lock before touching the player (its API is safe from
    // any thread). Close joins this thread before destroying impl_, so the raw
    // impl pointer stays valid for this iteration.
    std::string session_snapshot;
    winrt_playback::MediaPlayer player_snapshot{nullptr};
    Impl* impl = nullptr;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      session_snapshot = active_session_id_;
      if (impl_) {
        player_snapshot = impl_->player;
        impl = impl_.get();
      }
    }
    if (session_snapshot.empty() || impl == nullptr) continue;

    std::int64_t pos_ms = 0;
    std::int64_t dur_ms = 0;
    // Editing port (clips, 4-3b): in stitched mode the MediaPlayer is paused and
    // its Position/NaturalDuration are the RAW (uncut) source — report the EDITED
    // playhead + edited duration instead (guarded by render_mutex).
    bool edited = false;
    {
      std::lock_guard<std::mutex> render_lock(impl->render_mutex);
      if (impl->edited_mode) {
        edited = true;
        pos_ms = impl->edited_pos_ms;
        dur_ms = capture::export_::clip_planner::EditedDurationMs(
            impl->clip_ranges);
      }
    }
    if (!edited) {
      if (player_snapshot == nullptr) continue;
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

void PreviewEngine::UnwindFailedOpenTexture(const std::string& session_id) {
  if (texture_registrar_ != nullptr && texture_id_ >= 0 && impl_) {
    auto* teardown = new TearDownContext{};
    teardown->dying_impl = std::move(impl_);
    teardown->texture_id = texture_id_;
    teardown->session_id = session_id;
    teardown->close_qpc = NowQpc();
    teardown->qpc_frequency = QueryQpcFrequencyHz();
    LogNative(
        "UnwindFailedOpenTexture: async-unregistering the texture after a "
        "failed Open");
    FlutterDesktopTextureRegistrarUnregisterExternalTexture(
        texture_registrar_, texture_id_, &OnUnregisterComplete, teardown);
  } else {
    impl_.reset();
  }
  texture_id_ = -1;
  shared_handle_ok_ = false;
}

void PreviewEngine::NoteRenderFailure(Impl* impl, const char* stage) {
  // Threshold ≈ 1.5–3 s of consecutive failures at 30–60 fps: long enough
  // that a transient device hiccup (which recovers and resets the counter)
  // never fires, short enough that a permanently dead render loop is
  // reported while the user is still looking at the frozen frame.
  constexpr std::uint32_t kConsecutiveRenderFailureThreshold = 90;
  const std::uint32_t failures =
      impl->consecutive_render_failures.fetch_add(
          1, std::memory_order_relaxed) +
      1;
  if (failures != kConsecutiveRenderFailureThreshold) return;

  std::string session_snapshot;
  std::string project_path_snapshot;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (render_error_emitted_ || shutting_down_.load()) return;
    render_error_emitted_ = true;
    session_snapshot = active_session_id_;
    project_path_snapshot = active_project_path_;
  }
  if (session_snapshot.empty()) return;

  const std::string message =
      std::string("The preview stopped rendering (stage: ") + stage +
      "). Close and reopen the preview; the recording file itself is "
      "unaffected.";
  // Fold the last per-frame HRESULT (+ the device-removed reason, when the
  // device is gone) into the log line — it discriminates device loss (Modern
  // Standby resume / TDR) from out-of-memory, which the stage name alone
  // cannot.
  const HRESULT last_hr = static_cast<HRESULT>(
      impl->last_render_failure_hr.load(std::memory_order_relaxed));
  const HRESULT removed_reason =
      impl->d3d_device ? impl->d3d_device->GetDeviceRemovedReason() : S_OK;
  char detail[96];
  if (removed_reason != S_OK) {
    std::snprintf(detail, sizeof(detail),
                  " (hr=0x%08lX, device removed, reason=0x%08lX)",
                  static_cast<unsigned long>(last_hr),
                  static_cast<unsigned long>(removed_reason));
  } else {
    std::snprintf(detail, sizeof(detail), " (hr=0x%08lX)",
                  static_cast<unsigned long>(last_hr));
  }
  LogNative(("PREVIEW_RENDER_ERROR emitted: " + message + detail).c_str());
  clingfy::bridge::NativeLogPublisher::Instance().Error(
      "Preview", "render loop died (" + std::string(stage) + ")" + detail +
                     "; emitting PREVIEW_RENDER_ERROR");
  clingfy::bridge::PlayerEventPublisher::Instance().EmitPlayerError(
      session_snapshot, clingfy::bridge::error::kPreviewRenderError, message);
  clingfy::bridge::WorkflowEventPublisher::Instance().EmitPreviewFailed(
      session_snapshot, project_path_snapshot,
      clingfy::bridge::error::kPreviewRenderError, message);
}

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

  // Step 4-3b: join the pacer thread before touching impl_ (same reason as the
  // heartbeat) — it holds a raw impl_ pointer + render_mutex per iteration, so
  // it must be fully stopped before the impl_ move/destroy below. shutting_down_
  // is already set, so its next loop check exits; the join waits out the current
  // iteration (during which impl_ is still alive).
  if (pacer_thread_.joinable()) {
    pacer_thread_.join();
  }
  LogNative("Close() pacer thread joined");

  // Voice cleanup (Phase 4): signal + join any in-flight RNNoise worker before
  // impl_ is torn down — the worker holds a raw impl_ pointer via its cancel
  // flag. The cancel makes ProduceCleanedMic return between samples, so the
  // join is fast even mid-denoise. Grabbed under mutex_ but joined outside it
  // (the worker never takes mutex_, and the pacer/heartbeat are already
  // stopped, so nothing else touches these here). The temp is deleted AFTER
  // the renderer reset below — the mic pump holds the cleaned file open (MF
  // opens it without FILE_SHARE_DELETE), so removing it first would fail.
  {
    Impl* impl = nullptr;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      impl = impl_.get();
    }
    if (impl != nullptr) {
      impl->cleanup_cancel.store(true);
      if (impl->cleanup_thread.joinable()) {
        impl->cleanup_thread.join();
      }
    }
  }
  LogNative("Close() voice-cleanup worker joined");

  // 4-7c: stop + join the audio renderer's thread HERE, next to the pacer
  // join (design D9) — explicitly, before impl_ is moved into the async
  // texture-unregister teardown, so the WASAPI stream never outlives the
  // session and the join runs on this (platform) thread, not whichever
  // thread Flutter's unregister callback lands on. The pacer and platform
  // handlers are stopped/serialized at this point, so the reset needs no
  // render_mutex.
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (impl_ != nullptr) {
      impl_->audio_renderer.reset();
      // Now the mic pump has released the cleaned temp — safe to delete.
      if (!impl_->cleaned_mic_path.empty()) {
        std::error_code ec;
        std::filesystem::remove(impl_->cleaned_mic_path, ec);
      }
    }
  }

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
    render_error_emitted_ = false;
    media_failed_emitted_ = false;
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
  const std::wstring artifact_path = ArtifactPath();
  if (write_artifact && !artifact_path.empty()) {
    EnsureLogParentDir();
    f.open(std::filesystem::path(artifact_path),
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
    std::fprintf(stderr, "STAGE2A_2_ARTIFACT wrote %ls\n",
                 artifact_path.c_str());
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
  Impl* impl = nullptr;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!running_.load() || session_id != active_session_id_) {
      return;  // Stale or pre-Open call — silent no-op.
    }
    if (impl_) {
      player_snapshot = impl_->player;
      impl = impl_.get();
    }
  }
  if (player_snapshot == nullptr || impl == nullptr) return;
  // Editing port (clips, 4-3b/4-4): for an edited session, drive continuous
  // playback from the pacer thread — NEVER resume the MediaPlayer (it would
  // decode the uncut source; its frames are dropped by the edited-mode guard and
  // any audio would be uncut). Both cut (forward-decode) and reorder (per-range
  // seeks) play.
  {
    std::lock_guard<std::mutex> render_lock(impl->render_mutex);
    if (impl->edited_mode) {
      namespace clip = capture::export_::clip_planner;
      // 4-7c/D7: consume a mid-stream audio failure BEFORE acting on the
      // renderer (one WARN + one rebuild; degrades to logged silent video).
      HandleAudioRenderErrorLocked(impl);
      // 4-5: Play at the edited end restarts from 0 (macOS IsAtEnd parity) —
      // otherwise the pacer EOSes immediately and the button feels dead.
      if (ShouldRestartEditedPlaybackFromEnd(
              impl->edited_pos_ms, clip::EditedDurationMs(impl->clip_ranges))) {
        impl->edited_pos_ms = 0;
      }
      // Reorder needs the per-range cursor primed from the current position.
      if (!clip::IsSourceMonotonic(impl->clip_ranges)) {
        PrimeReorderStateLocked(impl, impl->edited_pos_ms);
      }
      // Render the current frame (re-positions the reader), then arm the pacer —
      // only if the render succeeded, so a soft reader/decode failure leaves the
      // pacer idle rather than busy-polling.
      impl->edited_playing = RenderEditedFrameLocked(impl, impl->edited_pos_ms);
      // 4-7c: start the sound at the same edited position (Play always
      // re-primes the renderer, dropping any stale buffered audio). Only when
      // the video armed — a dead video path must not play sound alone.
      if (impl->edited_playing && impl->audio_renderer != nullptr) {
        impl->audio_renderer->Play(impl->edited_pos_ms);
      }
      clingfy::bridge::NativeLogPublisher::Instance().Debug(
          "Preview",
          std::string("Play (stitched, reorder=") +
              (clip::IsSourceMonotonic(impl->clip_ranges) ? "false" : "true") +
              ") from edited " + std::to_string(impl->edited_pos_ms) +
              "ms; pacer armed=" + (impl->edited_playing ? "true" : "false") +
              ", audio=" +
              (impl->audio_renderer != nullptr ? "on" : "off"));
      return;
    }
  }
  try {
    player_snapshot.Play();
  } catch (winrt::hresult_error const&) {
    // Best-effort. MediaPlayer errors surface separately via the
    // MediaFailed event subscription installed in Open().
  }
}

void PreviewEngine::Pause(const std::string& session_id) {
  winrt_playback::MediaPlayer player_snapshot{nullptr};
  Impl* impl = nullptr;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!running_.load() || session_id != active_session_id_) {
      return;
    }
    if (impl_) {
      player_snapshot = impl_->player;
      impl = impl_.get();
    }
  }
  if (player_snapshot == nullptr || impl == nullptr) return;
  // Editing port (clips, 4-3b): pausing an edited session stops the pacer; the
  // MediaPlayer is already paused, so leave it be.
  {
    std::lock_guard<std::mutex> render_lock(impl->render_mutex);
    if (impl->edited_mode) {
      impl->edited_playing = false;
      // 4-7c: freeze the sound with the frame.
      if (impl->audio_renderer != nullptr) {
        impl->audio_renderer->Pause();
      }
      clingfy::bridge::NativeLogPublisher::Instance().Debug(
          "Preview", "Pause (stitched) at edited " +
                         std::to_string(impl->edited_pos_ms) + "ms");
      return;
    }
  }
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

  // Editing port (clips, 4-3): in stitched-preview mode a scrub is an EDITED-
  // time position — render that edited frame from the reader instead of seeking
  // the (paused) MediaPlayer. Separate render_mutex scope so the fall-through
  // MediaPlayer path below can take it again without a recursive lock.
  {
    std::lock_guard<std::mutex> render_lock(impl_snapshot->render_mutex);
    if (shutting_down_.load()) return;
    if (impl_snapshot->edited_mode) {
      namespace clip = capture::export_::clip_planner;
      RenderEditedFrameLocked(impl_snapshot, position_ms);
      // 4-4: re-prime the reorder pacer cursor so a scrub while playing a
      // reordered timeline continues from the scrubbed range.
      if (!clip::IsSourceMonotonic(impl_snapshot->clip_ranges)) {
        PrimeReorderStateLocked(impl_snapshot, position_ms);
      }
      // 4-7c: a scrub WHILE playing restarts the sound at the new position
      // (Play re-primes and drops the stale buffer); while paused the
      // renderer stays idle — the next Play carries the fresh position.
      if (impl_snapshot->edited_playing &&
          impl_snapshot->audio_renderer != nullptr) {
        impl_snapshot->audio_renderer->Play(position_ms);
      }
      return;
    }
  }

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

PausedRepaintAction DecidePausedRepaint(bool is_playing,
                                        bool has_composed_frame) {
  if (is_playing) {
    return PausedRepaintAction::kSkipPlaying;
  }
  return has_composed_frame ? PausedRepaintAction::kRepaintRetained
                            : PausedRepaintAction::kNudgeSeek;
}

CameraNudgePlan ResolveCameraNudgeTarget(std::int64_t current_ms,
                                         std::int64_t previous_anchor_ms) {
  // The anchor's 1ms neighbor: one back normally, one forward at 0 so the
  // target is never negative.
  const auto neighbor = [](std::int64_t anchor) {
    return anchor > 0 ? anchor - 1 : anchor + 1;
  };
  CameraNudgePlan plan;
  plan.anchor_ms = previous_anchor_ms;
  if (plan.anchor_ms < 0 || (current_ms != plan.anchor_ms &&
                             current_ms != neighbor(plan.anchor_ms))) {
    // First nudge, or the playhead moved (user scrub / play+pause / new
    // session): the current position becomes the new anchor.
    plan.anchor_ms = current_ms;
  }
  // Alternate: away from the anchor when sitting on it, back onto it
  // otherwise. Either way the seek target differs from the current
  // position, so the seek is never coalesced away.
  plan.target_ms = current_ms == plan.anchor_ms ? neighbor(plan.anchor_ms)
                                                : plan.anchor_ms;
  return plan;
}

namespace {

// Reflect an editor change immediately in a PAUSED preview. The compositor
// only re-runs on a frame-server callback, which a paused MediaPlayer does
// not emit, so without this a camera/color edit would not appear until the
// user pressed play. Seeking forces the frame server to re-deliver a frame,
// recompositing with the new settings. The seek target comes from
// ResolveCameraNudgeTarget (see preview_engine.h): alternating between an
// anchor and its 1ms neighbor keeps the seek un-coalescable while bounding
// total drift to 1ms — under one frame at any fps, so the same image is
// shown — no matter how many edits a drag produces. No-op while playing —
// the next natural frame already picks the change up and nudging would
// stutter. Best-effort: a failed nudge just defers the change to the next
// frame. Shared by SetCameraComposition and SetColorGrade; `mutex` guards
// `nudge_anchor_ms` (the engine's mutex_ + camera_nudge_anchor_ms_).
void NudgePausedPreviewPlayer(winrt_playback::MediaPlayer player_snapshot,
                              std::mutex& mutex,
                              std::int64_t& nudge_anchor_ms) {
  if (player_snapshot == nullptr) {
    return;
  }
  try {
    auto session = player_snapshot.PlaybackSession();
    if (session.PlaybackState() !=
        winrt_playback::MediaPlaybackState::Playing) {
      const auto cur_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                              session.Position())
                              .count();
      CameraNudgePlan plan;
      {
        std::lock_guard<std::mutex> lock(mutex);
        plan = ResolveCameraNudgeTarget(cur_ms, nudge_anchor_ms);
        nudge_anchor_ms = plan.anchor_ms;
      }
      session.Position(std::chrono::duration_cast<winrt_foundation::TimeSpan>(
          std::chrono::milliseconds(plan.target_ms)));
    }
  } catch (winrt::hresult_error const&) {
    // Best-effort; the change will appear on the next frame instead.
  }
}

}  // namespace

void PreviewEngine::RepaintPausedPreview() {
  winrt_playback::MediaPlayer player_snapshot{nullptr};
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (impl_ == nullptr) return;
    player_snapshot = impl_->player;
  }

  bool is_playing = false;
  if (player_snapshot != nullptr) {
    try {
      is_playing = player_snapshot.PlaybackSession().PlaybackState() ==
                   winrt_playback::MediaPlaybackState::Playing;
    } catch (winrt::hresult_error const&) {
      // Unreadable state: treat as not playing. A repaint on a live frame is
      // wasteful but harmless; skipping one on a frozen frame is the bug being
      // fixed here.
    }
  }

  switch (DecidePausedRepaint(is_playing, HasComposedFrame())) {
    case PausedRepaintAction::kSkipPlaying:
      return;
    case PausedRepaintAction::kRepaintRetained:
      // Re-light the frame already on screen: one D2D compose, no decode. If it
      // races a Close and reports false, there is nothing left to show anyway.
      RepaintRetainedFrame();
      return;
    case PausedRepaintAction::kNudgeSeek:
      // Nothing composed yet (preview still coming up). The historical 1ms seek
      // can still kick a stalled pipeline into producing a first frame.
      NudgePausedPreviewPlayer(std::move(player_snapshot), mutex_,
                               camera_nudge_anchor_ms_);
      return;
  }
}

bool PreviewEngine::HasComposedFrame() {
  std::lock_guard<std::mutex> lock(mutex_);
  return impl_ != nullptr &&
         impl_->frames_consumed.load(std::memory_order_relaxed) > 0;
}

bool PreviewEngine::RepaintRetainedFrame() {
  Impl* impl = nullptr;
  {
    // Same lock discipline as HandleVideoFrame: take mutex_ only to resolve
    // impl_, release it, THEN take render_mutex. ComposeAndHandoffLocked
    // re-takes mutex_ underneath render_mutex for its session snapshot, so
    // holding both here in the other order would invert the lock hierarchy.
    std::lock_guard<std::mutex> lock(mutex_);
    impl = impl_.get();
    if (impl == nullptr) return false;
  }
  if (shutting_down_.load() || !running_.load()) return false;

  std::lock_guard<std::mutex> render_lock(impl->render_mutex);
  if (shutting_down_.load() || impl_ == nullptr) return false;

  // Nothing has been composed yet, so there is no retained frame to re-light.
  // (frames_consumed, not has_video_target(): the texture is allocated in
  // EnsureResources BEFORE the first CopyFrameToVideoSurface, so a non-null
  // texture does not by itself mean the surface holds real content.)
  if (impl->frames_consumed.load(std::memory_order_relaxed) <= 0) {
    return false;
  }

  ComposeAndHandoffLocked(impl, impl->last_playback_us, impl->last_emit_pos_ms,
                          impl->last_emit_dur_ms);
  return true;
}

void PreviewEngine::SetCameraComposition(
    const std::string& session_id,
    const PreviewCameraComposition& composition) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    // Stale-session calls (a previous preview, or a placement update racing a
    // Close) are silently ignored, matching the Play/Pause/Seek contract. An empty
    // session_id is treated as a wildcard for symmetry with Close.
    if (!session_id.empty() && session_id != active_session_id_) {
      return;
    }
    if (impl_ == nullptr || impl_->camera_renderer == nullptr) {
      return;
    }
    // SetComposition is internally synchronized and does no D2D work, so holding
    // mutex_ here is cheap and cannot deadlock against the frame thread (which
    // takes mutex_ -> render_mutex -> renderer lock; we take mutex_ -> renderer
    // lock, so the renderer lock is always acquired last). The repaint happens
    // AFTER releasing mutex_, matching the snapshot-then-release discipline of
    // SeekTo/Pause.
    impl_->camera_renderer->SetComposition(composition);
  }
  RepaintPausedPreview();
}

void PreviewEngine::SetZoomSettings(const std::string& session_id,
                                    double factor, bool effect_enabled) {
  Impl* impl = nullptr;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    // Same stale-session discipline as SetColorGrade.
    if (!session_id.empty() && session_id != active_session_id_) {
      return;
    }
    if (impl_ == nullptr) {
      return;
    }
    impl = impl_.get();
  }
  {
    // The frame thread takes render_mutex -> mutex_ (never the reverse), so
    // publish under render_mutex ALONE, after mutex_ is released above —
    // the SetCanvasComposition discipline.
    std::lock_guard<std::mutex> render_lock(impl->render_mutex);
    impl->zoom.zoom_factor = factor;
    impl->zoom.effect_enabled = effect_enabled;
  }
  RepaintPausedPreview();
}

void PreviewEngine::SetColorGrade(
    const std::string& session_id,
    const capture::export_::color::ColorGrade& grade) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    // Same stale-session + release-before-repaint discipline as
    // SetCameraComposition above.
    if (!session_id.empty() && session_id != active_session_id_) {
      return;
    }
    if (impl_ == nullptr) {
      return;
    }
    // SetColorGrade is internally synchronized (the compositor's grade
    // mutex) and does no D2D work here — the effect chain (re)builds on the
    // frame thread at the next composited frame, or immediately below when the
    // preview is paused and there is no next frame coming.
    impl_->compositor.SetColorGrade(grade);
  }
  RepaintPausedPreview();
}

void PreviewEngine::SetCanvasComposition(
    const std::string& session_id, const core::CanvasFramingArgs& framing) {
  Impl* impl = nullptr;
  UINT source_w = 0;
  UINT source_h = 0;
  int current_tex_w = 0;
  int current_tex_h = 0;
  std::string session_snapshot;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    // Same stale-session discipline as SetColorGrade.
    if (!session_id.empty() && session_id != active_session_id_) {
      return;
    }
    if (impl_ == nullptr) {
      return;
    }
    impl = impl_.get();
    source_w = impl->last_video_width.load();
    source_h = impl->last_video_height.load();
    current_tex_w = texture_width_;
    current_tex_h = texture_height_;
    // Emit against the session that is actually active: `session_id` may be
    // empty (meaning "whichever is active") and Dart drops events whose id
    // does not match its own.
    session_snapshot = active_session_id_;
  }

  // Normalise here rather than in the router: only the engine knows the source
  // dimensions, and ResolveTargetSize is the single source of truth for how a
  // source plus layout/resolution preset becomes a canvas. Dart sends raw
  // export-output pixels; converting them against the export target is what
  // stops the preview from drawing ~3x the padding at 4K.
  core::CanvasComposition canvas{};
  canvas.background_argb = framing.background_argb;
  canvas.background_image_path = framing.background_image_path;
  canvas.preset = framing.preset;
  canvas.has_preset = framing.has_preset;
  if (source_w > 0 && source_h > 0) {
    const capture::export_::SizeF target =
        capture::export_::ResolveTargetSize(
            capture::export_::SizeF{static_cast<double>(source_w),
                                    static_cast<double>(source_h)},
            framing.layout_preset, framing.resolution_preset);
    const double export_short = std::min(target.width, target.height);
    canvas.padding_fraction =
        core::NormalizeToShortSide(framing.padding_px, export_short);
    canvas.corner_radius_fraction =
        core::NormalizeToShortSide(framing.corner_radius_px, export_short);
    // Carried for the camera bubble, whose border/shadow/min-side floor are
    // export-canvas lengths that cannot be expressed as canvas fractions (a
    // shadow preset is an index, the floor is a constant). It rides this struct
    // so it inherits the render_mutex publish below.
    canvas.export_short_side = export_short;
  }
  // No frame yet => source dims unknown => fractions stay 0 and the canvas
  // renders unpadded, which is what the preview shows today anyway. The next
  // push after the first frame resolves properly.

  {
    // The frame thread takes render_mutex -> mutex_ (never the reverse), so
    // publish under render_mutex ALONE, after mutex_ is released above.
    std::lock_guard<std::mutex> render_lock(impl->render_mutex);
    impl->canvas = canvas;
  }
  // Paused / ended preview: re-light the retained frame so the canvas edit is
  // visible immediately. No seek, no decode. While playing this is a no-op and
  // the next natural frame carries the change.
  RepaintPausedPreview();

  // A layout change reshapes the CANVAS, and the shared texture is sized to
  // the canvas aspect — but a registered texture cannot be resized in place.
  // Repainting alone would letterbox the new canvas inside the old aspect, so
  // the preview would keep lying about the export. Ask Dart to rebuild the
  // session in place; it reopens with these presets and swaps the texture id
  // and aspect without a phase change or a remount.
  //
  // Deliberately AFTER the repaint: the rebuild is asynchronous, and repainting
  // first means the old texture shows the new colours/background during the
  // reopen gap instead of a stale frame.
  if (DecideCanvasAspectRebuild(static_cast<int>(source_w),
                                static_cast<int>(source_h), current_tex_w,
                                current_tex_h, framing.layout_preset,
                                framing.resolution_preset)) {
    clingfy::bridge::NativeLogPublisher::Instance().Info(
        "Preview",
        "canvas layout changed the required texture aspect for session " +
            session_snapshot + " — asking Dart to rebuild the preview in place "
            "(previewInvalidated)");
    clingfy::bridge::PlayerEventPublisher::Instance().EmitPreviewInvalidated(
        session_snapshot, "canvasAspectChanged");
  }
}

core::CanvasComposition PreviewEngine::canvas_composition_for_testing() {
  Impl* impl = nullptr;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    impl = impl_.get();
    if (impl == nullptr) return {};
  }
  std::lock_guard<std::mutex> render_lock(impl->render_mutex);
  return impl->canvas;
}

bool PreviewEngine::RangesAreEdited(
    const std::vector<capture::export_::clip_planner::ClipKeptRange>& ranges) {
  namespace clip = capture::export_::clip_planner;
  // Mirror the export ClassifyClipEdit has-real-edits test: coalesce source-
  // adjacent ranges, then a real edit is >1 window, or a single window that does
  // not start at source 0 (a head-trim). A split with nothing deleted coalesces
  // back to one full-from-0 window and stays passthrough.
  const auto coalesced = clip::Coalesce(ranges);
  return coalesced.size() > 1 ||
         (coalesced.size() == 1 && coalesced[0].source_in_ms > 0);
}

bool PreviewEngine::RenderEditedFrameLocked(Impl* impl,
                                            std::int64_t edited_ms) {
  namespace clip = capture::export_::clip_planner;
  if (impl == nullptr || impl->clip_ranges.empty()) {
    return false;
  }
  const std::int64_t edited_dur = clip::EditedDurationMs(impl->clip_ranges);
  if (edited_ms < 0) edited_ms = 0;
  if (edited_dur > 0 && edited_ms > edited_dur) edited_ms = edited_dur;
  const std::int64_t source_ms =
      clip::SourceMsForEditedMs(edited_ms, impl->clip_ranges);

  if (impl->edited_reader == nullptr) {
    impl->edited_reader = PreviewSourceReader::Create(impl->video_path);
    if (impl->edited_reader == nullptr) {
      // A real failure the user should see: the stitched preview can't open its
      // own reader on the recording, so an edited project would show nothing.
      clingfy::bridge::NativeLogPublisher::Instance().Error(
          "Preview",
          "stitched preview reader failed to open the recording — the edited "
          "preview will be blank (the export is unaffected)");
      return false;  // soft-fail: nothing to draw, MediaPlayer path unaffected
    }
  }
  PreviewSourceReader* reader = impl->edited_reader.get();

  // One seek to the target source window, then decode forward to the frame at
  // or after it (MF lands on the prior keyframe; discard the lead-in). A single
  // seek per scrub / clip edit — NOT a per-frame seek during playback (§5.4).
  reader->SeekTo(source_ms);
  // Every transport reposition resets the pacer's gap-seek lead-in floor —
  // a scrub BACKWARD must be allowed to re-emit earlier frames — and the
  // chase state (a fresh position starts at parity with the sound).
  impl->edited_min_source_ms = source_ms;
  impl->stale_streak = 0;
  impl->awaiting_chase_frame = false;
  impl->last_chase_seek = {};  // a fresh position starts at parity
  std::vector<BYTE> bgra;
  bool have_frame = false;
  for (int guard = 0; guard < 600; ++guard) {
    std::vector<BYTE> next;
    std::int64_t next_ts = 0;
    if (!reader->ReadNextFrame(&next, &next_ts)) {
      break;  // EOS — keep the last frame decoded before it
    }
    bgra = std::move(next);
    have_frame = true;
    if (next_ts >= source_ms) {
      break;  // reached the target frame
    }
  }
  if (!have_frame) {
    return false;
  }

  if (const HRESULT ensure_hr = impl->compositor.EnsureResources(
          impl->d3d_device.Get(), impl->d2d_context.Get(), reader->width(),
          reader->height());
      FAILED(ensure_hr)) {
    impl->last_render_failure_hr.store(static_cast<std::int32_t>(ensure_hr),
                                       std::memory_order_relaxed);
    NoteRenderFailure(impl, "edited_ensure_resources");
    return false;
  }
  impl->last_video_width.store(reader->width());
  impl->last_video_height.store(reader->height());
  // Upload the decoded BGRA straight into the compositor's video texture — the
  // same seam the headless compositor tests fill (no WinRT frame surface).
  impl->d3d_context->UpdateSubresource(impl->compositor.video_texture(), 0,
                                       nullptr, bgra.data(),
                                       reader->width() * 4u, 0);

  impl->edited_pos_ms = edited_ms;
  // Overlays (cursor / zoom / camera) are SOURCE-keyed, so pass the frame's
  // source time; Dart sees the EDITED position + the edited duration.
  impl->timing_total.BeginFrame();
  ComposeAndHandoffLocked(impl, source_ms * 1000, edited_ms, edited_dur);
  return true;
}

PreviewEngine::PacerStallDecision PreviewEngine::DecidePacerStallReport(
    const PacerStallInput& in) {
  PacerStallDecision out;

  if (in.rendered_in_window > 0) {
    // Producing again. Only announce recovery if a stall was announced —
    // otherwise a sub-threshold gap would log a recovery from nothing.
    out.next_stalled_windows = 0;
    out.next_stall_reported = false;
    out.report = in.stall_reported ? PacerStallReport::kRecovered
                                   : PacerStallReport::kNone;
    return out;
  }

  const int windows = in.stalled_windows + 1;
  out.next_stalled_windows = windows;
  out.next_stall_reported = in.stall_reported;

  if (windows < kPacerStallOnsetWindows) {
    return out;  // not yet convincing — playback can legitimately pause here
  }
  const int since_onset = windows - kPacerStallOnsetWindows;
  if (!in.stall_reported || since_onset % kPacerStallRepeatWindows == 0) {
    out.report = PacerStallReport::kStalled;
    out.next_stall_reported = true;
  }
  return out;
}

PreviewEngine::PacerChaseDecision PreviewEngine::DecidePacerChase(
    const PacerChaseInput& in) {
  PacerChaseDecision out;

  // The frame we repositioned to — show it, whatever the clock says.
  if (in.awaiting_chase_frame) {
    out.action = PacerChaseAction::kEmit;
    out.next_stale_streak = 0;
    return out;
  }
  // No sound: the pacer free-runs (pre-4-7c behavior, byte-identical).
  if (in.audio_edited_ms < 0) {
    out.action = PacerChaseAction::kEmit;
    out.next_stale_streak = 0;
    return out;
  }
  // Within a frame budget of the sound — in sync.
  if (in.frame_edited_ms >= in.audio_edited_ms - kAudioChaseSlackMs) {
    out.action = PacerChaseAction::kEmit;
    out.next_stale_streak = 0;
    return out;
  }

  // Behind the sound. A big enough trail warrants a reposition — but never
  // into the tail (the edited end maps one-past-the-last-kept-frame, which
  // would floor out every remaining frame), and never twice in a row
  // without a frame in between (the lead-in decode would starve forever).
  const std::int64_t deficit = in.audio_edited_ms - in.frame_edited_ms;
  const bool cooldown_elapsed = in.ms_since_chase_seek < 0 ||
                                in.ms_since_chase_seek >= kChaseSeekCooldownMs;
  const bool clear_of_the_tail =
      in.edited_duration_ms > 0 &&
      in.audio_edited_ms + kChaseSeekEndGuardMs < in.edited_duration_ms;
  if (in.allow_chase_seek && deficit > kChaseSeekDeficitMs &&
      cooldown_elapsed && clear_of_the_tail) {
    out.action = PacerChaseAction::kSeekToAudio;
    out.seek_target_edited_ms = in.audio_edited_ms;
    out.next_stale_streak = 0;
    return out;
  }

  // Otherwise decimate: show every Nth stale frame so the picture keeps
  // moving (trailing the sound) instead of freezing.
  const int streak = in.stale_streak + 1;
  if (streak >= kStaleEmitEvery) {
    out.action = PacerChaseAction::kEmit;
    out.next_stale_streak = 0;
    return out;
  }
  out.action = PacerChaseAction::kDiscard;
  out.next_stale_streak = streak;
  return out;
}

std::int64_t PreviewEngine::NextKeptSourceInMsAfter(
    std::int64_t source_ms,
    const std::vector<capture::export_::clip_planner::ClipKeptRange>& ranges) {
  // Monotonic ranges are in source order; return the first window that
  // STARTS after `source_ms` (the frame at source_in itself is kept, so a
  // seek target of exactly source_in is correct). -1 = no kept audio/video
  // follows — the caller crawls to EOS (playback-complete path).
  std::int64_t best = -1;
  for (const auto& r : ranges) {
    if (r.source_in_ms > source_ms &&
        (best < 0 || r.source_in_ms < best)) {
      best = r.source_in_ms;
    }
  }
  return best;
}

PreviewEngine::PaceStep PreviewEngine::PaceNextEditedFrameLocked(Impl* impl) {
  namespace clip = capture::export_::clip_planner;
  if (impl == nullptr || impl->edited_reader == nullptr ||
      impl->clip_ranges.empty()) {
    return PaceStep::kIdle;
  }
  const std::int64_t edited_dur = clip::EditedDurationMs(impl->clip_ranges);
  PreviewSourceReader* reader = impl->edited_reader.get();

  // 4-7c (design D5): while sound is streaming, AUDIO is the master clock —
  // the video chases the renderer's lock-free position and never leads it
  // (an audio glitch is far more audible than a ±1-frame video adjustment).
  // audio_target < 0 = no audio (or drained/paused): the pacer free-runs on
  // its fixed budget exactly as before this slice.
  std::int64_t audio_target_ms = -1;
  if (impl->audio_renderer != nullptr && impl->audio_renderer->playing()) {
    audio_target_ms = impl->audio_renderer->PositionEditedMs();
    if (impl->edited_pos_ms > audio_target_ms) {
      return PaceStep::kIdle;  // video is ahead — hold this tick
    }
  }
  // Per-frame chase decision (pure policy — see DecidePacerChase). Builds
  // the shared half of the input; each branch fills in the frame position
  // and whether repositioning is available.
  const auto chase_input_for = [&](std::int64_t frame_edited_ms,
                                   bool allow_chase_seek) {
    PacerChaseInput in;
    in.frame_edited_ms = frame_edited_ms;
    in.audio_edited_ms = audio_target_ms;
    in.edited_duration_ms = edited_dur;
    in.stale_streak = impl->stale_streak;
    in.awaiting_chase_frame = impl->awaiting_chase_frame;
    in.allow_chase_seek = allow_chase_seek;
    in.ms_since_chase_seek =
        impl->last_chase_seek.time_since_epoch().count() == 0
            ? -1
            : std::chrono::duration_cast<std::chrono::milliseconds>(
                  std::chrono::steady_clock::now() - impl->last_chase_seek)
                  .count();
    return in;
  };

  // Shared render tail: upload the decoded frame + compose it at its edited
  // position (overlays are SOURCE-keyed, so pass the frame's source time; Dart
  // sees the EDITED position + duration). Returns false (→ kIdle) on failure.
  const auto emit = [&](std::vector<BYTE>& bgra, std::int64_t source_ms,
                        std::int64_t edited_ms) -> bool {
    if (const HRESULT ensure_hr = impl->compositor.EnsureResources(
            impl->d3d_device.Get(), impl->d2d_context.Get(), reader->width(),
            reader->height());
        FAILED(ensure_hr)) {
      impl->last_render_failure_hr.store(static_cast<std::int32_t>(ensure_hr),
                                         std::memory_order_relaxed);
      NoteRenderFailure(impl, "pacer_ensure_resources");
      impl->edited_playing = false;
      // 4-7c: a dead video path must not keep playing sound alone. (The EOS
      // paths deliberately DON'T pause — audio self-drains its final buffer
      // to the plan end there.)
      if (impl->audio_renderer != nullptr) {
        impl->audio_renderer->Pause();
      }
      return false;
    }
    impl->last_video_width.store(reader->width());
    impl->last_video_height.store(reader->height());
    impl->d3d_context->UpdateSubresource(impl->compositor.video_texture(), 0,
                                         nullptr, bgra.data(),
                                         reader->width() * 4u, 0);
    // Adaptive budget: the edited-time distance between presented frames IS
    // the source's frame interval (the edited timeline is contiguous, and a
    // cut boundary still advances by one frame). Clamped so a seek jump or
    // a decimated skip can't stretch the budget.
    if (impl->last_presented_edited_ms >= 0) {
      const std::int64_t delta = edited_ms - impl->last_presented_edited_ms;
      if (delta > 0 && delta <= 100) {
        impl->paced_budget_ms.store(static_cast<int>(std::max<std::int64_t>(5, delta)),
                                    std::memory_order_relaxed);
      }
    }
    impl->last_presented_edited_ms = edited_ms;
    impl->edited_pos_ms = edited_ms;
    impl->timing_total.BeginFrame();
    ComposeAndHandoffLocked(impl, source_ms * 1000, edited_ms, edited_dur);
    return true;
  };

  // A presented frame that is STILL behind the sound must not burn a frame
  // budget — step again at once so decode runs at full speed until it
  // catches up (or the chase policy repositions).
  const auto step_for_emit = [&](bool ok, std::int64_t edited_ms) {
    if (!ok) return PaceStep::kIdle;
    return (audio_target_ms >= 0 &&
            edited_ms < audio_target_ms - kAudioChaseSlackMs)
               ? PaceStep::kRenderedBehind
               : PaceStep::kRendered;
  };

  // Decoding is NOT free (ReadNextFrame fully decodes each frame), so cap
  // forward reads at kMaxSkip per call: a long cut gap / keyframe lead-in then
  // returns kSkipping so the pacer RELEASES render_mutex between chunks (keeping
  // Pause/Seek/Close responsive) and steps again. The reader position + reorder
  // cursor persist across calls.
  constexpr int kMaxSkip = 8;

  if (clip::IsSourceMonotonic(impl->clip_ranges)) {
    // Cut path: decode FORWARD; cut-gap frames are skipped, which IS the cut
    // (matches the export monotonic path). EditedMsForKeptSourceMs is
    // well-defined and source-forward == edited-forward.
    //
    // LARGE gaps are SEEKED across (like the reorder path's boundaries)
    // instead of decode-crawled: the audio renderer — the master clock —
    // crosses a cut instantly via its slot seek, so crawling a multi-second
    // deleted segment at full-decode speed left the video seconds behind
    // the sound, frozen until it caught up (and on high-res sources it
    // never fully did). Small gaps still crawl: SeekTo lands on the
    // keyframe AT-OR-BEFORE the target, and this recorder does not pin
    // keyframe spacing (hardware-MFT default GOP, typically ~2-4s on
    // sparse-keyframe screen recordings) — when the GOP exceeds the
    // remaining gap the seek's lead-in decode is a SUPERSET of the crawl
    // it replaces. The threshold therefore sits above typical GOPs so a
    // seek near-always lands on a closer keyframe and wins. Follow-up
    // (issue): pin MF_MT_MAX_KEYFRAME_SPACING at record time, which
    // bounds every seek lead-in (scrub + reorder too) and lets this
    // threshold drop.
    constexpr std::int64_t kGapSeekThresholdMs = 3000;
    for (int i = 0; i < kMaxSkip; ++i) {
      if (shutting_down_.load()) return PaceStep::kIdle;
      std::vector<BYTE> bgra;
      std::int64_t ts_ms = 0;
      if (!reader->ReadNextFrame(&bgra, &ts_ms)) {
        NotifyEditedPlaybackCompleteLocked(impl);  // end of source
        return PaceStep::kIdle;
      }
      if (ts_ms < impl->edited_min_source_ms) {
        continue;  // gap-seek keyframe lead-in — never re-emit pre-gap frames
      }
      const auto edited =
          clip::EditedMsForKeptSourceMs(ts_ms, impl->clip_ranges);
      if (!edited.has_value()) {
        const std::int64_t next_in =
            NextKeptSourceInMsAfter(ts_ms, impl->clip_ranges);
        if (next_in >= 0 && next_in - ts_ms > kGapSeekThresholdMs) {
          reader->SeekTo(next_in);
          impl->edited_min_source_ms = next_in;
          clingfy::bridge::NativeLogPublisher::Instance().Debug(
              "Preview", "pacer seeked across a " +
                             std::to_string(next_in - ts_ms) +
                             "ms cut gap at source " + std::to_string(ts_ms) +
                             "ms");
          return PaceStep::kSkipping;
        }
        continue;  // small gap — crawl (decode-forward)
      }
      const auto chase = DecidePacerChase(
          chase_input_for(*edited, /*allow_chase_seek=*/true));
      impl->stale_streak = chase.next_stale_streak;
      if (chase.action == PacerChaseAction::kSeekToAudio) {
        // Way behind the sound and decode can't close it — reposition to
        // the audio clock like a scrub. The policy guarantees the target
        // sits clear of the tail, so it always maps into a kept window.
        const std::int64_t target_source = clip::SourceMsForEditedMs(
            chase.seek_target_edited_ms, impl->clip_ranges);
        reader->SeekTo(target_source);
        impl->edited_min_source_ms = target_source;
        impl->last_chase_seek = std::chrono::steady_clock::now();
        impl->awaiting_chase_frame = true;
        clingfy::bridge::NativeLogPublisher::Instance().Debug(
            "Preview",
            "pacer chase-seek to the audio clock: video was at edited " +
                std::to_string(*edited) + "ms, audio at " +
                std::to_string(audio_target_ms) + "ms");
        return PaceStep::kSkipping;
      }
      if (chase.action == PacerChaseAction::kDiscard) continue;
      impl->awaiting_chase_frame = false;
      return step_for_emit(emit(bgra, ts_ms, *edited), *edited);
    }
    return PaceStep::kSkipping;
  }

  // Reorder path (step 4-4): read each range's source window in TIMELINE order
  // via per-range backward seeks (the export reorder read model).
  // edited_range_idx + edited_reorder_base_ms are primed by Play/SeekTo and
  // advanced at each range boundary. The camera reader auto-seeks on the
  // backward playback_us jump; the zoom smoother easing across a boundary is a
  // known minor refinement (§5.4).
  const int n = static_cast<int>(impl->clip_ranges.size());
  for (int i = 0; i < kMaxSkip; ++i) {
    if (shutting_down_.load()) return PaceStep::kIdle;
    if (impl->edited_range_idx >= n) {
      NotifyEditedPlaybackCompleteLocked(impl);  // all ranges emitted
      return PaceStep::kIdle;
    }
    std::vector<BYTE> bgra;
    std::int64_t ts_ms = 0;
    if (!reader->ReadNextFrame(&bgra, &ts_ms)) {
      // A range ended at source EOS — advance to the next timeline range.
      impl->edited_reorder_base_ms +=
          impl->clip_ranges[impl->edited_range_idx].DurationMs();
      if (++impl->edited_range_idx >= n) {
        NotifyEditedPlaybackCompleteLocked(impl);
        return PaceStep::kIdle;
      }
      reader->SeekTo(impl->clip_ranges[impl->edited_range_idx].source_in_ms);
      // §5.4: the source clock jumped backward across the range boundary — snap
      // the zoom smoother to neutral (like the export ResetSmoothing) so it
      // doesn't ease across the discontinuity. The camera reader auto-seeks on
      // the backward playback_us.
      impl->zoom = ZoomState{};
      continue;
    }
    const auto& r = impl->clip_ranges[impl->edited_range_idx];
    if (ts_ms >= r.source_out_ms) {
      // Past this range's window → advance + seek (backward) to the next range.
      impl->edited_reorder_base_ms += r.DurationMs();
      if (++impl->edited_range_idx >= n) {
        NotifyEditedPlaybackCompleteLocked(impl);
        return PaceStep::kIdle;
      }
      reader->SeekTo(impl->clip_ranges[impl->edited_range_idx].source_in_ms);
      // §5.4: the source clock jumped backward across the range boundary — snap
      // the zoom smoother to neutral (like the export ResetSmoothing) so it
      // doesn't ease across the discontinuity. The camera reader auto-seeks on
      // the backward playback_us.
      impl->zoom = ZoomState{};
      continue;
    }
    if (ts_ms < r.source_in_ms) continue;  // keyframe lead-in — discard
    const std::int64_t edited =
        impl->edited_reorder_base_ms + (ts_ms - r.source_in_ms);
    // Decimation only here: a reorder reposition would need the range
    // cursor re-primed too, so the policy is told repositioning is
    // unavailable and keeps the picture moving by decimating instead.
    const auto chase =
        DecidePacerChase(chase_input_for(edited, /*allow_chase_seek=*/false));
    impl->stale_streak = chase.next_stale_streak;
    if (chase.action == PacerChaseAction::kDiscard) continue;
    impl->awaiting_chase_frame = false;
    return step_for_emit(emit(bgra, ts_ms, edited), edited);
  }
  return PaceStep::kSkipping;
}

void PreviewEngine::NotifyEditedPlaybackCompleteLocked(Impl* impl) {
  impl->edited_playing = false;
  std::string session_snapshot;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (shutting_down_.load()) {
      return;
    }
    session_snapshot = active_session_id_;
  }
  if (session_snapshot.empty()) {
    return;
  }
  clingfy::bridge::NativeLogPublisher::Instance().Debug(
      "Preview", "stitched playback complete at edited " +
                     std::to_string(impl->edited_pos_ms) + "ms");
  clingfy::bridge::PlayerEventPublisher::Instance().EmitPlayerState(
      session_snapshot, "completed");
}

void PreviewEngine::PrimeReorderStateLocked(Impl* impl, std::int64_t edited_ms) {
  namespace clip = capture::export_::clip_planner;
  if (impl == nullptr) return;
  impl->edited_range_idx = 0;
  impl->edited_reorder_base_ms = 0;
  if (impl->clip_ranges.empty()) return;
  const int idx = clip::ActiveIndexForEditedMs(edited_ms, impl->clip_ranges);
  const int n = static_cast<int>(impl->clip_ranges.size());
  std::int64_t base = 0;
  for (int i = 0; i < idx && i < n; ++i) {
    base += impl->clip_ranges[i].DurationMs();
  }
  impl->edited_range_idx = idx;
  impl->edited_reorder_base_ms = base;
}

void PreviewEngine::PacerLoop() {
  using clock = std::chrono::steady_clock;
  // Fixed ~30fps budget (the recorder default; the source fps is not trivially
  // exposed here — a source-fps-accurate pace is a later refinement, and there
  // is no preview audio yet to sync to). sleep_until an accumulating deadline so
  // decode jitter doesn't drift the pace fast; reset it if we fall behind so it
  // can't spiral into catch-up.
  auto next_deadline = clock::now();
  // Pacer telemetry (Debug level, ~2s cadence while playing): the A/V chase
  // in one line — video edited position vs the audio master clock plus the
  // step mix. The user-facing "laggy preview" class of bug is invisible in
  // ordinary logs (video position freezes silently); this line names which
  // side stalled without a debugger.
  auto telemetry_last = clock::now();
  int telemetry_rendered = 0;
  int telemetry_skipping = 0;
  int telemetry_idle = 0;
  // Stall watchdog (Info level, rate-limited): the same counters, but reported
  // when the pacer is playing and emits NOTHING. See DecidePacerStallReport.
  int stalled_windows = 0;
  bool stall_reported = false;
  while (!shutting_down_.load()) {
    Impl* impl = nullptr;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      impl = impl_.get();
    }
    PaceStep step = PaceStep::kIdle;
    if (impl != nullptr) {
      // render_mutex is held only for ONE bounded step (a kept frame or up to a
      // small skip cap) — released before the sleep so SetClips / SeekTo / Pause
      // / Close and the frame-server guard aren't blocked while paced.
      std::lock_guard<std::mutex> render_lock(impl->render_mutex);
      const bool paced = !shutting_down_.load() && impl->edited_mode &&
                         impl->edited_playing;
      if (!paced) {
        // Not playing: start the next window fresh so the first line after
        // a resume reports a real 2s sample, not counts stranded from
        // before the pause over an unbounded interval.
        telemetry_last = clock::now();
        telemetry_rendered = 0;
        telemetry_skipping = 0;
        telemetry_idle = 0;
      }
      if (paced) {
        step = PaceNextEditedFrameLocked(impl);
        switch (step) {
          case PaceStep::kRendered:
          case PaceStep::kRenderedBehind: ++telemetry_rendered; break;
          case PaceStep::kSkipping: ++telemetry_skipping; break;
          case PaceStep::kIdle: ++telemetry_idle; break;
        }
        const auto now = clock::now();
        if (now - telemetry_last >= std::chrono::milliseconds(2000)) {
          const std::int64_t audio_ms =
              impl->audio_renderer != nullptr
                  ? impl->audio_renderer->PositionEditedMs()
                  : -1;
          const bool audio_playing = impl->audio_renderer != nullptr &&
                                     impl->audio_renderer->playing();
          clingfy::bridge::NativeLogPublisher::Instance().Debug(
              "Preview",
              "pacer telemetry: video_edited=" +
                  std::to_string(impl->edited_pos_ms) +
                  "ms audio=" + std::to_string(audio_ms) +
                  "ms audio_playing=" + (audio_playing ? "1" : "0") +
                  " rendered=" + std::to_string(telemetry_rendered) +
                  " skipping=" + std::to_string(telemetry_skipping) +
                  " idle=" + std::to_string(telemetry_idle) + " per 2s");

          // The same numbers, escalated to Info ONLY when the pacer is playing
          // and producing nothing — the shape of the 35-hour burn that left no
          // trace in a release log (625 frames, one core, Debug-only evidence).
          const int stalled_before = stalled_windows;
          const auto stall = DecidePacerStallReport(PacerStallInput{
              telemetry_rendered, stalled_windows, stall_reported});
          stalled_windows = stall.next_stalled_windows;
          stall_reported = stall.next_stall_reported;
          if (stall.report == PacerStallReport::kStalled) {
            clingfy::bridge::NativeLogPublisher::Instance().Info(
                "Preview",
                "pacer STALLED: playing but no frame emitted for ~" +
                    std::to_string(stalled_windows * 2) +
                    "s. video_edited=" + std::to_string(impl->edited_pos_ms) +
                    "ms audio=" + std::to_string(audio_ms) +
                    "ms audio_playing=" + (audio_playing ? "1" : "0") +
                    " skipping=" + std::to_string(telemetry_skipping) +
                    " idle=" + std::to_string(telemetry_idle) + " per 2s");
          } else if (stall.report == PacerStallReport::kRecovered) {
            clingfy::bridge::NativeLogPublisher::Instance().Info(
                "Preview", "pacer recovered after ~" +
                               std::to_string(stalled_before * 2) +
                               "s without a frame");
          }

          telemetry_last = now;
          telemetry_rendered = 0;
          telemetry_skipping = 0;
          telemetry_idle = 0;
        }
      }
    }
    switch (step) {
      case PaceStep::kRenderedBehind:
        // Presented, but the sound is still ahead: no sleep — decode the
        // next frame immediately. The audio-ahead hold at the top of the
        // step is what stops the video from running past the sound, so
        // this cannot overrun.
        next_deadline = clock::now();
        break;
      case PaceStep::kRendered:
        // Pace by the MEASURED source frame interval (impl-adaptive), not
        // a fixed 30 fps: a 60 fps recording needs a ~16 ms budget or its
        // content advances at half wall-clock speed.
        next_deadline += std::chrono::milliseconds(
            impl != nullptr ? impl->paced_budget_ms.load(std::memory_order_relaxed)
                            : 33);
        {
          const auto now = clock::now();
          if (next_deadline > now) {
            std::this_thread::sleep_until(next_deadline);
          } else {
            next_deadline = now;  // fell behind — don't accumulate lag
          }
        }
        break;
      case PaceStep::kSkipping:
        // Mid-gap: render_mutex is released (scope ended) — step again almost
        // immediately so a large cut skips fast, yielding first so Pause / Seek /
        // Close interleave. No kept frame yet, so reset the pace anchor.
        next_deadline = clock::now();
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
        break;
      case PaceStep::kIdle:
        next_deadline = clock::now();
        std::this_thread::sleep_for(std::chrono::milliseconds(15));
        break;
    }
  }
}

void PreviewEngine::SetClips(
    const std::string& session_id,
    std::vector<capture::export_::clip_planner::ClipKeptRange> ranges) {
  winrt_playback::MediaPlayer player_snapshot{nullptr};
  Impl* impl = nullptr;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    // Same stale-session discipline as SetColorGrade: a clip edit racing a Close
    // (or targeting a non-active session) is a silent no-op.
    if (!session_id.empty() && session_id != active_session_id_) {
      return;
    }
    if (impl_ == nullptr) {
      return;
    }
    impl = impl_.get();
    player_snapshot = impl_->player;
  }
  const bool now_edited = RangesAreEdited(ranges);

  // Coordinate the render mode OUTSIDE mutex_. The compose path needs
  // render_mutex, and the lock order everywhere is render_mutex → mutex_
  // (HandleVideoFrame + ComposeAndHandoffLocked), so we must NOT take
  // render_mutex while holding mutex_. This runs on the Flutter platform thread,
  // serialized with Close, so `impl` cannot be torn down under us here.
  if (now_edited && player_snapshot != nullptr) {
    // Enter stitched-preview mode: pause the MediaPlayer so its frame server
    // stops overwriting the edited frame.
    try {
      player_snapshot.Pause();
    } catch (winrt::hresult_error const&) {
      // Best-effort — MediaPlayer errors surface via the MediaFailed event.
    }
  }
  std::lock_guard<std::mutex> render_lock(impl->render_mutex);
  if (shutting_down_.load()) {
    return;
  }
  // 4-6: preserve the playhead across a clip edit by anchoring it to the
  // SOURCE moment it was showing — the edited timeline just changed shape, so
  // the old edited position points at different content. Map old-edited →
  // source (old ranges) → new-edited (new ranges); a source moment the edit
  // cut away keeps the old position, which RenderEditedFrameLocked clamps
  // into the new duration (nearest-content behavior).
  if (impl->edited_mode && now_edited && !impl->clip_ranges.empty()) {
    namespace clip = capture::export_::clip_planner;
    const std::int64_t source_anchor =
        clip::SourceMsForEditedMs(impl->edited_pos_ms, impl->clip_ranges);
    const auto remapped = clip::EditedMsForKeptSourceMs(source_anchor, ranges);
    if (remapped.has_value()) {
      impl->edited_pos_ms = *remapped;
    }
  }
  // clip_ranges is read by the PACER THREAD under render_mutex, so it MUST be
  // written under render_mutex (never mutex_) or the move-assign races the
  // pacer's mid-iteration read → heap use-after-free.
  impl->clip_ranges = std::move(ranges);
  const bool was_edited = impl->edited_mode;
  if (now_edited) {
    impl->edited_mode = true;
    // A clip edit STOPS continuous playback: the timeline just changed (and may
    // now be non-monotonic / reorder, which the pacer must never pace). Show the
    // edited frame paused; the user re-presses Play, which re-arms the pacer only
    // for a monotonic session. (Slice 6 debounces the trim-drag storm.)
    impl->edited_playing = false;
    RenderEditedFrameLocked(impl, impl->edited_pos_ms);
    // Step 4-7c: build/update the audio plan for the stitched session — after
    // consuming any pending mid-stream failure (D7 rebuild-once), so the
    // SetSlots below always targets a live renderer.
    HandleAudioRenderErrorLocked(impl);
    if (impl->audio_renderer != nullptr) {
      // Defers the pump rebuild to the next Play (on the render thread).
      impl->audio_renderer->SetSlots(BuildPreviewAudioSlots(impl->clip_ranges));
    } else {
      OpenPreviewAudioRendererLocked(impl);
    }
    if (!was_edited) {
      namespace clip = capture::export_::clip_planner;
      clingfy::bridge::NativeLogPublisher::Instance().Debug(
          "Preview",
          "stitched preview ON: " + std::to_string(impl->clip_ranges.size()) +
              " ranges, reorder=" +
              (clip::IsSourceMonotonic(impl->clip_ranges) ? "false" : "true") +
              ", editedDur=" +
              std::to_string(clip::EditedDurationMs(impl->clip_ranges)) +
              "ms, audio=" +
              (impl->audio_renderer != nullptr ? "on" : "off"));
    }
  } else if (impl->edited_mode) {
    // Passthrough (no real cut): leave stitched mode; the MediaPlayer path
    // resumes producing frames (audio included — its track was never touched).
    impl->edited_mode = false;
    impl->edited_playing = false;
    impl->edited_reader.reset();
    impl->audio_renderer.reset();
    clingfy::bridge::NativeLogPublisher::Instance().Debug(
        "Preview", "stitched preview OFF (passthrough — no real cut)");
  }
}

void PreviewEngine::SetAudioMix(const std::string& session_id, double gain_db,
                                double volume_percent) {
  winrt_playback::MediaPlayer player_snapshot{nullptr};
  Impl* impl = nullptr;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    // Same stale-session discipline as the other setters; an EMPTY id
    // applies to the active session (macOS optional-sessionId semantics).
    if (!session_id.empty() && session_id != active_session_id_) {
      return;
    }
    if (impl_ == nullptr) {
      return;
    }
    impl = impl_.get();
    player_snapshot = impl_->player;
  }
  const double gain = std::clamp(gain_db, 0.0, 24.0);
  const double volume = std::clamp(volume_percent, 0.0, 100.0);
  {
    std::lock_guard<std::mutex> render_lock(impl->render_mutex);
    if (shutting_down_.load()) {
      return;
    }
    impl->audio_gain_db = gain;
    impl->audio_volume_percent = volume;
    if (impl->audio_renderer != nullptr) {
      // Applies to samples decoded from now on (D6) — the export's exact
      // two-stage semantics via the shared resolvers (normalize stays
      // export-only, macOS parity). Separated sessions (D9) get mic-only
      // gain; legacy premix keeps the whole-track stages.
      if (impl->audio_separated) {
        impl->audio_renderer->SetSeparatedGainStages(
            capture::export_::ResolveSeparatedAudioStages(
                gain, volume, /*normalize=*/false,
                /*target_loudness_dbfs=*/-16.0, /*mic_peak_linear=*/0.0));
      } else {
        impl->audio_renderer->SetGainStages(
            capture::export_::ResolveAudioGainStages(
                gain, volume, /*normalize=*/false,
                /*target_loudness_dbfs=*/-16.0, /*source_peak_linear=*/0.0));
      }
    }
  }
  // Passthrough master volume — a WinRT call, outside both locks.
  // Attenuation only (MediaPlayer.Volume is 0..1): gain on an uncut preview
  // stays export-only, the documented D6 gap. Harmless in edited mode (the
  // MediaPlayer is paused there), and it keeps the volume correct across a
  // later passthrough transition.
  try {
    player_snapshot.Volume(volume / 100.0);
  } catch (winrt::hresult_error const&) {
    // Best-effort — MediaPlayer errors surface via MediaFailed.
  }
}

void PreviewEngine::StartVoiceCleanupWorkerLocked(Impl* impl,
                                                  const std::string& session_id,
                                                  float wet_mix,
                                                  std::uint64_t generation) {
  // Caller guarantees no worker is in flight, so any joinable handle is a
  // FINISHED worker — join it before reassigning. Never join an in-flight one
  // under render_mutex (the inline-dispatch path would run its completion,
  // which wants render_mutex, on the joined thread -> deadlock); the mode-
  // change path instead cancels the live worker and lets ITS completion start
  // the next pass. The self-id guard covers the degenerate inline-dispatch case
  // where this runs on the worker thread itself.
  if (impl->cleanup_thread.joinable()) {
    if (impl->cleanup_thread.get_id() == std::this_thread::get_id()) {
      impl->cleanup_thread.detach();
    } else {
      impl->cleanup_thread.join();
    }
  }
  impl->voice_cleanup_computing = true;
  impl->cleanup_cancel.store(false);

  const std::wstring mic = impl->mic_audio_path;
  const std::filesystem::path out =
      PreviewCleanedMicPath(session_id, generation);
  try {
    impl->cleanup_thread =
        std::thread([this, impl, session_id, mic, out, wet_mix, generation]() {
          const bool ok = capture::export_::ProduceCleanedMic(
              mic, out.u8string(),
              [impl] { return impl->cleanup_cancel.load(); }, wet_mix);
          const std::wstring out_w = out.wstring();
          clingfy::bridge::PlatformThreadDispatcher::Instance().Post(
              [this, session_id, ok, out_w, wet_mix, generation] {
                OnPreviewCleanedMicReady(session_id, ok, out_w, wet_mix,
                                         generation);
              });
        });
  } catch (const std::system_error&) {
    // Thread/handle exhaustion: clear the guard so a later toggle can retry
    // instead of silently no-opping for the rest of the session.
    impl->voice_cleanup_computing = false;
    clingfy::bridge::NativeLogPublisher::Instance().Warn(
        "Preview", "voice cleanup worker thread could not be started");
  }
}

void PreviewEngine::SetVoiceCleanup(const std::string& session_id, bool enabled,
                                    float wet_mix) {
  Impl* impl = nullptr;
  std::string active;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    // Stale/empty session-id semantics match the other setters.
    if (!session_id.empty() && session_id != active_session_id_) {
      return;
    }
    if (impl_ == nullptr) {
      return;
    }
    impl = impl_.get();
    active = active_session_id_;
  }

  std::lock_guard<std::mutex> render_lock(impl->render_mutex);
  if (shutting_down_.load()) {
    return;
  }
  // No change: same enabled state AND (if on) same strength.
  if (impl->voice_cleanup_enabled == enabled &&
      (!enabled || impl->voice_cleanup_wet_mix == wet_mix)) {
    return;
  }
  impl->voice_cleanup_enabled = enabled;
  impl->voice_cleanup_wet_mix = wet_mix;

  // Only a separated session with a mic sidecar has anything to denoise. A
  // premix or system-only session just records the flags (a mic reselected in
  // a later session would honor them).
  if (!impl->audio_separated || impl->mic_audio_path.empty()) {
    return;
  }

  // Only a LIVE renderer (edited mode) needs a rebuild to swap the mic. In
  // passthrough the audio_renderer is null (the MediaPlayer drives the premix,
  // so a mic swap has no audible effect and would just build an idle WASAPI
  // stream holding the temp open): record the flags and let the renderer built
  // on the first cut pick the right mic via OpenPreviewAudioRendererLocked.
  if (!enabled) {
    // Back to the raw mic immediately — no decode needed.
    impl->use_cleaned_mic = false;
    if (impl->audio_renderer != nullptr) {
      RebuildPreviewAudioRendererLocked(impl);
    }
    return;
  }

  if (impl->cleaned_mic_ready && impl->cleaned_wet_mix == wet_mix) {
    // Already produced at this strength: swap the cleaned mic straight in.
    impl->use_cleaned_mic = true;
    if (impl->audio_renderer != nullptr) {
      RebuildPreviewAudioRendererLocked(impl);
    }
    return;
  }

  // (Re)compute for this strength. Any cleaned file in use is for a different
  // strength now — drop back to the raw mic (releasing its handle) and delete
  // the stale file before the new worker runs.
  if (impl->use_cleaned_mic) {
    impl->use_cleaned_mic = false;
    if (impl->audio_renderer != nullptr) {
      RebuildPreviewAudioRendererLocked(impl);
    }
  }
  if (impl->cleaned_mic_ready) {
    std::error_code ec;
    std::filesystem::remove(impl->cleaned_mic_path, ec);
    impl->cleaned_mic_ready = false;
    impl->cleaned_mic_path.clear();
  }
  // If a worker is already running (for a now-stale strength), don't join it
  // here — cancel it and let its completion start the next pass for the
  // current strength. Otherwise start one now.
  if (impl->voice_cleanup_computing) {
    impl->cleanup_cancel.store(true);
    return;
  }
  StartVoiceCleanupWorkerLocked(impl, active, wet_mix,
                                ++impl->voice_cleanup_generation);
}

void PreviewEngine::OnPreviewCleanedMicReady(const std::string& session_id,
                                             bool ok,
                                             const std::wstring& cleaned_path,
                                             float wet_mix,
                                             std::uint64_t generation) {
  const std::filesystem::path out(cleaned_path);
  Impl* impl = nullptr;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (impl_ == nullptr || session_id != active_session_id_) {
      // Session closed or switched while computing: drop the orphan temp.
      std::error_code ec;
      std::filesystem::remove(out, ec);
      return;
    }
    impl = impl_.get();
  }

  std::lock_guard<std::mutex> render_lock(impl->render_mutex);
  const bool current = generation == impl->voice_cleanup_generation;
  if (!current) {
    // A superseded worker (the mode was toggled again before it finished): it
    // owns its own generation-tagged temp and never the live worker's state.
    std::error_code ec;
    std::filesystem::remove(out, ec);
    return;
  }
  impl->voice_cleanup_computing = false;

  const bool want_cleaned = !shutting_down_.load() && impl->voice_cleanup_enabled;
  if (ok && want_cleaned && impl->voice_cleanup_wet_mix == wet_mix) {
    impl->cleaned_mic_path = cleaned_path;
    impl->cleaned_wet_mix = wet_mix;
    impl->cleaned_mic_ready = true;
    impl->use_cleaned_mic = true;
    // Only rebuild a live renderer (edited mode). In passthrough the flags are
    // enough — the renderer built on the next cut opens the cleaned mic.
    if (impl->audio_renderer != nullptr) {
      RebuildPreviewAudioRendererLocked(impl);
    }
    return;
  }

  // Not applied: failed, cancelled, disabled, or the requested strength moved
  // on while this pass ran. Drop this worker's temp.
  std::error_code ec;
  std::filesystem::remove(out, ec);
  if (!ok && want_cleaned && impl->voice_cleanup_wet_mix == wet_mix) {
    clingfy::bridge::NativeLogPublisher::Instance().Warn(
        "Preview", "preview voice cleanup failed; keeping the raw mic");
  }
  // Hand off: if cleanup is still wanted at a strength we don't have cached and
  // nothing is now computing, start the next pass (covers the cancel-and-
  // restart on a mode change).
  if (want_cleaned && !impl->voice_cleanup_computing &&
      impl->audio_separated && !impl->mic_audio_path.empty() &&
      !(impl->cleaned_mic_ready &&
        impl->cleaned_wet_mix == impl->voice_cleanup_wet_mix)) {
    StartVoiceCleanupWorkerLocked(impl, session_id, impl->voice_cleanup_wet_mix,
                                  ++impl->voice_cleanup_generation);
  }
}

}  // namespace clingfy::preview
