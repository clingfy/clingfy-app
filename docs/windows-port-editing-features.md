# Windows port — editing features (clips + color): status, gaps, and macOS lessons

> **Audience:** the Windows machine (also running Claude Code) that will build the
> Windows equivalents of the light-editor features. This is a **handoff** written
> right after the macOS clip-editing work landed, so the Windows port can inherit
> the architecture decisions and — more importantly — **avoid the bugs we already
> hit and fixed on macOS.**
>
> **Read alongside** (do not duplicate them):
> - `docs/windows-port.md` — the general phased Windows port (recording, camera,
>   cursor, zoom, export up to the beta), with per-phase "known deliberate edges".
> - `docs/editing-platform-plan.md` — the editing-features *plan* (Mac-first,
>   Phases 0–5: volume/normalize → audio separation → color → split/cut →
>   audio-format → voice cleanup → subtitles+translate).
> - `docs/windows-port-inventory.md` — feature inventory + the bridge contract +
>   the macOS→Windows API replacement table.
>
> **Scope of THIS doc:** the two editing features that are DONE on macOS but NOT
> on Windows — **color grade (Phase 2)** and **clips: split / cut / trim / arrange
> (Phase 3)** — plus the concrete pitfalls encountered building them.

---

## 0. TL;DR (read this first)

- **macOS: clip editing (split / cut / trim / ARRANGE) + color grade is complete
  end-to-end** — portable Dart model, live native preview, and export bake. Merged
  to `develop` as PR-3a…3e (clips) and PR-2a…2c (color).
- **Windows: the portable Dart model already works** (it is platform-agnostic).
  **The native halves are NO-OPS:** `previewSetClips` and `previewSetColorGrade`
  are wired to `HandleNoopSetter` in `windows/runner/Bridge/Routers/preview_router.cpp`,
  and the `exportVideo` handler ignores the `clips` and `colorGrade` args.
- **The single most important lesson — do NOT build a "seek-through-cuts"
  preview.** macOS first shipped a preview that stayed on the raw asset and
  *seeked across every cut*; it hitched <1s at each boundary and spawned a family
  of reorder bugs (skip, backward-snap). We ripped it out and replaced it with a
  **stitched-timeline composition** preview (PR-3e). **Windows should build the
  composition/stitched-timeline preview from the start** and skip that whole
  detour. See §5.4.

---

## 1. Where these features plug into the architecture

The Flutter↔native seam is the same one described in `CLAUDE.md` / the inventory.
For clips + color, the load-bearing facts:

- **The model is portable Dart** and lives in `lib/core/timeline/` +
  `lib/core/clips/` (clips), with `ColorGrade` in
  `lib/core/timeline/model/color_grade.dart`. It has **no
  platform code** — Windows gets it for free. Key pieces:
  - `Clip` (`lib/core/timeline/model/edit_track.dart`): `id`, `sourceInMs`,
    `sourceOutMs`, `timelineStartMs`, `enabled`.
  - `ClipTimeline` / `ClipOperations` (`lib/core/timeline/`): pure split / remove
    (ripple) / trim / `moveToIndex` (arrange) + the `timeline↔source` mapping.
    Every op returns a **normalized** list (contiguous `timelineStartMs`).
  - `ClipEditorController` (`lib/core/clips/`): the ChangeNotifier the UI drives;
    undo/redo via `SetClipsCommand` over the shared `EditSession`; pushes each
    change to native via `previewSetClips`.
  - `ColorGrade` (`lib/core/timeline/model/color_grade.dart`):
    exposure/contrast/saturation/temperature/
    tint, all normalized `[-1, 1]`, `isIdentity` fast-path.
- **The UI is shared Flutter** (`lib/app/home/preview/widgets/timeline/…` +
  `video_timeline.dart`). The clip lane, trim handles, scissors cut, and
  drag-to-reorder all run on Windows already **as long as the native preview
  honors `previewSetClips`.** (Today it doesn't, so editing "works" in the model
  but the Windows preview never reflects a cut.)
- **The native side is what's missing on Windows:** live preview of cuts/reorder,
  and baking cuts/reorder/color into the exported file.

### The `timeline ↔ source` invariant (the spine)

Every other effect — **zoom segments, cursor samples, camera sync** — is keyed to
**original recording (source) time**. The moment clips re-time or reorder the
video, those effects must be remapped through the timeline↔source map or they
silently desync. This is the single concept the whole feature is organized around.
On macOS the map is `ClipPlaybackPlanner` (Swift). **Windows must port the same
math** (§4) and route zoom/cursor/camera through it.

