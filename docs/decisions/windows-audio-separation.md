# Windows audio separation — mic/system as separate tracks

Status: **design locked, implementation in slices** (see §6).
Written 2026-07-19, after the step 4-7 preview-audio track (#276–#281) landed
the edited-path WASAPI renderer and live mix. This is the Windows counterpart
of macOS Phase 1.5 ("separated audio sources"), and the prerequisite for
mic-only gain / normalize parity.
Companion docs: `docs/decisions/windows-editing-step4-7-preview-audio.md`
(the single-track preview mix this extends),
`docs/decisions/windows-editing-step-3b-reorder-export.md` (the
`ReorderAudioPump` this design doubles up).

## 1. Problem

Windows records **one premixed stereo AAC track**: `AudioMixer` sums mic +
system loopback at capture time into `screen.mov`, and the pre-mix packets
are destroyed inside the mixer-thread loop. Every downstream consumer
(preview, export, gain, normalize) can only ever see the blend:

- **Gain is whole-track.** The "mic gain" slider amplifies system audio too.
- **Normalize is impossible to do right.** macOS normalizes from the mic
  file's peak; Windows would measure the blend.
- **No macOS bundle parity.** A macOS project carries `capture/mic.m4a` +
  `capture/system.m4a` sidecars (manifest keys `capture.micAudio` /
  `capture.systemAudio`); a Windows project has neither, so cross-platform
  bundles degrade to the legacy embedded path when opened on a Mac.

macOS Phase 1.5 ground truth (verified in code, not docs): sidecars are
AAC-LC `.m4a`, zero-anchored **by construction**, additive next to the
unchanged embedded premix, `schemaVersion` stays **2**, and both preview and
export gate on the same decode-one-sample probe (`readableAudioAsset`) with
a legacy embedded fallback when neither sidecar decodes.

## 2. Key findings (what the code already gives us)

1. **The tee point is exact and singular.** The mixer thread loop in
   `recording_engine.cpp` pops mic (blocking) + loopback (`TryPop`), calls
   `AudioMixer::Mix` — which sums to int16 on a **synthetic sample-count
   timeline from 0** (QPC discarded) — and lets the pre-mix float32 packets
   die at the end of the iteration. Everything the sidecars need flows
   through that one loop.
2. **A minimal audio-only sink writer is proven feasible.**
   `MfSinkWriterEncoder` cannot do audio-only (video media types are
   unconditional, `Validate` requires dims/fps, `Open` requires a
   `D3DDevice`). But all the MF calls a sidecar writer needs already exist
   in `ConfigureAudioMediaTypes` (AAC-LC output type, int16 PCM input type,
   `MFCreateMemoryBuffer` + `SetSampleTime/Duration` sample pattern), and
   `CameraRecorder` proves a **second concurrent `IMFSinkWriter`
   mid-recording** works — `MFCreateSinkWriterFromURL`, no D3D.
3. **Mid-record mic death currently wedges ALL audio (pre-existing
   hazard).** On a WASAPI error the capture thread fires the one-shot
   `ReportCaptureError` and keeps spinning without pushing packets; the
   queue is never closed. Because the mixer's mic read is a **blocking
   Pop**, a dead mic starves the mixed track *and* would starve the system
   sidecar. Separation makes this bug's blast radius bigger, so this design
   fixes it.
4. **The export already has the "independent audio reader" seam.**
   `ReorderAudioPump` (own audio-only `IMFSourceReader`, 48 kHz stereo
   int16, `AudioPacketSink` = packet + absolute edited frame) is exactly the
   per-sidecar reader needed; two pumps over **one shared
   `clip_planner::AudioSlots` plan** stay sample-aligned by construction.
   `MeasureSourceAudioPeak` is already path-parameterized — pointing it at
   `mic.m4a` is a call-site change.
5. **macOS never byte-copies a separated export.** Its separated path always
   mixes down through the reader. Windows' Slice-1 byte-copy fast-path
   (`export_passthrough.cpp`) must therefore be **disabled when a sidecar
   decodes**, or exports would ship the premix and ignore mic-only gain.
6. **`resolveSeparatedAudioControls` is the math to port, and it is NOT
   `ResolveAudioGainStages`.** macOS computes
   `combinedMicLinear = 10^(gainDb/20) × (normalizeTarget/micPeak)`, clamps
   the **combined** boost to +24 dB, and keeps `masterVolumePercent`
   separate (applied per track, never folded into normalize). The existing
   Windows resolver folds volume into a single whole-track stage — fine for
   the legacy path, wrong for separated.
7. **WinRT `MediaPlayer` has no per-track mix API.** The uncut passthrough
   preview cannot do mic-only gain no matter how the bundle is shaped. The
   edited path (our own WASAPI renderer + FIFO) can.
8. **Manifest keys already parse on both sides.** macOS emits
   `capture.micAudio` / `capture.systemAudio` under `schemaVersion` 2; the
   Windows reader ignores unknown keys (and rejects any other
   schemaVersion), so the keys are additive and cross-platform today.

## 3. Decisions

- **D1 — Bundle shape mirrors macOS exactly.** Keep the embedded premix AAC
  in `screen.mov` untouched (legacy fallback + passthrough preview + old
  builds keep working). Additionally write `capture/mic.m4a` +
  `capture/system.m4a` and emit `capture.micAudio` / `capture.systemAudio`
  in `project.json`. `schemaVersion` stays **2**. A sidecar is only emitted
  for a source that was actually captured (mic disabled ⇒ no `mic.m4a`, no
  manifest key — matching macOS's nullable keys).
- **D2 — `AudioSidecarWriter`: minimal MF sink writer, no D3D.**
  `MFCreateSinkWriterFromURL`, one AAC-LC stream (48 kHz / stereo / int16
  PCM in → AAC out), media types lifted from `ConfigureAudioMediaTypes`.
  Temps follow the camera pattern: `%TEMP%\clingfy_<sanitized>.mic.mp4` /
  `.sys.mp4` (MF picks the MPEG-4 container from the `.mp4` extension),
  renamed to `capture/mic.m4a` / `capture/system.m4a` at bundle time — the
  container is identical, only the name changes. New temp resolvers live in
  `encoder_output_path.h`; every cleanup list learns the new names
  (`CleanupSessionTempFiles`, `CleanupFailedStartArtifacts`, the recovery
  sweep's stranded-temp deletion).
- **D3 — Tee inside the mixer thread, slaved to the MIXED clock.** For each
  mixer iteration that emits a `MixedPacket` of N frames at offset F, each
  active sidecar receives exactly **N frames at offset F**: the source's
  own float32 packet converted to int16 when it contributed, **silence
  otherwise**. No per-source free-running sample counters — a loopback
  `TryPop` miss or a dead mic must not let a sidecar's timeline slip
  against the mixed track. This is the Windows analog of macOS's
  zero-anchor + silence-fill construction: all three tracks (premix, mic,
  system) stay sample-exact against each other and pause-continuous. QPC
  timestamps are never used.
- **D4 — Fix the mic-death starvation as part of this track.** On a fatal
  capture error the capture loop **closes its own queue**. The mixer
  distinguishes closed-vs-empty: a closed mic queue flips the loop into
  loopback-blocking mode (and vice versa), the dead source contributing
  silence to both the premix and its sidecar from that point on. Both-
  closed still exits the thread. This fixes the pre-existing all-audio
  wedge and is a hard prerequisite for D3's "sidecars never starve".
- **D5 — Sidecars are best-effort, never fatal.** A sidecar writer failing
  to open or write logs one WARN and drops that sidecar (manifest key
  omitted); the premix and the recording are unaffected. Mirrors the
  existing best-effort mic/loopback capture opens. Finalize slots into
  `TeardownPipeline` after the mixer thread joins (the writers are fed only
  from the mixer thread), before the bundle move; a failed finalize also
  just drops the sidecar.
- **D6 — Reader: two independent existence-gated optionals.**
  `RecordingProject` gains `std::optional<std::wstring> mic_audio_path` /
  `system_audio_path` following the `cursor_path` pattern (key present +
  file exists, else `nullopt`). Never require both.
- **D7 — One decodability probe, shared by preview and export.** A Windows
  analog of macOS `readableAudioAsset`: open a throwaway audio-only
  `IMFSourceReader` on the sidecar and decode one PCM sample. Probe passes
  ⇒ the sidecar is used; **neither** sidecar passes ⇒ legacy embedded path
  (whole-track semantics, exactly today's behavior).
- **D8 — Export mixes separated sources through dual pumps; byte-copy is
  off for separated recordings.** When at least one sidecar decodes:
  `needs_composition` is forced true (macOS never byte-copies separated —
  shipping the premix would ignore mic-only gain); the audio path runs
  **two `ReorderAudioPump` instances** (mic + system) built from **one
  shared `AudioSlots` plan** (identity plan when no clips), summed
  int16-clamped in a mixing `AudioPacketSink` feeding the encoder's single
  AAC output track (macOS also mixes down to one track). Controls resolve
  via a new pure `SeparatedAudioControls` port of
  `resolveSeparatedAudioControls` in `export_audio.{h,cpp}`: mic stage =
  gain × normalize, **combined** clamp +24 dB; system stage = unity;
  master volume applied to both; normalize peak =
  `MeasureSourceAudioPeak(mic.m4a)` only when auto-normalize is on and the
  mic sidecar decodes; gain + normalize **inert when there is no decodable
  mic** (macOS D7 semantics). No gain-bake temp file: macOS baked mic gain
  into a temp file only because `AVAudioMix` volume cannot exceed 1.0 —
  Windows applies gain in the PCM domain per packet, so the bake step is
  unnecessary by construction.
- **D9 — Preview edited path goes dual-pump; passthrough keeps its
  documented gap.** `PreviewAudioRenderer` grows a second pump (mic +
  system over the same slots plan), clamp-summed at the `TopUpFifo` fill
  site; `SetGainStages` widens to a mic/system stage pair resolved by the
  same `SeparatedAudioControls` (normalize off in preview, both platforms).
  Sessions where no sidecar decodes keep today's single-pump whole-track
  path. The uncut passthrough `MediaPlayer` keeps premix + volume-only
  (finding 7) — same already-documented gap as today, notice copy updated
  only if wording goes stale.
- **D10 — Scene info learns audio presence (additive).**
  `getRecordingSceneInfo` gains `hasMicAudio` / `hasSystemAudio` derived
  from the manifest + probe, so the post-processing sidebar can stop gating
  the gain slider on **live device selection** and gate on what the
  recording actually contains (macOS behavior). Dart treats missing keys as
  today's behavior (additive, no macOS change required).

## 4. What does NOT change

- `screen.mov` still carries the premixed AAC track — byte-identical
  recording pipeline for every consumer that doesn't know about sidecars.
- `schemaVersion` stays 2; old Windows/macOS builds open new bundles.
- The Dart↔native wire contract: `updateAudioPreview`, `processVideo`
  audio args, and the bridge method list are untouched (D10 is a reply-key
  addition, not a new method).
- Whole-track legacy behavior for old recordings (no sidecars ⇒ every path
  behaves exactly as before this track).
- The export's video path, clip stitch math, and `AudioSlots` planner.

## 5. Risks / open edges

- **Mixer-thread budget.** The tee adds two int16 conversions + two sink
  writer `WriteSample` calls per iteration on the mixer thread. MF sink
  writers buffer internally and AAC-encode on worker threads, so the added
  latency is small; the drop-oldest 200-packet queues bound the damage if a
  writer stalls. If profiling shows pressure, sidecar writes move to a
  dedicated thread fed by a queue — not expected for v1.
- **Loopback silence vs. absence.** WASAPI loopback delivers nothing when
  no audio renders; D3 silence-fill makes the system sidecar continuous
  regardless. Verified against the premix by construction (same N@F span).
- **`.m4a` naming.** MF writes the MPEG-4 container under a `.mp4` temp
  name; the bundle-time rename to `.m4a` matches macOS naming. macOS
  `AVURLAsset` and MF source readers both open MPEG-4 audio regardless of
  extension — cross-platform open verified in Slice B's probe tests.
- **D4 semantics change.** Today a dead mic wedges audio silently; after
  D4 the recording keeps system audio and the mixed track gains silence in
  the mic's place. Strictly better, but it is a behavior change worth a
  line in the recording-warning docs.

## 6. Slices

1. **Slice A — capture:** `AudioSidecarWriter`, mixer-thread tee (D3),
   mic-death queue-close fix (D4), temp resolvers + cleanup/recovery lists,
   manifest keys, reader optionals (D6). Tests: tee alignment invariants
   (pure helper: N@F spans, silence-fill, source-contribution), writer
   open/finalize soft-fail, manifest emit/omit, reader existence gates,
   mixer closed-queue transitions.
2. **Slice B — export:** decode probe (D7), `SeparatedAudioControls`
   resolver, dual-pump mixing sink, byte-copy gate + forced composition
   (D8), normalize-from-mic. Tests: resolver math vs. macOS constants
   (clamp split, inert-no-mic, volume separation), probe gating, dual-pump
   sum determinism, byte-copy disable.
3. **Slice C — preview + Dart:** dual-pump `PreviewAudioRenderer`, gain
   stage pair (D9), `hasMicAudio`/`hasSystemAudio` scene-info keys + Dart
   parsing + sidebar gating (D10), notice copy check. Tests: renderer
   soft-fail/dual-pump paths, Dart scene-info parsing + gating, stage-pair
   resolution.

Each slice lands as its own PR on green CI, in order — A unblocks B and C;
B and C are independent of each other but share the resolver, so B goes
first.
