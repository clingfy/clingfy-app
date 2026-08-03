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

#include "Capture/Export/clip_playback_planner.h"
#include "Capture/Export/color_grade.h"
#include "Core/canvas_composition.h"
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
  // Polish: the recording's natural size from screen.meta.json (0 = unknown).
  // Sizes the shared texture to the video's ASPECT (fitted in the 1280x720
  // budget) so the compositor letterbox is an exact fit — no bars baked into
  // the pixels (which doubled up with Flutter's AspectRatio letterbox on
  // non-16:9 recordings) and the camera bubble's canvas matches the export's
  // auto-layout canvas aspect.
  int video_width_hint = 0;
  int video_height_hint = 0;
  // Canvas presets, so the texture starts at the CANVAS aspect rather than the
  // video's — a 16:9 recording in a 9:16 canvas previewed as 16:9 while the
  // export was portrait. Empty (a caller that has not plumbed them yet) falls
  // back to the old video-aspect sizing, so this stays backwards compatible.
  std::string layout_preset;
  std::string resolution_preset;
  // Audio separation (design D9): the mic / system sidecar paths from the
  // project reader (existence-gated there; empty = absent). The engine runs
  // the decode probe once at Open and, when either passes, the edited-path
  // renderer goes dual-pump with mic-only gain — the premix in screen.mov
  // stays the fallback (and the uncut passthrough MediaPlayer's source).
  std::wstring mic_audio_path;
  std::wstring system_audio_path;
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

// What to do when a preview setting (color grade, camera composition) changes.
enum class PausedRepaintAction {
  kSkipPlaying,      // playing: the next natural frame already carries it.
  kRepaintRetained,  // not advancing: re-composite the frame already on screen.
  kNudgeSeek,        // nothing composed yet: fall back to the 1ms seek nudge.
};

