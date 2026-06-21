# Clingfy editing platform

Clingfy is growing from a screen recorder into a light, local-first video
editor. This document is the operating manual for that work — it lives next to
the code so the plan and the build steps stay in sync with what's actually
checked in, the same way [`windows-port.md`](windows-port.md) does for the
Windows port.

## High-level strategy

> Model every edit as portable Dart in `lib/core/`, sync it live to the native
> preview through the existing bridge, and bake it into the export composition.
> Only the render/export path differs per platform.

This is not a new pattern — zoom, cursor, camera, and background already work
exactly this way. Each new editing feature reuses the same three-part loop:

1. **Model it in portable Dart** (`lib/core/timeline/…`) — a track/effect plus a
   command on the shared undo stack.
2. **Sync to live preview** via a `previewSet*` method on the bridge; native
   updates `InlinePreviewView` (macOS) / `preview_compositor` (Windows).
3. **Bake into export** by adding a pass to `CompositionBuilder.swift` (macOS) /
   the Media Foundation encoder + `preview_compositor.cpp` (Windows).

Because the editing model is portable Dart, macOS and Windows share it; only the
render/export differs. The Dart bridge surface is the source of truth, kept in
three-way sync (Dart / Swift / Windows C++).

## The four features driving this work

A user asked for these so they could drop a paid editor (CapCut). In priority of
*self-containedness* (see roadmap for the build order):

1. **Auto-subtitles + translate** — local speech-to-text, same-language captions,
   translate where supported, editable caption track, sidecar/burn-in export.
2. **Split & cut** — split at the playhead, trim, enable/disable clips.
3. **Audio** — volume boost / normalize (mostly exists) + local noise reduction.
4. **Color improvement** — one-tap auto plus manual grade.

## Status

- [x] Architecture mapped; extension points identified.
- [x] Engine decisions locked (below).
- [x] Foundation design chosen (incremental, immutable tree, global undo).
- [ ] **Phase 0 — foundation** (next; start with PR-0a).
- [ ] Phases 1–5 (features).

## Locked decisions (2026-06-21)

| Area | Decision |
|---|---|
| **Subtitle ASR engine** | WhisperKit on macOS, whisper.cpp on Windows — both on-device, MIT, free. |
| **Whisper model** | User-selectable quality, default **Auto** (large-v3-turbo when hardware allows; small/medium fallback on low-end Windows). |
| **Translation (v1)** | Local transcription + same-language captions + Whisper's **English-only** translation where supported. |
| **Translation (deferred)** | Arbitrary target language via Apple Translation framework (macOS 15+, *only after a prototype proves the batch/headless flow*) and an optional M2M-100 download (Windows / macOS 14, MIT). NLLB-200 rejected (CC-BY-NC). Cloud translation is **not** default — a possible future Clingfy.ai paid/studio feature. |
| **Subtitle export** | Default = video + `.srt` + `.vtt` sidecars. Burn-in is an opt-in export mode; "both sidecar + burned-in" is an optional checkbox, never automatic. |
| **Noise reduction** | RNNoise (open-source, cross-platform C), as a pre-mix filter on the mic source. |
| **Build order** | Foundation first; then features easiest/most-self-contained first. |
| **Pricing / gating** | **No separate Pro gates inside the local editor for v1.** All local editing rides the existing app-level trial/license gate. Trial = 14 days OR 3 exports with all local editing available. The paid license covers all local editing. Future cloud features (batch, team, hosted Clingfy.ai processing, cloud translation, studio-enhance) become paid add-ons / subscription / credits later. **Windows: keep gating disabled / feature-flagged until licensing smoke tests pass.** |

**Implication of the pricing decision:** each feature phase needs *zero*
per-feature gating code — reuse the existing export-time license gate
(`LicenseController.canExport`). One follow-up: verify the current gate actually
enforces *14 days OR 3 exports*; if not, that trial logic is its own small task,
separate from the editor features.

## Architecture context — where editing plugs in

