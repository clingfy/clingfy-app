# Windows editing — Step 4-7: preview audio

Status: **design locked, implementation in slices** (see §6).
Written 2026-07-19, after step 4 slices 1–4 (#255–#259) landed continuous
stitched playback and the color-parity calibration (#275) closed step 2.
Companion docs: `docs/windows-port-editing-features.md` (§5.2, §5.4),
`docs/decisions/windows-editing-step-3b-reorder-export.md` (the export audio
stitch this design reuses).

## 1. Problem

Windows preview audio is split down the middle:

- **Passthrough sessions** (no real clip edits) play through the WinRT
  `MediaPlayer` in frame-server mode, which renders the source's audio track
  natively — audio works, but the gain/volume sliders are silent no-ops
  (`updateAudioPreview` → `HandleNoopSetter`, `devices_router.cpp`), and the
  sidebar shows the Windows-only notice "Applied on export — the inline
  preview doesn't show this effect yet".
- **Edited sessions** (cuts / trims / reorders) switch to the step-4 pacer,
  which decodes video via `PreviewSourceReader` and renders **no audio at
  all**. A cut or reordered preview is completely silent — the biggest
  user-visible gap left in the editing port.

macOS has neither problem: its preview swaps the `AVPlayerItem` to an
`AVMutableComposition` that stitches **video and audio** per kept range
(silence-filled slots, `ClipPlaybackPlanner.audioSlots`), so cuts/reorders
are audible by construction, and `updateAudioPreview` applies a live
`audioMix` within ~150 ms of a slider drag.

## 2. Key findings (what the code already gives us)

1. **The stitch math is already ported and shipping.** The export's audio
   path runs on `clip_planner::AudioSlots` + `clip_audio::PlanReorderAudioSlots`
   (pure, headless-tested, §5.1 truncation and §5.2 full-slot-advance
   invariants baked in) and `ReorderAudioPump` (own audio-only
   `IMFSourceReader`, 48 kHz stereo int16, per-slot backward seeks,
   silence-fill, origin shift). These are exactly the semantics macOS's
   `stitchKeptRanges` implements for its preview composition.
2. **The gain math is already ported and shared with the export.**
   `ResolveAudioGainStages` / `ApplyAudioGain` (`export_audio.h`) mirror the
   macOS ordered stages (gain 0–24 dB amplifies and clamps FIRST, volume
   0–100 % attenuates second). macOS preview passes
   `autoNormalizeOnExport:false` — normalize is **export-only** on both
   platforms.
3. **Windows recordings carry ONE premixed stereo track.** Mic + system are
   summed by `AudioMixer` at record time into a single AAC stream; there are
   no separated sidecars (that is the unstarted audio-separation track). So
   the macOS behavior to match is its **legacy embedded path**: whole-track
   gain + volume over a kept-range-stitched single track — precisely what
   the pieces in (1)+(2) compute.
4. **No render-side audio code exists anywhere in `windows/`.**
   `WasapiAudioCapture` opens `eRender` only in loopback-*capture* mode. A
   WASAPI shared-mode **render** client is new code, but can mirror the
   capture class's event-driven loop with `IAudioRenderClient` swapped in.
5. **The pacer has no real clock and says so.** `PacerLoop` paces at a fixed
   33 ms `steady_clock` budget; the comment at its head explicitly notes
   "there is no preview audio yet to sync to". Position advances from
   decoded frame timestamps, not wall time.
6. **The Dart contract is complete and already firing.** Dart sends
   `updateAudioPreview {sessionId?, gain, volume}` (debounced 150 ms during
   drags, immediate on release) and carries `audioGainDb`/`audioVolumePercent`
   in every `processVideo` — Windows currently drops all of it.
   `previewSetAudioMix`/`previewSetAudioGainDb` are never sent by Dart
   (macOS-side dispatch aliases; keep them registered, keep them thin).

## 3. The macOS reference (what we are matching)

What the user hears on macOS in an edited preview, which Windows must
reproduce for the single-track case:

- Cuts remove their audio; reorders play audio in timeline order; slots
  advance by their FULL timeline duration with silence filling any decode
  shortfall (§5.2 — a short tail must never desync downstream slots).
- Gain/volume changes are audible while playing within ~150 ms, without a
  re-composition, and survive session reopen (macOS stores an override that
  applies to pending opens; stale `sessionId` is a silent success).
- Pause silences immediately; seek resumes at the sought position; there is
  no mute UI (volume 0 % is the de-facto mute).

## 4. Decisions

**D1 — One owned audio engine for edited sessions; MediaPlayer keeps
passthrough.** Edited sessions get a new `PreviewAudioRenderer` (see D3).
Passthrough sessions stay on the proven MediaPlayer audio path. We do NOT
unify passthrough onto the owned engine in this step: it would re-clock the
MediaPlayer-driven video path against a second clock for zero user-visible
gain today. Revisit only if the passthrough gain gap (D6) graduates from
"documented" to "complained about".

**D2 — Audio plan = `AudioSlots` for every edited session, monotonic or
not.** Unlike the export (which keeps monotonic audio in the main reader
loop), the preview always builds the slot plan via
`clip_planner::AudioSlots` + `PlanReorderAudioSlots`. One code path,
already reorder-proof, already silence-fill-correct; the monotonic case is
just a plan whose seeks happen to run forward.

**D3 — New unit `windows/runner/preview/preview_audio_renderer.{h,cpp}`
owning thread + WASAPI + decode.** Narrow API driven from the engine's
platform-thread serialization: `Open(video_path, slots, stages)`,
`Play(edited_ms)`, `Pause()`, `SeekTo(edited_ms)`, `SetSlots(...)`,
`SetStages(...)`, `PositionEditedMs()`, `Close()`. Internally: one render
thread running an event-driven WASAPI shared-mode client (`eRender` default
device, float32 mix format, int16→float conversion at the fill site) fed by
a decode core extracted from `ReorderAudioPump` behind a packet-sink seam
(the pump's only export couplings are the `MfSinkWriterEncoder&` parameter
and `EncoderError` return — see 3b docs). The seam refactor must leave the
export pump byte-identical (its tests pin that).

**D4 — The preview decode core gains a seek/prime API the export never
needed.** The export pump's cursor is forward-only. The preview core adds
`PrimeAt(edited_ms)`: locate the containing slot (`ActiveIndexForEditedMs`
semantics), seek the reader to the slot's source window at the intra-slot
offset, and resume the plan from there. Scrub/replay correctness lives
here; it gets dedicated headless tests (fake reader) plus device-gated
round-trip tests.

**D5 — Audio is the master clock while playing with audio.**
`PreviewAudioRenderer::PositionEditedMs()` derives edited position from
`IAudioClock` (device position minus stream-start offset, mapped through
the slot plan). When an edited session is PLAYING and audio is present, the
pacer stops advancing on its fixed 33 ms deadline and instead renders the
kept frame at/behind the audio position each tick (video chases audio —
never the reverse; audio glitches are far more audible than a ±1-frame
video adjustment). Sessions without an audio track (or with a failed WASAPI
open — D7) keep today's fixed-budget behavior byte-identical.

**D6 — Live mix wiring: `updateAudioPreview` becomes real; passthrough gets
volume now, gain stays export-only there (documented gap).**
`updateAudioPreview` (the name Dart actually sends; keys `gain`/`volume`;
clamp [0,24] dB / [0,100] %; stale `sessionId` = silent success; not-yet-open
session = stored override applied on next open, mirroring macOS) routes to
the preview engine: edited sessions apply `ResolveAudioGainStages` at the
ring-buffer fill site (affects only future samples — no re-decode);
passthrough maps volume% → `MediaPlayer.Volume` (0..1 attenuation).
`MediaPlayer.Volume` cannot amplify, so gain > 0 dB on a PASSTHROUGH
preview remains inaudible-in-preview for now: the Dart notice is re-gated
(D8) to say the effect is live in edited previews and on export. The
`processVideo` handler additionally seeds gain/volume into the session
(today it drops the args), so the mix survives editor open and the
standby-resume resync without waiting for a slider touch.

**D7 — Soft-fail everywhere.** WASAPI open failure, no default endpoint,
device invalidated (`AUDCLNT_E_DEVICE_INVALIDATED` — standby resume!), or a
source with no audio track: the preview stays a working silent video
preview (today's behavior) with one WARN log; never a failed open, never a
crash. Device-invalidated during play additionally attempts ONE renderer
rebuild (same pattern as the #271/#272 standby recovery) before going
silent.

**D8 — Dart/test knock-ons land in the same slice as the behavior they
describe.** When edited-preview audio ships (slice 4-7c): re-gate the
`post_audio_export_notice` copy; flip `export_rendered_notice_test.dart`.
When `updateAudioPreview` becomes real (4-7d): move it out of
`router_stub_shapes_test.cpp`'s `kSetters` null-sweep into a dedicated
contract test (the documented migration pattern at its lines ~176–182), and
fix the stale `setAudioMix` mock name in `native_test_setup.dart`.
`bridge_contract_coverage_test.cpp` is untouched (no new method names).

**D9 — Threading/locking rules (extends the 4-3b/4-4 rules).** The audio
render thread NEVER touches `render_mutex` or `mutex_`; it owns its state
behind the renderer's internal lock plus an SPSC ring buffer. The engine
calls the renderer API only from the platform thread (already serialized)
or the pacer (which may read `PositionEditedMs()` — a lock-free/atomic read).
Renderer `Close()` joins its thread and is called from `PreviewEngine::Close`
BEFORE `impl_` teardown, next to the pacer join. Nothing new may hold
`mutex_` while taking `render_mutex` (unchanged global rule).

## 5. Load-bearing invariants (do not regress)

- §5.1: every seconds→ms→frames conversion TRUNCATES.
- §5.2: slots advance by FULL timeline duration; silence fills shortfall.
- Gain order: amplify+clamp first, then attenuate (`export_audio.h`).
- Normalize is export-only; the preview never reflects it (macOS parity).
- The export `ReorderAudioPump` behavior stays byte-identical through the
  sink-seam refactor (its device test + headless tests pin it).
- Passthrough video/audio path byte-identical when no mix is set.
- Edited sessions without audio: pacer behavior byte-identical to today.

## 6. PR slice plan

1. **4-7a — decode core + seam (headless).** Extract the packet-sink seam
   from `ReorderAudioPump`; new `PreviewAudioPump` with `PrimeAt`; pure-plan
   and fake-sink tests. No WASAPI, no engine wiring. Export tests must pass
   untouched.
2. **4-7b — WASAPI renderer (device-gated).** `PreviewAudioRenderer` with
   the event-driven render loop, int16→float, `IAudioClock` position,
   soft-fail matrix (D7). Device-gated smoke tests (headless CI skips).
3. **4-7c — engine wiring (on-device verify).** Edited sessions get audible
   stitched audio; pacer slaved to the audio clock (D5); play/pause/seek/
   clip-edit/EOS transitions; Dart notice re-gate + test flip (D8 first
   half). USER PLAY-TEST: cut and reordered projects audible in timeline
   order, seek/pause tight, no drift over a minute, silent-video fallback
   when audio open fails.
4. **4-7d — live mix.** `updateAudioPreview` + `processVideo` args honored
   (D6); passthrough volume; stub-shape test migration (D8 second half).

## 7. Risks

- **A/V drift** (audio-master pacer): bounded by design — video renders the
  frame at the audio position each tick; there is no accumulating clock.
  Watch the seek-then-play boundary (audio primes on a packet boundary,
  video on a keyframe-forward decode; accept ≤1 video frame of lead).
- **WASAPI event-loop stalls** starving the buffer → audible glitch: use a
  ≥100 ms ring with a low-watermark refill; decode happens on the render
  thread between waits (the export proves decode of these files is far
  faster than realtime).
- **Standby resume** invalidates the audio device mid-play (the #263/#271
  incident class): D7's rebuild-once, then silent-video fallback; the
  preview-rebuild path (#271) recreates the renderer wholesale anyway.
- **Seam refactor regressing the export**: the pump's tests are the guard;
  the refactor slice (4-7a) deliberately ships without any behavior change.

## 8. References

- macOS: `InlinePreviewView.swift` (`rebuildClipComposition`,
  `stitchKeptRanges`, `applyAudioMix`), `PreviewEngine.setAudioMix`,
  `LetterboxExporter.resolveSeparatedAudioControls` (D7 export sharing),
  `CompositionBuilder.swift` `AudioMixEngine.makeAudioMix` (legacy path —
  the semantics Windows matches).
- Windows: `reorder_audio_pump.{h,cpp}`, `clip_audio_stitch.{h,cpp}`,
  `clip_playback_planner.{h,cpp}` (`AudioSlots`), `export_audio.h`,
  `wasapi_audio_capture.{h,cpp}` (the event-driven WASAPI pattern),
  `preview_engine.cpp` `PacerLoop` (the clock this design replaces).
