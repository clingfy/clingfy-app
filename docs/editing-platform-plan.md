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

A user asked for these so they could drop a paid editor (CapCut):

1. **Auto-subtitles + translate** — local speech-to-text, same-language captions,
   translate where supported, editable caption track, sidecar/burn-in export.
2. **Split & cut** — split at the playhead, trim, enable/disable clips.
3. **Audio** — volume boost / normalize + local voice cleanup (noise reduction).
4. **Color improvement** — one-tap auto plus manual grade.

## Status

- [x] Architecture mapped; extension points identified.
- [x] Engine decisions locked (below).
- [x] Foundation design chosen (incremental, immutable tree, global undo).
- [x] Plan reviewed; audio/ASR adjustments folded in (audio source separation,
      resampling, pluggable enhancement, model manager).
- [ ] **Phase 0 — foundation** (next; start with PR-0a).
- [ ] Phases 1–5 (features).

## Locked decisions

| Area | Decision |
|---|---|
| **Subtitle ASR engine** | WhisperKit on macOS, whisper.cpp on Windows — both on-device, MIT, free. |
| **Whisper model** | User-selectable quality, default **Auto** (large-v3-turbo when hardware allows; small/medium fallback on low-end Windows). |
| **Whisper translation caveat** | `large-v3-turbo` returns the original language even with `--task translate` — **it cannot translate**. English translation requires a **medium or large** model. If Auto picked turbo, translation prompts a translation-capable model download (see §C). |
| **Translation (v1)** | Local transcription + same-language captions + Whisper's **English-only** translation, and only on a medium/large model. |
| **Translation (deferred)** | Arbitrary target language via Apple Translation framework (macOS 15+, *only after a prototype proves the batch/headless flow*) and an optional M2M-100 download (Windows / macOS 14, MIT). NLLB-200 rejected (CC-BY-NC). Cloud translation is **not** default — a possible future Clingfy.ai paid/studio feature. |
| **Audio source separation** | **Keep mic and system audio as separate sources inside the `.clingfyproj` bundle until export.** Never denoise a pre-mixed track — that damages system/music/game/app audio. (See Phase 1.5.) |
| **Audio format** | One internal format — **48 kHz float32** — converted at the edges with platform-native resamplers (Media Foundation Audio Resampler DSP on Windows, `AVAudioConverter` on macOS). Mic enhancement runs on a 48 kHz **mono** copy; the final mix is 48 kHz **stereo**. (See Phase 3.5.) |
| **Voice cleanup (noise reduction)** | A **pluggable `AudioEnhancementPipeline`**. v1 engine = **RNNoise** (small, local, C, 48 kHz). Future local **High-Quality** engine = **DeepFilterNet** (full-band 48 kHz). Optional future cloud = Clingfy.ai add-on. **The UI never names engines** — it exposes `Voice Cleanup: Off / Light / Balanced / High Quality`; internally Light/Balanced → RNNoise, High Quality → DeepFilterNet (later). |
| **Subtitle export** | Default = video + `.srt` + `.vtt` sidecars. Burn-in is an opt-in export mode; "both sidecar + burned-in" is an optional checkbox, never automatic. |
| **Local models** | A first-class `LocalModelManager` (download-on-first-use, hash verify, version, disk usage, delete, offline state, per-model license note) for WhisperKit / whisper.cpp models and, later, DeepFilterNet / M2M-100. Built early, not as an afterthought (see §A.7). |
| **Export quality** | Audio presets — Standard (AAC 128 kbps), High (192 kbps), Best (256 kbps). Video keeps existing presets, with one rule: when effects force a re-encode of text/UI-heavy screen video, bump one step higher than the camera-footage default (see §B, Export quality). |
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
> - Windows audio = `windows/runner/Audio/audio_mixer.cpp` (today
>   `AudioMixer::Mix` *sums* mic + system into one stream — see Phase 1.5);
>   export = `windows/runner/Encoding/mf_sink_writer_encoder.cpp` +
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
    audio_track.dart          # AudioTrack with SEPARATED mic/system sources
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