> **Verified paths** (an earlier brief had stale names — these are the real ones):
>
> - macOS audio gain/mix and render live in the **export composition path**:
>   `macos/Runner/Capture/Export/CompositionBuilder.swift` and
>   `LetterboxExporter.swift`. There is **no** `AudioMixEngine.swift`;
>   `macos/Runner/Capture/Audio/` currently holds only level estimators.
> - Windows audio = `windows/runner/Audio/audio_mixer.cpp`; export =
>   `windows/runner/Encoding/mf_sink_writer_encoder.cpp` +
>   `windows/runner/preview/preview_compositor.cpp` (there is no
>   `export_pipeline.cpp`; the *test* `export_pipeline_test.cpp` exists).
> - Bridge command names are **inline string literals** in
>   `lib/core/bridges/native_bridge.dart` (e.g. `'previewSetZoomSegments'`),
>   **not** named constants — `native_method_channel.dart` only holds
>   event/callback names. Phase 0 promotes these to constants.
> - Durable editor state today is `editor_state.json` (via
>   `CanvasAppearanceStore`). The new `post/state.json` is net-new.

The relevant existing seams:

- **Editing model / undo:** `lib/core/zoom/zoom_editor_controller.dart` is the
  only part with an undo stack today (`ZoomEditCommand`). It is the prototype the
  foundation generalizes. Everything else is flat fields on
  `lib/app/home/post_processing/post_processing_controller.dart`, fired to native
  eagerly with no transaction.
- **Live preview:** `macos/Runner/Preview/InlinePreviewView.swift` (60 Hz CALayer
  tree); `windows/runner/preview/preview_compositor.cpp`.
- **Export bake:** `CompositionBuilder.swift`
  (`AVMutableVideoComposition` + `AVVideoCompositionCoreAnimationTool`) /
  the Windows MF encoder.
- **Durable artifact:** the `.clingfyproj` bundle.

## A. The foundation (Phase 0)

**Goal:** deliver the one missing primitive — a unified, transactional,
globally-undoable edit model in portable Dart — *without* touching `ZoomSegment`,
the `CompositionBuilder` zoom/camera paths, or any passing zoom test. Every PR
ships independently. Windows gets a parity stub the same day macOS gets the real
implementation.

### New portable package: `lib/core/timeline/`

```
lib/core/timeline/
  timeline_timebase.dart      # TimelineTimebase  (PR-0a, zero native)
  edit_command.dart           # EditCommand, CompositeCommand
  edit_session.dart           # EditSession  (undo/redo/batch/dirty-domain flush)
  model/
    timeline.dart             # Timeline (immutable, copyWith, structural sharing)
    edit_track.dart           # sealed EditTrack + TrackKind
    zoom_track.dart           # ZoomTrack (wraps existing auto/manual ZoomSegment)
    clip_track.dart           # ClipTrack + Clip
    caption_track.dart        # CaptionTrack + Caption + CaptionStyle
    audio_track.dart          # AudioTrack
    color_grade.dart          # ColorGrade (canvas-wide, lives on Timeline)
  codec/
    timeline_codec.dart       # single read/write path -> post/state.json
    state_migrator.dart       # legacy (editor_state.json + manual zoom) -> Timeline
```

### Key classes

```dart
// Pure, zero-native: lift frameMs/snapToGrid/normalizeEditableMs out of
// ZoomEditorController so every track agrees on the frame grid.
class TimelineTimebase {
  final int durationMs;
  static const double frameMs = 1000.0 / 60.0;
  int snapToGrid(int ms);          // identical math to today
  int normalizeEditableMs(int ms); // clamp + snap, identical to today
}

// Immutable tree; copyWith at track/clip level (structural sharing) so 60 Hz
// drag previews don't churn GC.
class Timeline {
  final int durationMs;            // authoritative clock (defined by ClipTrack)
  final List<EditTrack> tracks;
  final ColorGrade grade;
  final int schemaVersion;
  Timeline copyWith({/* ... */});
}

sealed class EditTrack { final String id; final TrackKind kind; final bool enabled; }
enum TrackKind { zoom, clip, caption, audio }

// Explicit source-vs-timeline coordinates make multi-clip arrange tractable
// later at ~zero cost now.
class Clip {
  final String id;
  final int sourceInMs, sourceOutMs;   // in/out into the captured media
  final int timelineStartMs;           // position on the timeline
  final bool enabled;
}

// ZoomSegment stays byte-untouched; ZoomTrack is a thin shell over it.
class ZoomTrack extends EditTrack {
  final List<ZoomSegment> auto;
  final List<ZoomSegment> manual;
}
```

The undo/transaction core generalizes `ZoomEditCommand`. Because the tree is
immutable, commands are pure reducers, which collapses today's manual snapshot
bookkeeping to "previous tree."