---

## 2. Status matrix — what's done on macOS vs missing on Windows

| Capability | macOS | Windows | Notes |
|---|---|---|---|
| Clip model (split/cut/trim/arrange, undo/redo) | ✅ portable Dart | ✅ portable Dart | Shared; nothing to do. |
| Clip **UI** (lane, trim, scissors, drag-reorder) | ✅ shared Flutter | ✅ shared Flutter | Runs on Windows; just needs a native preview that honors it. |
| Clip **live preview** (play through cuts/reorder) | ✅ composition preview (PR-3e) | ❌ `previewSetClips` = no-op | **Build composition-based (§5.4).** |
| Clip **export bake** (cuts / trim) | ✅ (PR-3d, PR-3c5) | ✅ **(step 3a, 2026-07-04)** — MONOTONIC edits (cut / trim / delete-middle) bake in `export_pipeline`: the frame loop drops source frames/packets in a cut gap (`EditedMsForKeptSourceMs`) and re-stamps survivors onto a compacted edited PTS; audio + video share one origin (the encoder rebases video only, so audio is origin-shifted + buffered until the first kept video frame); zoom smoothing eased on edited dt, camera intro/outro clock on edited time; `ClassifyClipEdit` gate forces composition | Packet-granular audio (~≤21ms cut-seam leak) until 3b. |
| Clip **export bake** (reorder) | ✅ (PR-3c5) | ✅ **(step 3b-2, 2026-07-10)** — REORDER / OVERLAP bake: video reads each kept range's source window in TIMELINE order via per-range backward `SetCurrentPosition` seeks (3b-2a), re-stamped onto a contiguous edited PTS; audio rides a decoupled pump on its OWN reader (per-slot seeks, sample-accurate copy + `AudioSlots` silence-fill, §5.2/§5.3), interleaved with the video writes to dodge the sink-writer throttle; zoom smoother reset + camera reader re-primed at each backward boundary (§5.4/§5.5); progress driven from edited position. The `kUnsupportedClipEdits` refuse-guard is RETIRED | Reorder + overlap now fully supported (parity with cuts). |
| Color model (`ColorGrade`, auto + manual) | ✅ portable Dart | ✅ portable Dart | Shared. |
| Color **live preview** | ✅ CIFilter videoComposition | ✅ **(PR-2b, 2026-07-03)** — `previewSetColorGrade` → `PreviewEngine::SetColorGrade` (stale-session no-op, paused-nudge like camera) → `PreviewCompositor` applies the SAME shared D2D chain (`Graphics/color_grade_effect`) to the video only (halo/camera ungraded, macOS preview parity); frame-thread effect cache, in-place matrix update per slider tick; headless pixel tests | Ships in the same release as PR-2a. |
| Color **export bake** | ✅ (PR-2c) | ✅ **(PR-2a, 2026-07-03)** — D2D graded intermediate (video+cursor+clicks, camera ungraded) via `Capture/Export/color_grade.{h,cpp}` (one linear-space 5x4 matrix), ColorManagement linearization at 16bpc float; identity = passthrough; parity gated on the golden fixture | Preview half (PR-2b) ships in the SAME release — sliders bake into export before they render in preview. |
| Audio volume / normalize on export | ✅ | ✅ (already shipped) | See `docs/editing-platform-plan.md` Phase 1. |

**Windows entry points to change** (already scaffolded, currently stubs/ignores):
- `windows/runner/Bridge/Routers/preview_router.cpp` — `previewSetClips` (line
  ~608) and `previewSetColorGrade` (line ~605) → replace `HandleNoopSetter`.
- `windows/runner/preview/preview_compositor.cpp` / `preview_engine.cpp` — where
  the live preview frame is composed (apply cuts → stitched timeline + color).
- `windows/runner/Capture/Export/export_pipeline.cpp` / `export_session.cpp` /
  `export_audio.cpp` — where the export honors `clips` + `colorGrade`.
- `windows/runner/Encoding/mf_sink_writer_encoder.cpp` — the MF encode loop.
- `windows/runner/Audio/audio_mixer.cpp` — the kept-range audio stitch (§5.2).

---

## 3. Bridge contract for these features

Command/method names are **inline string literals** (not constants) and must
match on both sides. For clips + color:

- **`previewSetClips`** (Flutter→native, live): args `{ clips: [ {id, sourceInMs,
  sourceOutMs, timelineStartMs, enabled}, … ], sessionId }`. Clips are in
  **timeline order**; disabled clips are dropped by the parser; the *kept ranges*
  are the enabled clips' `[sourceInMs, sourceOutMs)` source windows. Empty / a
  single whole-recording clip = **passthrough** (no cuts).
- **`previewSetColorGrade`** (Flutter→native, live): args carry the `ColorGrade`
  map. Identity grade = passthrough.
- **`exportVideo`** (Flutter→native): the args map already includes **`clips`**
  (same shape as above) and **`colorGrade`**. Windows currently parses the map but
  **ignores both** — it must consume them.

Windows already has a **`bridge_contract_coverage_test`** — keep the clips/color
methods covered there when you implement them, and keep the day-one contract:
**every `previewSet*` ships a Windows implementation (even if a documented
degrade), never silently diverging.**

---

## 4. The portable cut-math to port to C++ (`ClipPlaybackPlanner`)

macOS keeps this as a pure enum `ClipPlaybackPlanner` in
`macos/Runner/Capture/Export/CompositionBuilder.swift`, exhaustively unit-tested
in `macos/RunnerTests/RunnerTests.swift` (`ClipPlaybackPlannerTests`). It is pure
integer-millisecond math — **port it verbatim to C++** with the same tests.

> **✅ PORTED (2026-07-02, build-order step 1).** The C++ port lives at
> `windows/runner/Capture/Export/clip_playback_planner.{h,cpp}`
> (namespace `clingfy::capture::export_::clip_planner`), test-for-test suite at
> `windows/runner_tests/clip_playback_planner_test.cpp` (26/26 passing).
> Parsing the Dart `Clip.toMap()` payload into `ClipKeptRange` is deliberately
> NOT in the module (the `export_router` precedent keeps `EncodableValue`
> parsing in routers) — port `ClipKeptRange.fromFlutter`'s filtering rules
> (drop disabled, drop `out <= in`, preserve timeline order, truncate-not-round
> numeric coercion) into the router when steps 3/4 wire the bridge methods.

The functions and their
**invariants** (get these exactly right — the macOS bugs in §5 were all subtle
violations of these):

- `ClipKeptRange { sourceInMs, sourceOutMs }`, `durationMs = sourceOutMs − sourceInMs`.
- `isPassthrough(ranges, assetDurationMs)` — empty, or a single range covering
  `[0, assetDurationMs]`. Skips all clip handling.
- `coalesce(ranges)` — merge *source-adjacent* ranges (`out == next.in`). A split
  with no deletion collapses back to passthrough. **Reordered ranges are NOT
  source-adjacent, so coalesce leaves them intact.**
- `isSourceMonotonic(ranges)` — true when ranges are in non-decreasing **source**
  order. Split/cut/trim keep this true; **only arrange/reorder breaks it.** This
  bit decides "simple cut" vs "reorder" in both preview and export.
- `editedDurationMs(ranges)` — sum of kept `durationMs` (order-independent).
- `editedMs(forSourceMs, activeIndex, ranges)` — source→edited given the active
  slot (handles arrange; clamps within the slot).
- `sourceMs(forEditedMs, ranges)` — the inverse: edited→source. **This is the map
  the composition preview uses every frame** to sample cursor/zoom/camera.
- `editedMsForKeptSourceMs(sourceMs, ranges)` — source→edited or `nil` if the
  moment is in a cut gap (used by the export writer to drop/keep frames).
- `audioSlots(ranges, audioDurationMs)` → `[{sourceInMs, editedStartMs,
  copyDurationMs, durationMs}]` — tiles kept ranges onto the edited timeline; each
  slot spans its **full** `durationMs`, copying only `copyDurationMs` of available
  audio and leaving the rest silent. **Reused for the video stitch too.** See
  §5.2 — the "advance by full duration" rule is load-bearing.

---

## 5. Bugs & pitfalls we hit on macOS — AVOID THESE on Windows

These are the expensive lessons. Each was found by on-device testing and/or
adversarial review and fixed; the Windows port should design them out from day one.

### 5.1 Millisecond conversion must TRUNCATE, not round