### Audio model — separated sources from day one

`AudioTrack` models mic and system as **separate sources** so the mic can be
denoised/boosted without touching system audio. Older recordings without
separated capture fall back to a single mixed path.

```dart
class AudioSource {
  final String? path;        // capture/mic.wav | capture/system.wav (null if absent)
  final double gainDb;
  final bool normalize;
  final VoiceCleanup? cleanup;   // mic only in practice
}
class VoiceCleanup {
  final bool enabled;
  final CleanupMode mode;    // light | balanced | highQuality  (UI labels)
  // engine is chosen internally by AudioEnhancementPipeline, never shown.
}
class AudioTrack extends EditTrack {
  final AudioSource? mic;
  final AudioSource? system;
  final String? mixedFallbackPath;   // for legacy recordings (no separation)
  final double masterGainDb;
  final bool limiter;
}
```

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
      {
        "kind": "audio",
        "sources": {
          "mic":    { "path": "capture/mic.wav", "gainDb": 0, "normalize": true,
                      "voiceCleanup": { "enabled": false, "mode": "balanced" } },
          "system": { "path": "capture/system.wav", "gainDb": 0 }
        },
        "mixedFallbackPath": null,
        "mix": { "masterGainDb": 0, "limiter": true }
      },
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

### A.7 Local model manager (built early)

Because the app ships several on-device models, a `LocalModelManager` is a
first-class subsystem, not an afterthought:

```
lib/core/models/local_model_manifest.dart   # model ids, sizes, hashes, licenses, capabilities
lib/core/models/model_download_manager.dart  # download-on-first-use, verify, version, delete
```

Native model caches:

- macOS: `Application Support / Clingfy / Models`
- Windows: `%LOCALAPPDATA% / Clingfy / Models`

Responsibilities: download on first use, hash verification, disk-usage reporting,
delete-model, model versioning, offline-unavailable state, and a per-model
license note (e.g. transcription-capable vs translation-capable Whisper builds,
DeepFilterNet, M2M-100). It backs the ASR model picker (§C) and, later, the
High-Quality voice-cleanup and translation downloads. The official signed app
should make all of this feel reliable and easy even though the project is
open-source and local-first.

## B. Phased roadmap (Mac-first, then Windows)

Order is easiest/most-self-contained first, **with one deviation:** split/cut
moves *ahead* of voice cleanup because `ClipTrack` defines the authoritative
`durationMs` that captions and zoom re-clamp against, and it is the lowest native
risk (AVFoundation `insertTimeRange`, no new render pass). Two audio-quality
sub-phases (1.5 source separation, 3.5 format normalization) are sequenced so
that by the time voice cleanup lands, the audio pipeline is clean.

**Final order:** (1) volume/normalize → (1.5) audio source separation →
(2) color → (3) split & cut → (3.5) audio format normalization →
(4) voice cleanup → (5) subtitles + translate.

Each phase ships across Dart core (`lib/core/timeline/…`), Dart app (panel UI +
route setters through `EditSession`), macOS Swift, Windows C++ (stub day-one), the
bridge, and tests on both sides. The bridge checklist per new method: ① Dart
constant ② Swift constant ③ Windows constant ④ `NativeBridge` method/registry
⑤ Swift handler ⑥ Windows handler/stub ⑦ keep the "sync with Swift" comment honest
⑧ tests both sides.

### Phase 1 — volume / normalize *(mostly exists)*

Route the existing gain/volume setters through `EditSession` (kills two eager
setters) and add a `normalize` toggle, modelled on the new `AudioTrack`
(master gain initially; per-source once 1.5 lands). Additive to the existing
audio-mix args; no new method. macOS: consume in the audio-mix path of
`CompositionBuilder.swift` / `LetterboxExporter.swift`. Windows: in
`audio_mixer.cpp`. Tests: `audio_track_test.dart`, macOS audio-mix assertion,
`audio_mixer_test.cpp` (extend).

### Phase 1.5 — audio source separation *(quality-critical)*

**Preserve raw mic and raw system audio separately** in the `.clingfyproj`
bundle so downstream stages (cleanup, voice boost, voice-only export) never have
to un-mix.