```dart
abstract class EditCommand {
  Timeline apply(Timeline t);
  EditDomain get domain;           // zoom | clips | captions | audio | color
  String get label;
}

class EditSession extends ChangeNotifier {
  Timeline _timeline;
  final _undo = <Timeline>[];      // ONE global stack
  final _redo = <Timeline>[];      // redo is NET-NEW (doesn't exist today)
  // ...
  void execute(EditCommand c);     // apply -> push prev -> clear redo -> flush
  void beginBatch();               // drag start: stash one baseline
  void preview(Timeline staged);   // live tree, NO undo entry -> previewSet* only
  void endBatch();                 // one undo entry for the whole drag
  void cancelBatch();
  void undo(); void redo();
  void _flush();                   // debounced; routes ONLY dirty domains to previewSet*
}
```

Two fixes fall out: **transactions** collapse a slider drag into one undo entry,
and **dirty-domain flush** replaces "every setter calls full `processVideo`" with
per-effect `previewSet*` routing.

### `post/state.json` schema (v2)

```jsonc
{
  "schemaVersion": 2,
  "timeline": {
    "durationMs": 0,
    "grade": { "autoEnabled": false, "exposure": 0, "contrast": 0,
               "saturation": 0, "temperature": 0, "tint": 0 },
    "tracks": [
      { "kind": "zoom",    "auto": [/* ZoomSegment.toMap() */], "manual": [/* ... */] },
      { "kind": "clip",    "clips": [ {"id":"","sourceInMs":0,"sourceOutMs":0,"timelineStartMs":0,"enabled":true} ] },
      { "kind": "audio",   "source": "mixed", "gainDb": 0, "volumePercent": 100,
                           "normalize": false, "noise": {"enabled": false, "strength": 0.6} },
      { "kind": "caption", "language": "en", "sourceLanguage": "en",
                           "style": {}, "captions": [ {"id":"","startMs":0,"endMs":0,"text":""} ] }
    ]
  }
}
```

`TimelineCodec` is the single read/write path. **Cutover discipline:**
read-old / write-both until cutover; on a crash mid-migration prefer the legacy
files; unknown `schemaVersion` or track `kind` → defaults / dropped-with-log,
never a crash, so old projects always open.

### Migration — small, always-shippable PRs

| PR | Title | Behavior change | Risk gate |
|---|---|---|---|
| **0a** | `TimelineTimebase` extract (ZoomEditorController delegates) | none | existing zoom tests stay green |
| **0b** | `EditCommand` + `EditSession` (undo/redo/batch/dirty) | undo becomes global; **redo arrives** | full `test/core/zoom/*` must pass |
| **0c** | `Timeline` tree + `TimelineCodec` + `StateMigrator` | none (round-trip) | round-trip test |
| **0d** | Promote inline bridge strings → constants (3 langs) | none | bridge-contract tests both sides |

**Stays untouched through Phase 0:** `ZoomSegment`
(`lib/core/models/app_models.dart`), the `CompositionBuilder` zoom/camera paths,
`previewSetCameraPlacement`, camera state, all zoom tests. `CanvasAppearanceStore`
becomes a v1 reader wrapped by `StateMigrator`. `PostProcessingController` keeps
export orchestration and sheds eager setters one feature-PR at a time.

**Intermediate UX caveat:** between PR-0b and the last feature PR, undo is partial
per-domain (zoom/audio undoable before color/captions). Acceptable and shippable;
note it in the UI.

### Two contracts locked into the bridge spec now

1. **Single pooled caption layer.** Captions render as **one** keyframed
   `CATextLayer` (macOS) / one DirectWrite pass (Windows), swapped per visible
   cue — never one layer per cue. The reducer emits only currently-visible cues.
   This keeps the `AVVideoCompositionCoreAnimationTool` ~100-layer cliff from
   being discovered late.
2. **Windows stub-day-one.** Every new `previewSet*` lands as a Windows no-op
   stub the same day as macOS, capability-gated like `ZoomNativeCapabilities`.
   Windows never silently diverges per-feature again (the Phase 8.3 wound).

## B. Phased roadmap (Mac-first, then Windows)

Order is easiest/most-self-contained first, **with one deviation:** split/cut
moves *ahead* of noise reduction because `ClipTrack` defines the authoritative
`durationMs` that captions and zoom re-clamp against, and it is the lowest native
risk (AVFoundation `insertTimeRange`, no new render pass).

**Final order:** (1) volume/normalize UI → (2) color → (3) split & cut →
(4) noise reduction → (5) subtitles + translate.