// Policy for reflecting a settings change on a preview that is NOT advancing.
//
// The seek nudge above cannot be the primary path. It forces a decode for a
// cosmetic change, and at end-of-stream the ±1ms target lands past the end so
// no frame is ever produced -- which is why an edit made after pausing OR
// finishing playback stayed invisible while the same edit during playback
// worked. Re-compositing the retained frame costs one D2D compose instead, and
// works at EOS because it never asks the player for anything.
//
// Pure and lock-free for unit testing; the engine supplies the two facts.
PausedRepaintAction DecidePausedRepaint(bool is_playing,
                                        bool has_composed_frame);

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
  //     the running session is ORPHANED (Dart is the single serialized
  //     driver, so it can only ask for a new session after its owner is
  //     gone — a Dart hot restart survives the native process, as does a
  //     watchdog-abandoned close). Open closes the stale session and
  //     proceeds (last-open-wins, matching macOS). Refusing here used to
  //     wedge every future preview until a full app restart.
  OpenResult Open(const OpenArgs& args);

  // Pure decision for Open()'s orphan reconcile: should an incoming Open
  // close the currently-running session first? True only for a NON-empty
  // incoming id that differs from the active one while the engine runs.
  // Same-session re-entry stays idempotent; a not-running engine has
  // nothing to close. Exposed for tests; keep in sync with the reconcile
  // block at the top of Open().
  static bool ShouldReconcileStaleSession(
      bool running, const std::string& active_session_id,
      const std::string& incoming_session_id);

  // Windows resumed from Modern Standby / suspend. The D3D11 device and
  // WinRT frame server backing an open session are frequently invalid
  // after a resume (DXGI_ERROR_DEVICE_REMOVED) — but the failure only
  // surfaces once playback next touches the device, and the render loop
  // takes ~90 failed frames to die. Instead of waiting for that, tell
  // Dart the session is suspect NOW via a `previewInvalidated` player
  // event; Dart closes and reopens the preview in place (same session
  // id), rebuilding the device, reader, and texture. No-op when no
  // session is running. Called from FlutterWindow::MessageHandler on
  // WM_POWERBROADCAST / PBT_APMRESUMEAUTOMATIC (the platform thread),
  // but safe from any thread — the publisher marshals internally.
  void OnSystemResumed();

  // Pure decision for OnSystemResumed(): only a running engine with a
  // non-empty active session has anything to invalidate. Exposed for
  // tests; keep in sync with OnSystemResumed().
  static bool ShouldInvalidateOnSystemResume(
      bool running, const std::string& active_session_id);

  struct TextureSize {
    int width = 0;
    int height = 0;
  };
  // Pure (exposed for tests): the shared-texture size for a session — the
  // recording's aspect fitted inside the historical 1280x720 budget,
  // even-aligned, with a small floor. Unknown hints (<= 0) keep 1280x720.
  static TextureSize ComputePreviewTextureSize(int video_width_hint,
                                               int video_height_hint);

  // The shared-texture size for a session's CANVAS, which is what the preview
  // must actually match.
  //
  // The texture used to be sized to the VIDEO aspect. That is wrong as soon as
  // the canvas aspect differs — a 16:9 recording inside a 9:16 reel canvas
  // previewed as 16:9, so switching the layout preset changed nothing on screen
  // while the export changed completely. The canvas comes from
  // `ResolveTargetSize(source, layout, resolution)`; only its ASPECT is used
  // here, because the texture stays inside the 1280x720 budget regardless of
  // the user's export resolution.
  //
  // Falls back to the video aspect when the presets are empty or degenerate, so
  // a caller that has not learned the presets yet behaves exactly as before.
  static TextureSize ComputeCanvasTextureSize(int video_width_hint,
                                              int video_height_hint,
                                              const std::string& layout_preset,
                                              const std::string& resolution_preset);

  // Pure (exposed for tests): does a canvas push need the preview session
  // REBUILT, because the layout/resolution it carries changes the shared
  // texture's aspect?
  //
  // A shared texture cannot be resized in place — Flutter holds the handle for
  // the lifetime of the registration — so the only way a mid-session layout
  // switch reshapes the preview is close + reopen. Rather than invent a
  // protocol for that, the engine reuses `previewInvalidated`: Dart already
  // rebuilds in place on that event (same session id, no phase change, no
  // remount) and re-pushes the editing state afterwards.
  //
  // Returns false unless a rebuild is genuinely required, because every true
  // costs a close+reopen:
  //   - Source dims unknown (no frame decoded yet). This is the loop guard.
  //     Sizing from unknown dims yields the default 1280x720, which mismatches
  //     any portrait texture and would ask for a rebuild forever.
  //   - Current texture size unknown (no session open).
  //   - The required size already matches. This is the TERMINATION property:
  //     the rebuild re-pushes the canvas, and that second push must be a
  //     no-op or the rebuild would trigger another rebuild.
  //
  // Note a pure RESOLUTION change (720p -> 4K) does not rebuild: the texture
  // is aspect-only inside a fixed budget, so the pixels on screen are
  // unchanged and only the export target moves.
  static bool DecideCanvasAspectRebuild(int source_width, int source_height,
                                        int current_texture_width,
                                        int current_texture_height,
                                        const std::string& layout_preset,
                                        const std::string& resolution_preset);

  // Editing port (step 4-5) — pure decision for Play() on an edited session:
  // pressing Play with the playhead at (or within one frame of) the edited
  // end RESTARTS from 0, macOS IsAtEnd parity — otherwise Play at the end
  // renders one final frame, the pacer immediately EOSes, and the button
  // feels dead. Non-positive durations never restart (nothing to play).
  // Exposed for tests; keep in sync with Play()'s edited branch.
  static bool ShouldRestartEditedPlaybackFromEnd(std::int64_t edited_pos_ms,
                                                 std::int64_t edited_duration_ms);

  // ---- Edited-pacer chase policy (pure, exposed for tests) ----------------
  //
  // The edited preview's audio renderer is the MASTER clock (design 4-7c
  // D5), so the video pacer must chase it. The naive chase — discard every
  // frame that is behind the sound — assumes video decode runs well past
  // realtime. The preview reader's SOFTWARE decode does not (measured
  // ~1.3-1.7x at 1080p Release, ~1.0x Debug, worse at higher resolutions),
  // so at zero margin an unbounded discard freezes the picture completely
  // while audio plays on (user-reported, 2026-07-20). This policy keeps the
  // picture moving in that regime and bounds the lip-sync trail.
  //
  // Tunables are public so tests assert against named values, not magic
  // numbers.
  //   kAudioChaseSlackMs   — a frame within this of the sound is "in sync".
  //   kStaleEmitEvery      — emit every Nth stale frame anyway (late-frame
  //                          decimation: the picture always advances).
  //                          Discarding does NOT speed up catch-up (the
  //                          decode already happened) — it only saves the
  //                          compose+upload — so this stays small: measured
  //                          17-25 presented fps at N=2 vs 8 at N=6, for
  //                          the same content rate.
  //   kChaseSeekDeficitMs  — trail past this and a reposition is warranted.
  //                          Measured on a 1080p60 recording: a chase seek
  //                          costs a keyframe lead-in decode (~2 s of
  //                          blacked-out catch-up, since the recorder does
  //                          not pin GOP — issue #294), so the trigger must
  //                          sit well above that or the seek costs more
  //                          than it recovers.
  //   kChaseSeekCooldownMs — minimum spacing between chase seeks.
  //   kChaseSeekEndGuardMs — never chase INTO the tail: the edited end maps
  //                          one-past-the-last-kept-frame, so a seek there
  //                          floors out every remaining frame and freezes
  //                          the picture for good. Decimation carries the
  //                          tail instead.
  static constexpr std::int64_t kAudioChaseSlackMs = 33;
  static constexpr int kStaleEmitEvery = 2;
  static constexpr std::int64_t kChaseSeekDeficitMs = 5000;
  static constexpr std::int64_t kChaseSeekCooldownMs = 3000;
  static constexpr std::int64_t kChaseSeekEndGuardMs = 1000;

  enum class PacerChaseAction { kEmit, kDiscard, kSeekToAudio };

  struct PacerChaseInput {
    // The decoded frame's position on the edited timeline.
    std::int64_t frame_edited_ms = 0;
    // The audio master clock, or < 0 when this session has no sound (the
    // pacer then free-runs on its own budget — every frame emits).
    std::int64_t audio_edited_ms = -1;
    std::int64_t edited_duration_ms = 0;
    // Consecutive stale frames discarded so far.
    int stale_streak = 0;
    // Elapsed since the last chase seek; < 0 = never chased.
    std::int64_t ms_since_chase_seek = -1;
    // A chase seek is in flight: the next frame that clears the lead-in
    // floor IS the frame we repositioned to, so it emits unconditionally.
    // Without this the post-seek frame is still "stale" (the keyframe
    // lead-in decode let audio advance), so a long lead-in would trigger
    // another chase — seek, decode, discard, seek — and the picture would
    // never advance at all.
    bool awaiting_chase_frame = false;
    // The reorder branch cannot reposition (its range cursor would need
    // re-priming), so it decimates only.
    bool allow_chase_seek = true;
  };

  struct PacerChaseDecision {
    PacerChaseAction action = PacerChaseAction::kEmit;
    // Valid for kSeekToAudio: where to reposition, in edited ms.
    std::int64_t seek_target_edited_ms = 0;
    int next_stale_streak = 0;
  };

  // Pure decision for one decoded frame. See the tunables above.
  static PacerChaseDecision DecidePacerChase(const PacerChaseInput& input);

  // --- Pacer stall watchdog -------------------------------------------------
  //
  // A dev build was once found burning ~0.7 of a core for 35 hours with a
  // preview session open that had rendered 625 frames in that time, and
  // NOTHING in the release log said so: the per-window pacer line is Debug,
  // which release builds do not surface, so the only evidence was Task
  // Manager. The condition is cheap to name — the pacer is PLAYING yet
  // emitted no frame across a whole telemetry window — and that is what this
  // reports, at Info, so the next occurrence is diagnosable from the log
  // instead of requiring the process to be caught alive.
  //
  // Deliberately NOT "promote the 2s line to Info": that would put a line
  // every 2 seconds into every release log for the entire duration of every
  // normal playback, which is how a log stops being read at all.

  // Windows are the telemetry cadence (~2s each).
  static constexpr int kPacerStallOnsetWindows = 15;   // ~30s before the first
  static constexpr int kPacerStallRepeatWindows = 30;  // then ~every 60s

  enum class PacerStallReport { kNone, kStalled, kRecovered };

  struct PacerStallInput {
    // Frames emitted during the window that just closed.
    int rendered_in_window = 0;
    // Consecutive stalled windows BEFORE this one.
    int stalled_windows = 0;
    // A stall has already been reported for this run of windows.
    bool stall_reported = false;
  };

  struct PacerStallDecision {
    PacerStallReport report = PacerStallReport::kNone;
    int next_stalled_windows = 0;
    bool next_stall_reported = false;
  };

  // Pure: rate-limits the stall report so a long stall logs on onset and then
  // periodically, and logs once on recovery. Recovery is only reported when a
  // stall was actually reported — a brief gap that never crossed the onset
  // threshold must not produce a "recovered" line for an event nobody saw.
  static PacerStallDecision DecidePacerStallReport(
      const PacerStallInput& input);

  // Pure (exposed for tests): the next kept range's source_in_ms strictly
  // AFTER `source_ms`, or -1 when none follows. The monotonic pacer uses it
  // to SEEK across a large cut gap instead of decode-crawling every deleted
  // frame — the audio renderer (the master clock) crosses a cut instantly
  // via its slot seek, so a crawl left the video seconds behind the sound,
  // frozen while it caught up (user-visible lag after deleting a middle
  // segment). Ranges are the engine's clip_ranges (source-monotonic here).
  static std::int64_t NextKeptSourceInMsAfter(
      std::int64_t source_ms,
      const std::vector<capture::export_::clip_planner::ClipKeptRange>&
          ranges);

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

  // Editing port (color): update the live color grade for the inline preview.
  // Driven by Dart's previewSetColorGrade on every slider tick / auto-enhance
  // toggle. Applies to the VIDEO ONLY (the cursor halo and camera bubble stay
  // ungraded — macOS preview parity; the export grades video+cursor+clicks).
  // A stale session_id is a silent no-op. Cheap and thread-safe; the D2D
  // effect chain (re)builds on the frame thread at the next composited frame,
  // and a PAUSED preview is nudged to recomposite immediately, exactly like
  // camera edits.
  void SetColorGrade(const std::string& session_id,
                     const capture::export_::color::ColorGrade& grade);

  // Canvas framing (background colour, padding, corner radius) for the live
  // preview. Driven by Dart's previewSetCanvas on every canvas edit.
  //
  // The composition is resolution-independent (fractions of the canvas's
  // shorter side, see Core/canvas_composition.h) precisely because this
  // surface is capped at kTextureWidth x kTextureHeight while the export
  // renders at the user's chosen resolution — raw pixels would make the
  // preview's padding ~3x the export's at 4K.
  //
  // The background is NOT graded, matching the existing rule that the cursor
  // halo and camera bubble stay outside the colour chain.
  //
  // A stale session_id is a silent no-op. Cheap and thread-safe; a PAUSED
  // preview repaints immediately via RepaintPausedPreview() with no seek and
  // no decode.
  // Takes the RAW Dart args (export-output pixels + presets) and normalises them
  // here, because only the engine knows the source dimensions that
  // ResolveTargetSize needs to work out the export canvas.
  void SetCanvasComposition(const std::string& session_id,
                            const core::CanvasFramingArgs& framing);

  // The canvas framing last pushed from Dart. Read on the frame thread while
  // compositing; guarded by render_mutex.
  core::CanvasComposition canvas_composition_for_testing();

  // Editing port (clips, step 4-1): store the edited-timeline kept ranges for
  // the inline preview. Driven by Dart's previewSetClips on open and on every
  // clip edit (split / cut / trim / drag-reorder), in TIMELINE order — the same
  // wire shape the export router parses (ReadClipRangesArg). A stale session_id
  // is a silent no-op. Slice 4-1 only STORES the ranges (the stitched decode
  // that honors them lands in the following slices); a passthrough list (no real
  // cut) leaves the preview byte-identical to today. Cheap + thread-safe.
  void SetClips(
      const std::string& session_id,
      std::vector<capture::export_::clip_planner::ClipKeptRange> ranges);

  // Editing port (audio, step 4-7d — design D6): the live preview audio mix.
  // `gain_db` [0,24] amplifies (clamped, export/macOS parity), then
  // `volume_percent` [0,100] attenuates. Applies to the edited-session
  // renderer's FUTURE samples immediately (no re-decode) and to the
  // passthrough MediaPlayer's master volume (attenuation only there —
  // MediaPlayer.Volume is 0..1, so gain on an UNCUT preview stays
  // export-only: the documented D6 gap). Stored on the session so a
  // renderer opened later (first clip edit) starts with the current mix,
  // mirroring macOS's pending-open audioMix override. A stale session_id is
  // a silent no-op; an empty one applies to the active session (macOS
  // optional-sessionId semantics). Driven by `updateAudioPreview` (the
  // method Dart actually sends, debounced 150 ms during slider drags), the
  // previewSetAudioMix/previewSetAudioGainDb dispatch aliases, and the
  // audio args riding every processVideo (editor open + standby resync).
  void SetAudioMix(const std::string& session_id, double gain_db,
                   double volume_percent);

  // Voice cleanup (Phase 4, preview WYSIWYG): denoise the preview's mic track
  // so the live preview matches what the export bakes. `enabled` runs the mic
  // sidecar through RNNoise (Capture/Export/mic_cleanup) on a background
  // thread; when the cleaned file is ready the mic pump is rebuilt to play it
  // (marshaled back to the platform thread). Disabling rebuilds immediately on
  // the raw mic. Only meaningful on a separated (sidecar) session; a premix or
  // mic-less session is a no-op. Stale/empty session-id semantics match the
  // other setters. On Windows this is the analog of macOS's
  // previewSetVoiceCleanup re-resolving which mic FILE the preview plays.
  void SetVoiceCleanup(const std::string& session_id, bool enabled,
                       float wet_mix);

  // For tests / observability.
  std::int64_t current_texture_id() const;

 private:
  PreviewEngine() = default;
  ~PreviewEngine();
  PreviewEngine(const PreviewEngine&) = delete;
  PreviewEngine& operator=(const PreviewEngine&) = delete;

  // Voice-cleanup background-pass completion, marshaled back to the platform
  // thread. Rebuilds the mic pump onto `cleaned_path` when the session is still
  // current, the toggle is still on, and `wet_mix` still matches the requested
  // strength (a mode change mid-compute discards a stale result); otherwise
  // drops the temp file.
  // `generation` identifies the worker; only the CURRENT generation clears
  // `computing`, applies the result, or hands off to the next pass — a
  // superseded worker (mode changed) just drops its temp.
  void OnPreviewCleanedMicReady(const std::string& session_id, bool ok,
                                const std::wstring& cleaned_path, float wet_mix,
                                std::uint64_t generation);

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

  // Phase 10.4: releases a texture registered during an Open attempt that
  // failed AFTER RegisterExternalTexture (path-resolution / MediaPlayer
  // setup). Routes through the same async-unregister path as Close so
  // Flutter can never call ObtainSurfaceDescriptor against a freed Impl
  // (use-after-free) and the texture id is not leaked. Clears texture_id_
  // and shared_handle_ok_; moves impl_ into the teardown context.
  void UnwindFailedOpenTexture(const std::string& session_id);

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
  // Phase 10.4: counts a per-frame render failure (EnsureResources /
  // frame-copy / EndDraw). After a run of consecutive failures it emits
  // PREVIEW_RENDER_ERROR as playerError + previewFailed exactly once per
  // session — before this, a permanently dead render loop froze the image
  // while the heartbeat kept the playhead moving and the user got no
  // signal at all. The counter lives on the Impl; the success path resets
  // it. (Declared after `struct Impl;` — the parameter needs the name.)
  void NoteRenderFailure(Impl* impl, const char* stage);

  // Start a background cleanup pass for `wet_mix` under `generation`. Caller
  // holds render_mutex and guarantees no worker is in flight (computing ==
  // false), so the only thread joined here is a FINISHED handle — never an
  // in-flight one (joining that under the lock could deadlock the inline
  // dispatch path).
  void StartVoiceCleanupWorkerLocked(Impl* impl, const std::string& session_id,
                                     float wet_mix, std::uint64_t generation);

  // Editing port (clips, step 4-3): the shared compose + handoff tail, factored
  // out of HandleVideoFrame so BOTH the MediaPlayer frame path and the edited
  // (stitched) frame path draw + hand off + emit the playerTick identically. The
  // caller holds impl->render_mutex, has run EnsureResources, and has already
  // filled the compositor's video surface/texture. `playback_us` drives the
  // source-keyed cursor/zoom/camera; `emit_pos_ms` / `emit_dur_ms` are what Dart
  // sees (edited on the stitched path, raw source on the MediaPlayer path). The
  // lock order matches HandleVideoFrame: it briefly takes mutex_ while holding
  // render_mutex for the session snapshot.
  void ComposeAndHandoffLocked(Impl* impl, std::int64_t playback_us,
                               std::int64_t emit_pos_ms,
                               std::int64_t emit_dur_ms);

  // Make a just-applied settings change visible when the preview is not
  // advancing. No-op while playing (the next frame carries it). Otherwise
  // re-composites the retained frame; only if none exists yet does it fall back
  // to the 1ms seek nudge. Shared by SetColorGrade + SetCameraComposition.
  // Snapshots the player itself (this header pulls in no WinRT), so call it
  // AFTER releasing mutex_, exactly like the nudge it replaces.
  void RepaintPausedPreview();

  // Re-composite the frame already on screen with the CURRENT settings and hand
  // it to Flutter. The last decoded frame still lives in the compositor's video
  // surface, so this costs one D2D compose + flush: no seek, no decode, no
  // re-copy from the player.
  //
  // This is what makes an edit visible while the preview is PAUSED. While
  // playing, the next natural frame already picks the change up and calling this
  // would just duplicate work. Returns false when there is nothing to repaint
  // (no frame composed yet), which is also the "preview isn't up" case.
  bool RepaintRetainedFrame();

  // True once at least one frame has been fully composed, i.e. the compositor's
  // video surface holds real pixels. Deliberately NOT `has_video_target()`: the
  // texture is allocated in EnsureResources BEFORE the first frame is copied
  // into it, so a non-null texture does not imply drawable content.
  bool HasComposedFrame();

  // Editing port (clips, step 4-3): render ONE frame of the edited (stitched)
  // timeline at `edited_ms` — map edited→source, decode that source frame via
  // the edited reader, upload it into the compositor, then compose + hand off.
  // Drives the PAUSED / SCRUBBED edited preview (continuous playback is 4-3b).
  // The caller holds impl->render_mutex. Returns false when there is nothing to
  // draw (no reader, or the decode failed).
  bool RenderEditedFrameLocked(Impl* impl, std::int64_t edited_ms);

  // Step 4-3b: one bounded step of continuous edited playback. kRendered = a
  // kept frame was composed (pace one frame budget); kSkipping = the per-call
  // decode cap was hit while still inside a cut gap (release render_mutex + step
  // again immediately, so a large gap doesn't hold the lock for seconds);
  // kIdle = not playing / stopped / end-of-stream.
  // kRenderedBehind: a frame was presented but the video is STILL behind
  // the audio master — decode the next one immediately instead of burning
  // a frame budget. Without it the pacer sleeps a whole budget after every
  // frame, so a source whose frame rate exceeds the budget (a 60 fps
  // recording against the historical fixed 33 ms) advances content at half
  // wall-clock speed and can never track the sound, however fast decode is.
  enum class PaceStep { kIdle, kRendered, kRenderedBehind, kSkipping };

  // Step 4-3b: advance edited playback by ONE step — decode forward from the
  // edited reader, skipping cut-gap frames (EditedMsForKeptSourceMs nullopt) up
  // to a small per-call cap, and compose the first kept frame at its edited
  // position (advancing edited_pos_ms). Monotonic (cut) sessions only; reorder
  // playback needs per-range seeks (step 4-4). Clears edited_playing at
  // end-of-stream. Caller holds impl->render_mutex.
  PaceStep PaceNextEditedFrameLocked(Impl* impl);

  // Step 4-3b pacer thread body. Loops until shutting_down_; while an edited
  // session is playing, renders one kept frame per ~source-frame budget.
  void PacerLoop();

  // Step 4-4: prime the reorder-playback cursor (edited_range_idx +
  // edited_reorder_base_ms) so a subsequent reorder pace step reads forward
  // inside the timeline range that contains `edited_ms`. Caller holds
  // render_mutex; a no-op for a monotonic session (the pacer forward-decodes).
  void PrimeReorderStateLocked(Impl* impl, std::int64_t edited_ms);

  // Step 4-5: genuine end-of-timeline on the pacer path — clears the playing
  // flag and emits the SAME playerState "completed" the MediaPlayer path
  // sends from HandleMediaEnded, so Dart no longer infers completion from
  // pos≈dur. Caller holds render_mutex (the nested mutex_ snapshot inside is
  // the sanctioned render_mutex → mutex_ order). Decode-FAILURE paths must
  // NOT call this — they are errors, not completion.
  void NotifyEditedPlaybackCompleteLocked(Impl* impl);

  // Editing port (clips, step 4-3): are the current clip ranges a real edit
  // (cut / trim / delete-middle / reorder / overlap) — i.e. should this session
  // use the stitched reader path rather than the 1:1 MediaPlayer? Pure: coalesce
  // then check for more than one window, or a single window not starting at
  // source 0. Mirrors the export ClassifyClipEdit's has-real-edits test.
  static bool RangesAreEdited(
      const std::vector<capture::export_::clip_planner::ClipKeptRange>& ranges);

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

  // Phase 10.4: one-shot latches for the two mid-preview failure emitters.
  // `render_error_emitted_` gates the consecutive-frame-failure
  // PREVIEW_RENDER_ERROR pair (playerError + previewFailed);
  // `media_failed_emitted_` dedupes MediaFailed (MediaPlayer can fire it
  // repeatedly, and the pre-10.4 handler re-ran the whole close flow each
  // time). Both reset in Open / Close. Guarded by mutex_.
  bool render_error_emitted_ = false;
  bool media_failed_emitted_ = false;

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

  // Step 4-3b: the edited-playback pacer thread. Per session (created in Open,
  // joined in Close BEFORE impl_ teardown — like heartbeat_thread_). While an
  // edited session is playing it decodes forward and renders kept frames at
  // ~source fps; idle otherwise. shutting_down_ stops it.
  std::thread pacer_thread_;

  mutable std::mutex mutex_;
};

}  // namespace clingfy::preview

#endif  // RUNNER_PREVIEW_PREVIEW_ENGINE_H_