- **Capture:** write `capture/mic.wav` (or `.m4a`) and `capture/system.wav`
  separately; keep an optional `capture/mixed_preview.m4a` for cheap playback.
  macOS: split the capture tap. Windows: stop `AudioMixer::Mix` from summing into
  one stream during recording — persist both sources, mix only at export/preview.
- **Model:** the `AudioTrack` separated-source schema (above) becomes the live
  shape; legacy recordings use `mixedFallbackPath`.
- **Export chain becomes:** `raw mic → cleanup → normalize/boost/limiter → mix
  with system → final AAC`.
- Tests: capture writes two sources; codec round-trips separated sources; legacy
  fallback path still opens.

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

### Phase 3.5 — audio format normalization *(quality-critical)*

A small internal audio-conversion layer so cleanup, ASR, and any future import
all see one clean format:

```
any input format
  -> convert to internal 48 kHz float32
  -> 48 kHz MONO copy for mic enhancement
  -> 48 kHz STEREO for the final mix/export
```

- **Windows:** Media Foundation **Audio Resampler DSP** (`Wmcodecdsp.h`) to
  change sample rate / channel count — native, no heavy dependency. Removes the
  current "drop unsupported formats with a warning" behavior.
- **macOS:** `AVAudioConverter` equivalent.
- Tests: resample correctness (rate + channel count), mono/stereo split, a
  non-48 kHz input no longer dropped.

### Phase 4 — voice cleanup (noise reduction) — SHIPPED on macOS

A **pluggable `AudioEnhancementPipeline`** applied to the **mic source only**
(after 1.5/3.5 there is a clean 48 kHz mono mic copy to feed it).

- **v1 engine:** RNNoise (vendored as a submodule + CMake / SPM-or-bridged C
  target — a build-system task in this PR). 48 kHz, 480-sample mono frames.
- **Future High-Quality engine:** DeepFilterNet (full-band 48 kHz), downloaded
  via the `LocalModelManager`. The pipeline interface is engine-agnostic so this
  drops in later without touching callers.
- **UI:** `Voice Cleanup: Off / Light / Balanced / High Quality` — **no engine
  names.** Light/Balanced → RNNoise; High Quality → DeepFilterNet (later).
- macOS: new `macos/Runner/Capture/Audio/AudioEnhancementPipeline.swift` +
  `RNNoiseEngine.swift`. Windows: new `windows/runner/Audio/audio_enhancement.cpp`
  invoked pre-mix in `audio_mixer.cpp`. Extend audio args with
  `voiceCleanup{enabled,mode}` (additive).
- Tests: pipeline mode→engine routing (Dart), `RNNoiseEngineTests.swift`
  (frame size/passthrough), `audio_mixer_test.cpp` (cleanup branch).

**Landed (macOS):** RNNoise v0.2 is vendored at
`macos/Runner/Capture/Audio/RNNoise/`, wrapped by `RNNoiseEngine.swift`
and the engine-agnostic `AudioEnhancementPipeline.swift`, cached per
project by `EnhancedMicCache` and spliced into the export mic chain
between echo cancellation and the normalize/gain stage. Two deviations
from this plan, both deliberate:

- The UI exposes **Off / Light / Balanced** only. `High Quality` was to
  mean DeepFilterNet, which is not vendored, so offering the level would
  have been a relabelled Balanced. The `highQuality` wire value still
  parses (and runs RNNoise at full strength) so a project written by a
  future build opens correctly.
- Windows is **not** stubbed at `audio_mixer.cpp` as sketched here. That
  is a capture-time hook, so it could not honour a post-hoc Off/Light/
  Balanced change. With audio separation landed, the right Windows
  insertion point is the export/preview mic pump — before
  `ResolveAudioGainStages` in `export_pipeline` — mirroring the macOS
  ordering. What actually blocks the port is the build: both Windows CMake
  projects declare `LANGUAGES CXX` only, so the vendored C needs
  `enable_language(C)` or its own C target. Until then the bridge method is
  a no-op and the control is hidden there.