Each phase ships across Dart core (`lib/core/timeline/…`), Dart app (panel UI +
route setters through `EditSession`), macOS Swift, Windows C++ (stub day-one), the
bridge, and tests on both sides. The bridge checklist per new method: ① Dart
constant ② Swift constant ③ Windows constant ④ `NativeBridge` method/registry
⑤ Swift handler ⑥ Windows handler/stub ⑦ keep the "sync with Swift" comment honest
⑧ tests both sides.

### Phase 1 — volume / normalize UI *(mostly exists)*

Route the existing `postAudioGainDb` / `postAudioVolumePercent` setters through
`EditSession` (kills two eager setters) and add a `normalize` toggle. Additive to
the existing `setAudioMix` args; no new method. macOS: consume `normalize` in the
audio-mix path of `CompositionBuilder.swift` / `LetterboxExporter.swift`. Windows:
`normalize` branch in `audio_mixer.cpp`. Tests: `test/core/timeline/audio_track_test.dart`,
macOS audio-mix assertion, Windows `audio_mixer_test.cpp` (extend).

### Phase 2 — color: one-tap auto + manual grade

New `ColorGrade` on the Timeline (canvas-wide). New `previewSetColorGrade` +
`exportVideo` `colorGrade` key. Portable `lib/core/color/auto_grade_heuristic.dart`
for one-tap. macOS: new `ColorGradeRenderer.swift` — `CIColorControls` + `CIToneCurve`
appended to the per-frame CIFilter chain in `CompositionBuilder.swift`; preview hook
in `InlinePreviewView.swift`. Windows: new `Graphics/color_grade.cpp` — Direct2D
color matrix in `preview_compositor.cpp` + MF encoder. Tests: heuristic + command
(Dart), `ColorGradeRendererTests.swift`, `color_grade_test.cpp`.

### Phase 3 — split & cut *(foundation-critical: defines duration)*

Split at playhead, trim, enable/disable, delete. Defers true multi-clip rearrange.
`lib/core/timeline/model/clip_track.dart` + split/trim/delete commands (reuse the
timebase snap + zoom merge/snap utilities). New `previewSetClips` +
`exportVideo` `clips` key. macOS: build `AVMutableComposition` with one
`insertTimeRange` per enabled clip — **no new render pass**. Windows: source
segment ranges in the MF encoder + preview engine. Cross-track re-clamp consults
`TimelineTimebase.durationMs`. Tests: clip track + split/trim + re-clamp (Dart),
composition-range (macOS), `export_pipeline_test.cpp` (extend).

### Phase 4 — noise reduction (RNNoise)

RNNoise as a pre-mix filter on the mic source. macOS: new
`macos/Runner/Capture/Audio/NoiseReducer.swift` wrapping vendored RNNoise C,
invoked in the mic-mix stage. Windows: new `windows/runner/Audio/noise_reducer.cpp`
invoked pre-mix in `audio_mixer.cpp`. RNNoise wants **48 kHz mono, 480-sample
frames** — on Windows the native 48 kHz f32 format already matches (only mono
framing + float↔int16 conversion needed, no resampler). Extend the `setAudioMix`
args with `noise{enabled,strength}` (additive). Vendor RNNoise as a submodule +
CMake / SPM-or-bridged C target (build-system task in the Phase-4 PR). Tests:
command (Dart), `NoiseReducerTests.swift` (frame size/passthrough), `audio_mixer_test.cpp`
(denoise branch).

### Phase 5 — subtitles + translate *(the big one)*

See section C.

## C. Subtitles + translate deep-dive

### Pipeline

```
audio (from .clingfyproj capture/)
  -> ASR: WhisperKit (mac) / whisper.cpp (win)   [MIT, on-device, free, batch]
  -> timestamped Caption[] (segment + word timings)
  -> [optional] translate to English (Whisper) ; arbitrary target deferred
  -> editable CaptionTrack on the timeline (undoable via EditSession)
  -> render:  .srt/.vtt sidecar (default)  AND/OR  burn-in (opt-in)
```

### ASR

- **macOS:** WhisperKit (Argmax, MIT), SPM, min macOS 14, Core ML on ANE/GPU.
  Default model **Auto** → large-v3-turbo (~626 MB) when hardware allows,
  downloaded on first use. Exposes segment + word timestamps.
- **Windows:** whisper.cpp (MIT), Vulkan default GPU backend (cross-vendor) + CPU
  fallback, ggml `.bin` models; emits SRT/VTT natively.
- Batch on a finished recording, so real-time factor is not a blocker.