The whole-recording clip's `sourceOutMs` is derived on the Flutter side as
`Int(durationSeconds * 1000)` (**truncation**). Native must match. On macOS we
initially used `.rounded()` for `assetDurationMs`; for ~1/3 of durations it came
out 1 ms larger, so `isPassthrough` wrongly reported an *unedited* recording as
cut and ran the manual path — and a boundary frame could drop. **Rule: every
seconds→ms conversion in the clip path truncates (`(int)(seconds * 1000.0)`), and
the frame keep-check truncates too** (a frame at `sourceOutMs − ε` must map below
the exclusive `sourceOutMs`).

### 5.2 Kept-range audio must advance by the FULL slot duration (A/V sync)

When stitching kept-range audio, advance the write cursor by each range's **full
edited duration**, not by however much audio was actually copied. The captured
audio track can be a hair shorter than the video (or the mic stopped early), so a
range's audio gets **clamped/absent** — if you advance by the *copied* length, a
clamped range sitting **mid-timeline under reorder** pulls every later range's
audio earlier → audible desync (up to seconds). Fix: fill the shortfall with
explicit **silence** (`insertEmptyTimeRange` on macOS; a silent-sample gap in the
MF/`audio_mixer` path) so each slot is exactly `durationMs`. This was a HIGH review
finding on macOS. `audioSlots` (§4) encodes it — **use the same slot math for
both audio and video stitching.** (For source-monotonic cuts it never mattered —
only the *last* range can be clamped; reorder is what exposed it.)

### 5.3 Reorder export cannot be a single forward read

For **reorder** (non-monotonic ranges), you cannot forward-read the source once
and re-stamp — the output PTS would go backwards (invalid). macOS reads **each
kept range's source window in timeline order** (a per-window reader) and stamps
onto consecutive edited PTS. On Windows/MF the natural equivalent is to **build a
stitched timeline** (a Media Foundation topology / sequencer source, or read
per-range) that presents the kept ranges contiguously in **timeline order**. The
**audio path already reorders correctly** by inserting kept ranges in timeline
order (§5.2). Guard: `isSourceMonotonic` distinguishes simple cuts from reorder.

### 5.4 The seek-through-cuts preview is a trap — build a stitched-timeline preview

macOS's first preview kept the player on the raw asset and **seeked across each
cut** at playback. Problems that cost multiple on-device iterations:
- **Hitch:** every cut is a frame-accurate seek that decodes from the prior
  keyframe — on a screen recording (sparse keyframes) that stalls playback <1s at
  **every** boundary.
- **Reorder "skip":** a reorder advance seeks *backward* in source; the async seek
  hadn't landed, so the next tick read a stale (later) position as "this range is
  already finished" and skipped the piece. (We patched it with an
  `awaitingClipSeek` gate — then deleted the whole approach.)
- **Playhead "backward-snap":** the reported edited position was derived from the
  raw source position, which for a source-gap overshoot resolves to a *different*
  (earlier) timeline slot → the scrubber jumped backwards.

**The fix (PR-3e) — and what Windows should do from the start:** play a **stitched
composition** of the kept ranges (contiguous edited timeline), so playback is
naturally smooth with **no per-cut seeks**. Then:
- The player's time **is edited time**. Report it straight to Flutter.
- Map **edited→source once per frame** (`sourceMs(forEditedMs)`) to sample the
  **source-keyed overlays** (cursor, zoom, camera). Identity when there are no cuts.
- Rebuild the stitched timeline when clips change, **debounced** (macOS uses
  ~120 ms) so a live trim drag (streams ~60×/s) doesn't thrash the pipeline — the
  clip lane stays live in Flutter and the preview catches up on release.
- Reset zoom smoothing/hysteresis when source time jumps **backward** at a reorder
  boundary (the edited→source map reveals it).
On Windows: `preview_compositor.cpp` / `preview_engine.cpp` should compose from a
kept-range **stitched timeline**, not from a seek-per-cut loop. This also
sidesteps 5.4's three bugs entirely.

### 5.5 Camera stays a separate synced player — remap ALL its time inputs

The camera preview is a **separate synced player + PiP layer**, not a track in the
composition (it has independent geometry, zoom, placement animation, and a sync
timeline). Once the main player runs edited time, **every** place that feeds the
camera the screen time must map edited→source — not just the per-frame tick, but
also the off-tick paths (window relayout, camera-param change, placement-transition
timer, manual drag clamp). On macOS we missed 5 such call sites in the first pass
(caught by review). **Windows: route camera time through one `edited→source`
helper and audit every caller.**