### Phase 5 — subtitles + translate *(the big one)*

See section C.

## C. Subtitles + translate deep-dive

### Pipeline

```
mic source (from .clingfyproj capture/, post-cleanup)
  -> ASR: WhisperKit (mac) / whisper.cpp (win)   [MIT, on-device, free, batch]
  -> timestamped Caption[] (segment + word timings)
  -> [optional] translate to English (medium/large model only)
  -> editable CaptionTrack on the timeline (undoable via EditSession)
  -> render:  .srt/.vtt sidecar (default)  AND/OR  burn-in (opt-in)
```

### ASR

- **macOS:** WhisperKit (Argmax, MIT), SPM, min macOS 14, Core ML on ANE/GPU.
- **Windows:** whisper.cpp (MIT), Vulkan default GPU backend (cross-vendor) + CPU
  fallback, ggml `.bin` models.
- **Model selection (Auto):** Best Accuracy → large-v3-turbo when hardware
  allows; Fast/Balanced → small/medium. Models are managed by the
  `LocalModelManager` (§A.7).
- Batch on a finished recording, so real-time factor is not a blocker.

### Translation (with the turbo caveat)

Whisper only translates **to English** (both platforms), and **`large-v3-turbo`
cannot translate at all** — it returns the original language even with the
translate task. So:

```
Transcription model (Auto):
  - Best Accuracy: large-v3-turbo when hardware allows
  - Fast/Balanced: small/medium

English translation:
  - NOT supported by turbo
  - Requires a medium or large model
  - If the user is on turbo, show:
    "English translation requires downloading a translation-capable Whisper model."
    (download via LocalModelManager)
```

This avoids the confusing bug where transcription works but translation silently
returns the source language. Arbitrary target language stays deferred:

| Tier | Engine | Notes |
|---|---|---|
| macOS 15+ | **Apple Translation framework** | on-device, free, zero app weight — *prototype the headless/batch flow before committing* (it is SwiftUI-coupled; this is the largest unknown). |
| Windows / macOS 14 | **M2M-100 418M** (MIT, ~1.5 GB, any→any) | optional download via `LocalModelManager`. |
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

A quality setting (default **Auto**) plus a portable
`lib/core/captions/model_picker.dart` heuristic (RAM/GPU → turbo vs small/medium),
surfaced as one settings widget and backed by the `LocalModelManager` (§A.7),
which also enforces the translation-capable-model rule above.

## Export quality

Add an export-quality setting alongside the existing presets:

| Preset | Audio |
|---|---|
| Standard | AAC 128 kbps stereo (today's default) |
| High | AAC 192 kbps stereo |
| Best | AAC 256 kbps stereo |

Video keeps the existing bitrate presets, with one rule: **when effects force a
re-encode of text/UI/code-heavy screen video, default one step higher than the
camera-footage bitrate** — text and sharp UI edges show compression artifacts
faster than camera footage.

## D. Cross-cutting risks

- **Windows zoom-edit gap (Phase 8.3):** split/cut does **not** depend on it —
  `previewSetClips` is a new method with a day-one stub. Finish the Windows
  manual-zoom bridge as an independent cleanup once `previewSetClips` proves the
  parallel-stub pattern.
- **~100-CALayer / Core Animation render ceiling:** mitigated by one pooled
  caption layer + a single CIFilter color pass + sidecar-default subtitles. If
  heavy stacks still degrade, the long-term fix is a Metal/`CIImage` render path
  replacing `CoreAnimationTool` — a future spike, not a Phase-5 blocker.
- **Windows audio rigidity (48 kHz f32 stereo, no resampler):** addressed by
  **Phase 3.5** (internal resampler via the Media Foundation Audio Resampler DSP).
  Until then, RNNoise is unaffected (its 48 kHz rate already matches), but
  non-48 kHz import stays unsupported.
- **Pre-mixed legacy audio:** recordings made before Phase 1.5 have no separated
  sources — cleanup/voice-boost on those is best-effort via `mixedFallbackPath`
  and the UI should say so.
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