### Translation

Whisper only translates **to English** (both platforms). v1 ships transcription +
same-language captions + English-only translation. Arbitrary target language is
deferred:

| Tier | Engine | Notes |
|---|---|---|
| macOS 15+ | **Apple Translation framework** | on-device, free, zero app weight — *prototype the headless/batch flow before committing* (it is SwiftUI-coupled; this is the largest unknown). |
| Windows / macOS 14 | **M2M-100 418M** (MIT, ~1.5 GB, any→any) | optional download. |
| Rejected | NLLB-200 | CC-BY-NC — disqualified for a paid product. |
| Future paid | DeepL/Google cloud | not default; possible Clingfy.ai studio feature. |

### Data shape (portable, mirrors `ZoomSegment`)

```dart
class CaptionWord { final String text; final int startMs, endMs; }
class Caption {
  final String id; final int startMs, endMs; final String text;
  final List<CaptionWord> words;   // click-to-edit, drag-retime, reflow-on-split
  final String? translatedText;
}
class CaptionTrack extends EditTrack {
  final String language; final String? sourceLanguage;
  final CaptionStyle style; final List<Caption> captions;
}
```

### Render

- **Sidecar `.srt`/`.vtt` (default):** portable Dart serializer
  `lib/core/captions/srt_vtt_serializer.dart`; lossless, editable, zero render
  cost, sidesteps the layer ceiling.
- **Burn-in (opt-in):** macOS = one `CATextLayer` driven by a `CAKeyframeAnimation`
  in `CompositionBuilder.swift`; Windows = DirectWrite per active cue. One layer
  regardless of caption count (foundation contract).
- **Both:** optional checkbox, never automatic.

### Bridge additions (async + progress)

- `generateCaptions(projectPath, modelTier, sourceLang?) -> captionTrack` — async,
  progress via `workflow/events` `asrProgress`.
- `translateCaptions(captions, targetLang) -> captions` — async, progress via
  `workflow/events` `mtProgress`.
- `previewSetCaptions(captions, style, sessionId)` — live preview.
- `exportVideo` args gain `captions` + `subtitleMode` (`burnIn` | `sidecar` | `both`).

### Model picker (decision #3)

Small addition: a quality setting (default **Auto**) plus a portable
`lib/core/captions/model_picker.dart` heuristic (RAM/GPU → turbo vs small/medium),
surfaced as one settings widget.

## D. Cross-cutting risks

- **Windows zoom-edit gap (Phase 8.3):** split/cut does **not** depend on it —
  `previewSetClips` is a new method with a day-one stub. Finish the Windows
  manual-zoom bridge as an independent cleanup once `previewSetClips` proves the
  parallel-stub pattern.
- **~100-CALayer / Core Animation render ceiling:** mitigated by one pooled
  caption layer + a single CIFilter color pass + sidecar-default subtitles. If
  heavy stacks still degrade, the long-term fix is a Metal/`CIImage` render path
  replacing `CoreAnimationTool` — a future spike, not a Phase-5 blocker.
- **Windows audio rigidity (48 kHz f32 stereo, no resampler):** *helps* RNNoise
  (rate already matches). Would *block* future TTS/music import (needs a
  resampler) — out of scope for these four features.
- **Licensing untested on Windows:** keep editing free/feature-flagged on Windows
  until a licensing smoke pass on the existing entitlement UI
  (`lib/commercial/licensing/`) passes.

## E. Recommended first move

**PR-0a: extract `TimelineTimebase` into
`lib/core/timeline/timeline_timebase.dart`; make `ZoomEditorController` delegate to
it.** Zero native, zero bridge, zero UI — pure Dart, fully unit-testable, can't
break either platform. It kills the highest-severity silent bug (cross-track
frame-boundary disagreement) before a second track exists, and proves the "extract
from zoom without touching `ZoomSegment` or its tests" discipline the whole
foundation rides on. Then 0b → 0c → 0d → Phase 1.

## The recipe for adding a feature

1. Add the model + command in `lib/core/timeline/` (+ tests).
2. Route the UI through `EditSession.execute` (no eager setters).
3. Add the `previewSet*` bridge method across all three sides; ship the Windows
   no-op stub the same day.
4. Implement the macOS render/export pass; implement the Windows pass.
5. Persist via `TimelineCodec` into `post/state.json`.
6. No per-feature license gate — rely on the existing export-time gate.
7. Tests on both sides; keep the bridge-contract sync tests green.