**Export side (done, 3b-3 audit):** the export camera has no off-tick paths — a
deterministic frame loop routes every camera time through one helper
(`CameraTimeMsForFrame`): `Advance`/`SeekTo` take SOURCE time, `Draw` takes
EDITED time for the intro/outro clock. Under reorder the reader is re-primed at
each backward boundary (`CameraExportRenderer::SeekTo`, 3b-2a) and this is pinned
by `ExportPipelineTest.CameraBubbleTracksSourceTimeUnderReorder` (a camera
colored by source time must invert with the reorder). The off-tick audit is a
**step-4 (preview)** concern — that's where relayout / param-change / placement
timer / drag-clamp live.

### 5.6 Narrow-clip trim handle swallowed the reorder drag (shared Flutter UI)

Already fixed in shared code, but note it: the selected clip's opaque end-trim
handle sat on top and absorbed a body drag on a very narrow clip (≤ ~22 px),
blocking drag-to-reorder. Fix capped the handle hit-width so a reorder grab-strip
always survives. Windows inherits the fix (shared widget).

### 5.7 Backspace/Delete keybinding + a benign Flutter keyboard assertion

Shared-Flutter items surfaced during macOS testing (Windows inherits both):
- **Backspace/Delete now deletes the selected CLIP first** (falls back to
  zoom-segment delete). If Windows key routing differs, verify the `Shortcuts`/
  `Actions` still resolve over the timeline focus.
- A **debug-only** Flutter framework assertion
  (`HardwareKeyboard._assertEventIsRegular`, tripped by *holding* a key) is dropped
  in `lib/app/infrastructure/error/global_error_handlers.dart`. It is stripped in
  release and is not an app bug — do not chase it on Windows either.

### 5.8 Zoom lane vs. edited ruler under cuts

Originally the **zoom lane's recording-time segments mis-positioned vs the edited
ruler** — the lane drew segments in source time, so under cuts the pills sat at the
wrong x and ran past the timeline end.

