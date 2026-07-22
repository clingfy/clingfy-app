#ifndef RUNNER_PREVIEW_PREVIEW_AUDIO_RENDERER_H_
#define RUNNER_PREVIEW_PREVIEW_AUDIO_RENDERER_H_

#include <windows.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "Capture/Export/clip_playback_planner.h"
#include "Capture/Export/export_audio.h"

// Editing port, step 4-7b (docs/decisions/windows-editing-step4-7-preview-audio.md,
// D3/D5/D7): the edited-preview sound output — the first render-side audio
// code in the repo.
//
// One instance per edited preview session. Owns:
//   * a ReorderAudioPump decoding the session's single premixed audio track
//     through the SAME AudioSlots plan the export uses (cuts, reorders, and
//     silence-fill included — D2), primed at the playhead for scrub (4-7a),
//   * an event-driven WASAPI shared-mode render client on the default
//     eRender endpoint (mirrors WasapiAudioCapture's loop with
//     IAudioRenderClient swapped in), and
//   * one render thread that does ALL WASAPI streaming calls: decode happens
//     on it between buffer events (the export proves decode runs far faster
//     than realtime), int16 -> float32 conversion at the fill site, and the
//     export's ApplyAudioGain applied to each packet first so the preview
//     mix is bit-exact with the export's two-stage clamp semantics.
//
// CLOCK (D5): while streaming, `PositionEditedMs()` is derived from submit
// accounting — edited frames written minus the device's unplayed padding
// (`PlaybackEditedFrame`, pure) — published as an atomic so the video pacer
// can chase it lock-free. Audio is the master; video never drives audio.
//
// THREADING (D9): the render thread NEVER touches PreviewEngine's
// render_mutex or mutex_ — it owns its state behind the renderer's internal
// mutex plus atomics. The public API is called from the Flutter platform
// thread only (the engine's existing serialization); transport calls post a
// command and wake the render thread, which performs the WASAPI transition.
//
// SOFT-FAIL (D7): `Open` returns nullptr on ANY setup failure (no audio
// track, no default endpoint, incompatible mix format, WASAPI error) — the
// preview then stays a working silent-video preview. A mid-stream device
// failure (classic: AUDCLNT_E_DEVICE_INVALIDATED after a standby resume)
// stops streaming and fires the one-shot error callback; the ENGINE decides
// whether to rebuild (once) or fall back to silent video.
namespace clingfy::preview {

class PreviewAudioRenderer {
 public:
  // Pure position math, exposed for headless tests: the edited frame
  // currently at the speaker, given the stream base, total frames submitted
  // since the base, and the device's current unplayed padding. Clamped so a
  // just-primed stream (padding == everything submitted) reads the base.
  // (The renderer additionally clamps the published position to the plan
  // end so it pins there during the EOS drain.)
  static std::int64_t PlaybackEditedFrame(std::int64_t base_edited_frame,
                                          std::uint64_t submitted_frames,
                                          std::uint32_t padding_frames);

  // Pure, exposed for headless tests: the plan's end as an edited frame —
  // the tiling invariant makes it the last slot's edited start + duration
  // (ms -> frames, truncating). Device writes are clamped to it so the
  // buffer genuinely drains at EOS, and the published position pins there.
  // Empty slots -> 0 (nothing to play; a stream drains immediately).
  static std::int64_t PlanEndEditedFrame(
      const std::vector<capture::export_::clip_planner::AudioSlot>& slots);

  // Build the pump + WASAPI client + render thread, stopped at edited 0.
  // `slots` comes from clip_planner::AudioSlots (every edited session — D2).
  // nullptr on any failure (soft-fail; one WARN is logged by the caller).
  static std::unique_ptr<PreviewAudioRenderer> Open(
      const std::wstring& source_path,
      const std::vector<capture::export_::clip_planner::AudioSlot>& slots);

  // Audio separation (design D9): the SEPARATED variant — one pump per
  // decodable sidecar (either path may be empty, never both), both running
  // the SAME slots plan, clamp-summed at the FIFO fill site with the
  // per-track stage pair (mic gets gain, both get master volume). The
  // engine only calls this when ProbeDecodableAudio passed for the
  // non-empty paths. Same soft-fail contract as Open: nullptr when no
  // track opens (a single failed track just drops — export parity).
  static std::unique_ptr<PreviewAudioRenderer> OpenSeparated(
      const std::wstring& mic_path, const std::wstring& system_path,
      const std::vector<capture::export_::clip_planner::AudioSlot>& slots);

  ~PreviewAudioRenderer();
  PreviewAudioRenderer(const PreviewAudioRenderer&) = delete;
  PreviewAudioRenderer& operator=(const PreviewAudioRenderer&) = delete;

  // Start (or restart) audible playback at `edited_ms`. Always re-primes:
  // the engine calls this with its authoritative edited position on every
  // play/resume, so stale buffered audio from before a pause/scrub is
  // dropped, never replayed.
  void Play(std::int64_t edited_ms);

  // Freeze the stream (device stops pulling; position holds).
  void Pause();

  // Replace the slot plan after a clip edit. Pauses the stream and DEFERS
  // the pump rebuild to the next Play transition, which runs on the render
  // thread — so a mid-fill pump swap can never occur and the MF reader
  // reopen cost never lands on the platform thread. (The engine
  // force-clears playback on every edit anyway — the 4-3b rule: the user
  // re-presses Play.)
  void SetSlots(
      const std::vector<capture::export_::clip_planner::AudioSlot>& slots);

  // Live mix (D6, wired to the bridge in 4-7d): applied to packets decoded
  // AFTER the call — exactly the "affects only future samples" semantics.
  // Whole-track stages for the legacy (premix) renderer.
  void SetGainStages(const capture::export_::AudioGainStages& stages);

  // Separated live mix (D9): the per-track stage pair (mic-only gain,
  // master volume on both). Meaningful only on an OpenSeparated renderer;
  // same future-samples semantics.
  void SetSeparatedGainStages(
      const capture::export_::SeparatedAudioStages& stages);

  // The edited position currently at the speaker (ms, truncating). Lock-free;
  // safe from the pacer thread. Frozen while paused; pinned at the plan end
  // after playback drains.
  std::int64_t PositionEditedMs() const;

  // True while the device is actively streaming (Play called, not yet
  // paused/drained/failed). Lock-free.
  bool playing() const;

  // One-shot mid-stream failure callback (fired on the render thread — the
  // engine must marshal, not act inline). Set before the first Play.
  void SetOnRenderError(std::function<void(HRESULT)> callback);

 private:
  PreviewAudioRenderer();

  class Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace clingfy::preview

#endif  // RUNNER_PREVIEW_PREVIEW_AUDIO_RENDERER_H_