**Fixed for the display-only lane (#286)** by the pure
`mapZoomSegmentsToEditedTimeline` (`lib/core/timeline/zoom_segment_timeline_mapper.dart`):
it intersects each source-time segment with every enabled clip's window and re-bases
it to the clip's timeline position — cut-gap segments vanish, straddlers clamp,
multi-range segments split into one pill per range, reordered clips reposition; the
identity timeline maps 1:1 so it applies unconditionally. Wired in
`timeline_editor_viewport.dart`; the underlying zoom model stays in source time (the
native compositor and export do their own edited-time mapping). This is all of
Windows.

**Remaining (accepted v1 gap, macOS-only):** the macOS **editable** zoom lane keeps
raw source coords, because its drag interactions work in source coordinates and
remapping display-only would desync them (`timeline_editor_viewport.dart` falls back
to `editorController.displaySegments` when an editor is attached). Windows has no
editable lane, so it is unaffected.

### 5.9 macOS-only build noise (ignore on Windows)

For completeness: on macOS, SourceKit single-file diagnostics report false
"cannot find X in scope" for module-level symbols — confirm via `xcodebuild …
TEST SUCCEEDED`, not the editor squiggles. This is a macOS toolchain quirk with no
Windows equivalent.

---

## 6. Recommended Windows build order

1. ~~**Port `ClipPlaybackPlanner`** to C++ with its tests (§4). Pure math, no OS deps
   — do this first; everything else depends on it.~~ **✅ Done 2026-07-02** —
   `windows/runner/Capture/Export/clip_playback_planner.{h,cpp}` +
   `windows/runner_tests/clip_playback_planner_test.cpp` (26/26).
2. **Color** before clips (smaller, no timeline remap): implement
   `previewSetColorGrade` (per-frame color pass in `preview_compositor.cpp`) and
   honor `colorGrade` in the export encode. Identity = passthrough.
   **Export half ✅ done (PR-2a, 2026-07-03)**: `color_grade.{h,cpp}` (matrix) +
   `color_grade_args`/`clip_args` (shared wire parsers) + passthrough
   disqualifier + graded D2D intermediate + interim clips refuse-guard.
   Golden fixture (`windows/runner_tests/fixtures/color_grade_golden.json`,
   dumped by macOS `ColorGradeGoldenDumpTests`) gates the parity tests.
   **Preview half ✅ done (PR-2b, 2026-07-03)**: shared
   `Graphics/color_grade_effect` chain (export refactored onto it),
   `PreviewEngine::SetColorGrade` + paused-nudge, compositor video-only pass,
   headless `PreviewCompositorColorTest` pixel coverage. **Step 2 complete
   pending the golden fixture; both PRs ship in the same release.**
3. **Clip export bake** (deterministic, testable headless): honor `clips` in
   `export_pipeline`. Split into two slices:
   - **3a ✅ done (2026-07-04)** — MONOTONIC edits (cut / trim / delete-middle).
     No MF topology / no seeks / no separate audio pass: the existing interleaved
     loop gets a keep-or-drop gate (`EditedMsForKeptSourceMs` → nullopt = frame/
     packet in a cut gap) + a PTS re-stamp onto the compacted edited timeline.
     Audio + video share one origin (the encoder rebases video by its first
     written frame but writes audio raw, so audio is origin-shifted here and
     buffered until the first kept video frame anchors it — fixes a head-trim A/V
     skew). Zoom smoothing eased on EDITED dt (source dt spikes across a cut and
     would snap the zoom); camera video stays SOURCE-timed while its intro/outro
     clock moves to EDITED time (§5.5). Gate = pure `ClassifyClipEdit`
     (passthrough / bake). Audio is packet-granular (~≤21ms cut-seam
     leak — finer than the frame-granular video cut). The Dart clip editor
     enforces a 2-frame min clip (`TimelineTimebase.minDurationMs`), so a
     sub-frame range that would yield zero frames is unreachable.
   - **3b (DONE, 2026-07-10)** — REORDER + OVERLAP (non-monotonic, §5.3): the
     video path reads each kept range's source window in timeline order via
     per-range backward `SetCurrentPosition` seeks (3b-2a), re-stamped onto a
     contiguous edited PTS. Audio (3b-2b) rides a decoupled pump on its OWN
     reader — per-slot backward seeks, sample-accurate copy + `AudioSlots`
     silence-fill (§5.2 full-slot advance), interleaved with the video writes so
     it never races the throttling sink writer — origin-shifted onto the same
     zero as the video. Zoom smoother reset + camera reader re-primed at each
     backward boundary (§5.5); progress from edited position. Retired the
     reorder/overlap refuse-guard, so cut / trim / delete-middle / reorder /
     overlap all bake now.
4. **Clip live preview** — the **stitched-timeline** approach (§5.4), NOT
   seek-through-cuts. Wire `previewSetClips` to rebuild the stitched timeline
   (debounced) and map edited→source for the overlays + camera (§5.5).
   **✅ Slices 1–4 done (#255–#259, 2026-07-12):** stored ranges → source-reader
   front-end → paused/scrub edited render → pacer continuous playback →
   reorder playback. **Remaining: 4-5/4-6 transport polish + trim-drag rebuild
   hardening, and 4-7 preview AUDIO (edited previews are silent today) — design
   locked in `docs/decisions/windows-editing-step4-7-preview-audio.md`
   (2026-07-19).**
5. Keep the `bridge_contract_coverage_test` honest and add per-feature smoke
   checks (mirror the macOS `RunnerTests` invariants).

**Guiding principle:** the export is the deterministic, headless-testable part —
land it first and unit-test the math; the preview is the interactive, "verify
on-device" part — build it stitched-timeline-first so you never inherit the macOS
seek bugs.

---

## 7. Future roadmap (reference only — not scheduled here)

For the broader editing initiative (tracked in `docs/editing-platform-plan.md`),
the open items after clips+color are:

- **Clip / color persistence across app restarts** — durable editor state (macOS
  `editor_state.json` via `CanvasAppearanceStore`; the plan introduces a net-new
  `post/state.json`). Today the grade + clips reset per session.
- **Windows clip render** — the port this whole doc is about.
- **Remaining friend-features:** audio (boost / **denoise** / source separation) →
  **subtitles + translate** (on-device ASR: WhisperKit on macOS, whisper.cpp on
  Windows; translation with the large-v3-turbo caveat — turbo cannot translate).
- **Zoom lane under cuts (§5.8):** fixed for the display-only lane (#286); only the
  macOS editable lane keeps source coords by design — Windows is unaffected.

---

*Written 2026-07-01, right after macOS PR-3c5 (drag-to-reorder + export bake) and
PR-3e (smooth composition preview) merged to `develop`. If you (the Windows
machine) find any of the above is stale, update this file in the same PR that
touches the code — it is the shared source of truth for the editing-features
port.*
