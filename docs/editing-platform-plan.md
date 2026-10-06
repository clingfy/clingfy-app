# Clingfy editing platform

Clingfy grew from a screen recorder into a light, local-first video editor. This
document is the operating manual for that work — it lives next to the code so the
plan and the build steps stay in sync with what's actually checked in, the same
way [`windows-port.md`](windows-port.md) does for the Windows port.

> **Rewritten 2026-09-30 against the code, not against itself.** The previous
> revision claimed Phase 0 was "next; start with PR-0a". PR-0a
> ([#177](https://github.com/clingfy/clingfy-app/pull/177)) merged on 2026-06-21, the
> day after this file was created — so that line was wrong for 101 days and four
> releases. Every status claim below was re-derived from `lib/`, `macos/`,
> `windows/` and `CHANGELOG.md` on 2026-09-30. Where the plan and the code
> disagree, the code is recorded as the truth and the deviation is named.

## Where this stands

Four of the five feature phases shipped. The foundation shipped too, but not in
the shape this document specified, and one of its four PRs was abandoned midway.

| Phase | Planned | Reality | Shipped in |
|---|---|---|---|
| **0 — foundation** | one global `EditSession`, 4 PRs | built, **fragmented into four independent sessions**; PR-0d finished late | 1.0.5 – 1.0.6, PR-0d 2026-10-05 |
| **1 — volume / normalize** | per-source gain once 1.5 lands | **half-done, and bigger than it looks.** The model has per-source `gainDb`/`normalize` (1.0.5) but is constructed nowhere in `lib/`; the UI sends one flat value; and **native pins system gain at unity by design on both platforms**. Splits into 1a (Dart scope/plumbing) and 1b (native system gain) | model 1.0.5, UI never |
| **1.5 — audio source separation** | separate mic/system to export | **shipped**, but **additively** — `screen.mov` still carries the muxed track | 1.0.6 |
| **2 — colour** | auto + manual grade | **shipped** both platforms; Windows diverges numerically (see §D) | 1.0.5 |
| **3 — split & cut** | split/trim/enable, rearrange deferred | **shipped, and overshot the plan** — clip reorder landed too | 1.0.5 |
| **3.5 — audio format normalization** | 48 kHz float32 internal | **shipped**; Windows non-48 kHz inputs now work | 1.1.0 |
| **4 — voice cleanup** | RNNoise, macOS then Windows | **shipped both platforms.** High Quality / DeepFilterNet still unbuilt | 1.0.6 |
| **5 — subtitles** | ASR + translate | **transcription shipped** (macOS, Apple silicon). **Translation unbuilt. Windows ASR unbuilt.** | 1.1.0, refined 1.2.0 |
| **Export audio presets** | Standard 128 / High 192 / Best 256 | **shipped 2026-10-06 as 192 / 256 / 320**, macOS only. The plan's ladder was written believing today's default was 128 kbps; macOS has always exported 192. Windows was at 128 and is raised to 192 | 1.3.0 (unreleased) |
| **`LocalModelManager`** | first-class, built early (§A.7) | **unbuilt as specified.** Only caption-specific `caption_model_info.dart` exists | — |

**Release dates:** 1.0.5 (2026-07-01), 1.0.6 (2026-07-22), 1.0.7 (2026-08-01),
1.1.0 (2026-09-20), 1.2.0 (changelog 2026-09-23, published 2026-09-27).

### What the plan got wrong, and why it matters

Worth recording, because this repo's planning docs drift in the same direction
every time:

1. **The build order inverted.** The plan's order was 1 → 1.5 → 2 → 3 → 3.5 → 4
   → 5. What happened was 2 and 3 first (1.0.5), then 1.5 and 4 (1.0.6), then 3.5
   and 5 (1.1.0) — with Phase 1 still unfinished today. The foundation was built
   *around* the features rather than ahead of them, and it mostly worked.
2. **"One global undo stack" did not survive contact.** The plan's central
   primitive was a single `EditSession`. There are four
   (`clip_editor_controller.dart:40`, `zoom_editor_controller.dart:458`,
   `post_processing_controller.dart:313` and `:321`). Undo is per-domain and
   always has been. The plan called this an "intermediate UX caveat" expected to
   resolve by the last feature PR; it never did.
3. **The schema moved three versions past the documented one.**
   `kTimelineSchemaVersion = 4`. This file described v2.
4. **A phase can be "shipped" and still leave its own trigger unfired.** Phase 1
   says "per-source once 1.5 lands". 1.5 landed in 1.0.6. Nothing acted on it.

## High-level strategy

> Model every edit as portable Dart in `lib/core/`, sync it live to the native
> preview through the existing bridge, and bake it into the export composition.
> Only the render/export path differs per platform.

This held up. Zoom, cursor, camera and background already worked this way, and
colour, clips, captions and voice cleanup all shipped through the same three-part
loop:

1. **Model it in portable Dart** (`lib/core/timeline/…`) — a track/effect plus a
   command on an undo stack.
2. **Sync to live preview** via a `previewSet*` method on the bridge; native
   updates `InlinePreviewView` (macOS) / `preview_compositor` (Windows).
3. **Bake into export** by adding a pass to `CompositionBuilder.swift` (macOS) /
   the Media Foundation encoder + `preview_compositor.cpp` (Windows).

Because the editing model is portable Dart, macOS and Windows share it; only the
render/export differs. The Dart bridge surface is the source of truth, kept in
three-way sync (Dart / Swift / Windows C++).

**The "Windows stub day-one" contract also held.** All five editing bridge
methods have real Windows handlers today, not stubs:

| Method | Windows |
|---|---|
| `previewSetColorGrade` | `Bridge/Routers/preview_router.cpp` (D2D colour chain) |
| `previewSetClips` | `Bridge/Routers/clip_args.h` |
| `previewSetCaptions` | `Bridge/Routers/preview_router.cpp` |
| `previewSetVoiceCleanup` | `Bridge/Routers/preview_router.cpp` (real engine) |
| `previewSetCanvas` | `Core/canvas_composition.h` |

## The four features driving this work

A user asked for these so they could drop a paid editor (CapCut):

1. **Auto-subtitles + translate** — transcription **shipped** (macOS, Apple
   silicon, on-device, editable track, sidecar + burn-in). **Translate unbuilt.**
   **Windows ASR unbuilt** — `misc_router.cpp:171` returns "There is no speech
   model on Windows."
2. **Split & cut** — **shipped**, including reorder.
3. **Audio** — **voice cleanup shipped** on both platforms. **Volume boost /
   normalize half-done** (model yes, UI no).
4. **Colour improvement** — **shipped**, one-tap auto plus manual grade.

## Locked decisions

Marked with what the code did with each.

| Area | Decision | Status |
|---|---|---|
| **Subtitle ASR engine** | WhisperKit on macOS, whisper.cpp on Windows — both on-device, MIT, free. | **macOS half honoured.** Windows half never started. |
| **Whisper model** | User-selectable quality, default **Auto**. | Shipped as `caption_model_info.dart`, not the planned general picker. |
| **Whisper translation caveat** | `large-v3-turbo` returns the original language even with `--task translate` — **it cannot translate**. English translation requires a **medium or large** model. | **Still governs.** Untested in practice because translation was never built. |
| **Translation (v1)** | Local transcription + same-language captions + Whisper's **English-only** translation, on a medium/large model. | **Unbuilt.** `Caption.translatedText` exists on the model and round-trips; nothing writes it. |
| **Translation (deferred)** | Apple Translation framework (macOS 15+, after a prototype) or M2M-100 (Windows / macOS 14, MIT). NLLB-200 rejected (CC-BY-NC). Cloud not default. | Unchanged. No prototype run. |
| **Audio source separation** | Keep mic and system separate inside the bundle until export. Never denoise a pre-mixed track. | **Shipped — additively.** See the caveat under Phase 1.5. |
| **Audio format** | One internal format — 48 kHz float32 — converted at the edges. | **Shipped.** `AACEncoderSettings.defaultSampleRate = 48_000`; Windows accepts non-48 kHz since 1.1.0. |
| **Voice cleanup** | Pluggable `AudioEnhancementPipeline`. v1 = RNNoise. Future High Quality = DeepFilterNet. The UI never names engines. | **Shipped both platforms.** UI exposes Off / Light / Balanced. High Quality **deliberately not offered** — DeepFilterNet is not vendored, so the level would be a relabelled Balanced. The `highQuality` wire value still parses. |
| **Subtitle export** | Default = video + `.srt` + `.vtt` sidecars. Burn-in opt-in. | **Shipped.** Per-recording destination added in 1.2.0 (`CaptionTrack.destination`, null = follow app preference). |
| **Local models** | A first-class `LocalModelManager` — download-on-first-use, hash verify, version, disk usage, delete, offline state, per-model license note. Built early, not as an afterthought. | **Not built as specified.** Only the caption-specific path exists. Settings › Storage (1.1.0) shows and deletes the speech model, which is the user-visible slice of it. |
| **Export quality** | Audio presets — Standard 128 / High 192 / Best 256 kbps. | **Unbuilt.** |
| **Build order** | Foundation first; then features easiest-first. | **Not what happened.** See "What the plan got wrong". |
| **Pricing / gating** | No per-feature Pro gates. Trial = 14 days OR 3 exports. The app-level gate covers all local editing. | **Held.** No per-feature gating code was ever written. `LicenseController.canExport` gates on `trialExportsRemaining > 0`. |

**The pricing decision paid off exactly as predicted:** five feature phases
shipped with *zero* per-feature gating code.

## Architecture context — where editing plugs in

Current paths, re-verified 2026-09-30:

- **macOS audio gain/mix and render** live in the export composition path:
  `macos/Runner/Capture/Export/CompositionBuilder.swift` and
  `LetterboxExporter.swift`. `macos/Runner/Capture/Audio/` now holds the real
  pipeline (`AudioEnhancementPipeline.swift`, `RNNoiseEngine.swift`,
  `SourceAudioRecorder.swift`, `AACEncoderSettings.swift`) alongside the level
  estimators.
- **Windows audio** — `windows/runner/Audio/audio_mixer.cpp`, with
  `Audio/VoiceCleanup/rnnoise_denoiser.{h,cpp}` and
  `Capture/Export/mic_cleanup.{h,cpp}`. Export =
  `windows/runner/Encoding/mf_sink_writer_encoder.cpp` +
  `windows/runner/preview/preview_compositor.cpp`.
- **Bridge command names are constants.** `NativeMethod` holds **115** of
  them, one per Flutter→native method, and `native_method_names_test.dart`
  fails the build if any `invokeMethod` call in `lib/` names a method with a
  bare string. Before PR-0d (2026-10-05) only 7 were constants and **143 call
  sites across 10 files** passed literals.
  
  This number has now been wrong three times, each time because a regex was
  trusted over a count: "37 in `native_bridge.dart`" came from a pattern that
  read one file and only single-line calls; "120 across 9 files" came from one
  whose generic matcher could not cross a `>`, so every
  `invokeMethod<Map<dynamic, dynamic>>` was invisible. The figure here was
  derived by resolving every call site to the string it actually sends and
  counting, on both sides of the change.
- **Durable editor state is `post/state.json`** via
  `lib/core/timeline/post_state_store.dart`, at **schema v4**. It subsumed
  `clips_state.json`, `captions_state.json` and `editor_state.json`; the bundle
  manifest has pointed at it since the bundle format was introduced.

The seams as they now stand:

- **Editing model / undo:** four `EditSession`s —
  `lib/core/clips/clip_editor_controller.dart:40`,
  `lib/core/zoom/zoom_editor_controller.dart:458`, and two inside
  `lib/app/home/post_processing/post_processing_controller.dart` (`_colorSession`
  at :313, `_captionsSession` at :321). Each has its own undo/redo.
- **Live preview:** `macos/Runner/Preview/InlinePreviewView.swift` (60 Hz CALayer
  tree); `windows/runner/preview/preview_compositor.cpp`.
- **Export bake:** `CompositionBuilder.swift`
  (`AVMutableVideoComposition` + `AVVideoCompositionCoreAnimationTool`) /
  the Windows MF encoder.
- **Durable artifact:** the `.clingfyproj` bundle.

## A. The foundation (Phase 0) — what was actually built

**Status: built, in a different shape.** The goal was a unified, transactional,
globally-undoable edit model in portable Dart without touching `ZoomSegment` or
any passing zoom test. The second half of that goal was met completely. The
"unified/global" half was not.

### The package as it exists

```
lib/core/timeline/
  timeline_timebase.dart              # PR-0a — shipped 2026-06-21 (#177)
  edit_command.dart                   # PR-0b
  edit_session.dart                   # PR-0b — undo/redo/beginBatch/endBatch all present
  clip_operations.dart                # net-new, not in the plan
  clip_timeline.dart                  # net-new, not in the plan
  zoom_segment_timeline_mapper.dart   # net-new, not in the plan
  post_state_store.dart               # PR-0c — absorbed the planned state_migrator.dart
  commands/
    set_captions_command.dart
    set_clips_command.dart
    set_color_grade_command.dart
  model/
    timeline.dart                     # kTimelineSchemaVersion = 4
    edit_track.dart                   # ALL track types in one file
    color_grade.dart
    canvas_state.dart                 # net-new, not in the plan
  codec/
    timeline_codec.dart               # PR-0c
```

Deviations from the planned layout, all deliberate and all harmless:

- **`edit_track.dart` holds every track type.** The plan wanted `zoom_track.dart`,
  `clip_track.dart`, `caption_track.dart` and `audio_track.dart` as separate
  files. They are sealed subclasses in one file instead, which is how Dart
  sealed hierarchies want to be written — the `sealed` keyword requires all
  subtypes in the same library.
- **`state_migrator.dart` folded into `post_state_store.dart`.** The migration is
  a fallback branch in `load()`, not a standalone class: when `post/state.json`
  is absent it composes a timeline from the legacy files. Same contract, fewer
  moving parts.
- **Three files the plan never imagined** (`clip_operations`, `clip_timeline`,
  `zoom_segment_timeline_mapper`) plus `model/canvas_state.dart`. Clips needed
  more machinery than "a track plus commands".

### PR ledger — the real one

| PR | Title | Status |
|---|---|---|
| **0a** | `TimelineTimebase` extract | **Done** (#177, 2026-06-21). `ZoomEditorController` delegates at `:225`/`:233`; `frameMs` and `minDurationMs` re-export from it. |
| **0b** | `EditCommand` + `EditSession` | **Done, but instantiated four times.** `undo()`, `redo()`, `beginBatch()`, `endBatch()` all exist and work — per domain. |
| **0c** | `Timeline` tree + `TimelineCodec` + migrator | **Done**, migrator folded into `post_state_store.dart`. Schema now v4. |
| **0d** | Promote inline bridge strings → constants | **Done 2026-10-05** in two passes. 108 names promoted across **143 call sites in 10 files**, verified by resolving every call site to the string it sends and proving the multiset identical to the pre-PR-0d codebase. The first pass (#589) missed 16 literals and shipped a ratchet that could not see them: its generic matcher used `<[^>]*>`, which cannot cross a `>`, so every nested generic escaped — and its constant parser required the value on the same line, hiding 15 wrapped declarations from all four assertions. Both fixed in the follow-up. A ratchet test now fails the build on any new literal, which is the part that matters — four `previewSet*` literals had been added *after* `NativeMethod` already existed, one per feature phase. |

### `post/state.json` — schema v4, not v2

The shape below is the **planned v2** and is retained only as a record of intent.
For the live shape read `lib/core/timeline/model/timeline.dart` and
`lib/core/timeline/model/edit_track.dart` — they are the contract. Two v4
additions worth naming because they are load-bearing:

- **`CaptionTrack.destination`** (`SubtitleMode?`, 1.2.0). Null means "follow the
  app preference"; it is seeded at generate time, not only on override, because
  the user who reports the bug never touches the setting on recording A.
- **`Caption.toMap` no longer writes `words`** (1.2.0). `fromMap` still reads
  them, so old projects open unchanged. This is what made projects much smaller
  and caption correction much faster.

```jsonc
// HISTORICAL — the v2 shape this document originally specified.
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

**The cutover discipline held and is still the rule:** `TimelineCodec` is the
single read/write path; on a crash mid-migration prefer the legacy files; an
unknown `schemaVersion` or track `kind` degrades to defaults or
dropped-with-a-log, never a crash. Old projects still open.

### The two locked bridge contracts

Both held.

1. **Single pooled caption layer.** Captions render as one keyframed
   `CATextLayer` (macOS) / one DirectWrite pass (Windows), swapped per visible
   cue. The `AVVideoCompositionCoreAnimationTool` ~100-layer cliff was never hit.
2. **Windows stub day-one.** No editing feature silently diverged per-feature.
   Every `previewSet*` above has a Windows handler, and several went past stub to
   full parity.

### A.7 Local model manager — still unbuilt

The plan called for `lib/core/models/local_model_manifest.dart` and
`lib/core/models/model_download_manager.dart`. Neither exists. What shipped is
caption-specific: `caption_model_info.dart`, plus the Settings › Storage screen
(1.1.0) that reports and deletes the speech model.

**The gap is mostly unpaid because only one model shipped.** It becomes real the
moment a second arrives — DeepFilterNet for High Quality cleanup, or M2M-100 for
translation. Both of those are blocked on exactly this, so build it with whichever
comes first rather than as a standalone task.

## B. Phased roadmap — outcome per phase

The original order was (1) → (1.5) → (2) → (3) → (3.5) → (4) → (5). The delivered
order was (2, 3) → (1.5, 4) → (3.5, 5), with (1) still open.

The per-phase bridge checklist stands unchanged, and is the reason Windows never
diverged: ① Dart constant ② Swift constant ③ Windows constant ④ `NativeBridge`
method/registry ⑤ Swift handler ⑥ Windows handler/stub ⑦ keep the "sync with
Swift" comment honest ⑧ tests both sides.

### Phase 1 — volume / normalize — HALF DONE

**What exists:** `AudioTrackSource` (`edit_track.dart:531`) carries `gainDb` and
`normalize` per source, round-trips through the codec, and `AudioTrack` carries
`masterGainDb` and `limiter`.

**What does not:** the UI sends one flat value.
`post_processing_controller.dart:1577` pushes `gainDb: _audioGainDb` through
`setAudioMix`, aimed at the mic. `normalize` has no UI at all.

`_audioGainDb` dates to the **initial public release** (2026-03-16) — it predates
this entire initiative. The per-source model shape arrived beside it in PR-0c
(#179, 2026-06-21) and the two were never joined.

**Correction (2026-09-30, same day as the rewrite).** An earlier revision of this
section said Phase 1 was "UI plus routing through an `EditSession`, not a schema
change" and called it the smallest item on the list. A scope pass against the
native code refuted that. Recorded here rather than quietly edited, because
under-sizing an item is the same failure this rewrite exists to fix.

Four things make it bigger than a UI change:

1. **System gain is pinned at unity by design, on both platforms.**
   `windows/runner/Capture/Export/export_audio.h:104` documents the contract as
   `system = {1, master}`. `LetterboxExporter.resolveSeparatedAudioControls`
   (`:3926-3968`) and `ResolveSeparatedAudioStages` (`export_audio.h:108-112`)
   each take **one** `gainDb` and aim it at the mic. Master volume is the only
   thing that touches system audio, and it touches every track equally, so it is
   not a system control.
2. **Two Windows tests encode "system never gets gain" as intended behavior** —
   `GainBoostsTheMicOnly` and `NormalizeScalingDownRidesTheVolume`
   (`export_audio_test.cpp:237` and `:257`). They must be rewritten, not extended.
3. **System gain must be BAKED, never tapped.** `LetterboxExporter.swift:234-242`
   and `:3327-3331`: the manual export path reads through
   `AVAssetReaderAudioMixOutput`, which applies a per-track tap to the **mixed**
   stream, so a mic-only boost multiplied the system audio too and the tap's
   ±1.0 clamp squared the mix off at full scale. That is the "distorted system
   audio when the mic is on" bug. `MicEchoCanceller.bakeGain` is already generic
   (decode → multiply → clip → write CAF) and only *named* for the mic, so a
   `gainBakedSystemURL` sibling is the shape.
4. **There is no audio `EditSession`, and audio is app-scoped.** `EditDomain.audio`
   exists (`edit_command.dart:4`) but only `edit_session_test.dart` references it;
   `commands/` holds captions, clips and colour and no audio command; and
   `AudioTrack` is constructed **nowhere** in `lib/` — the only construction in the
   repo is `test/core/timeline/timeline_codec_test.dart:47`. Today's audio state
   lives in app-wide SharedPreferences, re-seeded onto every project at
   `post_processing_controller.dart:1883-1885`. Phase 1 therefore changes the
   **scope** of audio settings from app-wide to per-recording, which is a
   user-visible behaviour change, not a refactor.

**The natural split, since the halves have different risk:**

- **Phase 1a — scope and plumbing, Dart only.** Construct a real `AudioTrack` in
  `PostStateStore`, add `SetAudioCommand` and an audio-owning `EditSession`, move
  gain/volume/cleanup from app-wide prefs to per-project `post/state.json`. No
  native change, no new bridge arg. Ships the undo/redo and per-project scoping
  the roadmap always wanted. Watch for two traps: `AudioTrack` and
  `AudioTrackSource` define no `operator==`/`hashCode` (unlike `VoiceCleanup`), so
  the `if (value == _current) return;` dedupe guard degrades to identity and never
  dedupes; and `_audioVolumePercent` has **no corresponding field on `AudioTrack`**
  at all.
- **Phase 1b — system gain and per-source normalize, native both platforms.** Add
  `micGainDb`/`systemGainDb` to `updateAudioPreview` and `exportVideo` (both are
  additive: every audio arg is read with a default on both sides, so old payloads
  still parse), bake system gain on export, extend both resolvers, rewrite the two
  Windows tests. Needs a Windows machine for its half.

Two facts worth carrying into 1b. **Normalize is peak, not LUFS**, despite
`targetLoudnessDbfs` — it computes `targetLinear / micPeakLinear`
(`LetterboxExporter.swift:3941-3948`). And **normalize is export-only**: preview
hardcodes `autoNormalizeOnExport: false` at `InlinePreviewView.swift:729`, so the
editor never previews it. There is **no limiter anywhere** despite
`AudioTrack.limiter` — the only ceilings are hard clips.

**This is the oldest open item in the document.** The plan's own trigger —
"master gain initially; per-source once 1.5 lands" — fired in 1.0.6, two months
ago, and nothing acted on it. The model is already the right shape, so the work
is UI plus routing through an `EditSession`, not a schema change.

### Phase 1.5 — audio source separation — SHIPPED (1.0.6), ADDITIVELY

`SourceAudioRecorder.swift` writes `capture/mic` and `capture/system` separately;
the export chain is `raw mic → cleanup → normalize/boost/limiter → mix with system
→ final AAC`; legacy recordings fall back to `mixedFallbackPath`.

**The deviation that matters:** separation landed *additively*. `screen.mov` still
carries the muxed audio track — `CaptureBackendScreenCaptureKit.swift` states
"embedded audio is untouched". Nothing was removed, so nothing broke.

This is why **#217 (preview/export audio divergence) is not actionable**. Its
premise is that preview has no separated sources to mix; in fact preview applies
a gain tap to the still-present muxed stream, which is the exact defect export
was changed to avoid (distorted system audio when the mic is on,
`LetterboxExporter.swift:3328`). The real trigger for #217 is "the recorder stops
embedding audio in `screen.mov`", which has not happened and is not scheduled.

### Phase 2 — colour — SHIPPED (1.0.5), refined through 1.1.0

`lib/core/color/auto_grade_heuristic.dart` (portable one-tap),
`model/color_grade.dart`, `commands/set_color_grade_command.dart`,
`previewSetColorGrade` on both platforms, Windows via the D2D colour chain in
`Graphics/color_grade_effect` + `preview_compositor`.

Three follow-ups landed after the initial ship: colour accuracy capture-to-export
and preview/export transfer-function match (1.0.7), grade undo/redo (1.0.7), and
a fix for Clingfy deleting its own colour-corrected export when final validation
compared the graded file against ungraded expectations (1.1.0).

**Open:** Windows and macOS do not agree numerically. See §D.

### Phase 3 — split & cut — SHIPPED (1.0.5), past scope

Split at playhead, trim, enable/disable, delete — **and clip reorder**, which the
plan explicitly deferred ("defers true multi-clip rearrange"). macOS builds an
`AVMutableComposition` with one `insertTimeRange` per enabled clip, no new render
pass, exactly as designed. `clip_operations.dart` and `clip_timeline.dart` are the
machinery the plan under-budgeted for.

### Phase 3.5 — audio format normalization — SHIPPED (1.1.0)

48 kHz is the internal rate (`AACEncoderSettings.defaultSampleRate = 48_000`, with
the full supported-rate ladder at `:31`). The user-visible half shipped on
Windows in 1.1.0: "audio devices that are not running at 48 kHz now work — a
44.1 kHz USB interface, or anything you have changed by hand". The
"drop unsupported formats with a warning" behaviour is gone.

### Phase 4 — voice cleanup — SHIPPED BOTH PLATFORMS (1.0.6)

macOS: RNNoise v0.2 vendored at `macos/Runner/Capture/Audio/RNNoise/`, wrapped by
`RNNoiseEngine.swift` behind the engine-agnostic `AudioEnhancementPipeline.swift`,
cached per project by `EnhancedMicCache`, spliced into the export mic chain
between echo cancellation and the normalize/gain stage.

Windows: **complete, not blocked.** An earlier revision of this file said the port
was stuck because both Windows CMake projects declared `LANGUAGES CXX` only.
That was fixed — `windows/runner/CMakeLists.txt:6` now calls `enable_language(C)`
— and the engine shipped as `Audio/VoiceCleanup/rnnoise_denoiser.{h,cpp}` +
`Capture/Export/mic_cleanup.{h,cpp}`, with export, live WYSIWYG preview and
Light/Balanced strength matching macOS, covered by `rnnoise_denoiser_test.cpp`
and `mic_cleanup_test.cpp`. The plan's proposed insertion point (`audio_mixer.cpp`,
capture-time) was correctly rejected: a capture-time hook cannot honour a post-hoc
Off/Light/Balanced change. It went in at the export/preview mic pump instead,
mirroring the macOS ordering.

**Still open:** the High Quality tier. The UI exposes **Off / Light / Balanced**
only, because High Quality was to mean DeepFilterNet, which is not vendored —
offering it would have been a relabelled Balanced. The `highQuality` wire value
still parses and runs RNNoise at full strength, so a project written by a future
build opens correctly. `AudioEnhancementPipeline.swift:22` holds the reservation.

### Phase 5 — subtitles — TRANSCRIPTION SHIPPED (1.1.0), TRANSLATE UNBUILT

Shipped in 1.1.0: on-device transcription (nothing uploaded), an editable caption
track, `.srt`/`.vtt` sidecars, opt-in burn-in, undo/redo for caption edits, a
speech-model picker, Settings › Storage model management, and an over-long-cue
warning.

Refined in 1.2.0: `words` dropped from `Caption.toMap` (smaller projects, much
faster correction), per-recording subtitle destination, spoken-language selection
with automatic detection, sidecars no longer overwriting an existing `.srt`/`.vtt`
the user owns, and a font fallback chain so non-Latin text renders everywhere.
1.2.0 also made Intel Macs state *why* subtitles are unavailable rather than
failing silently.

**Not built:** translation (see §C — the design still stands, nothing implemented)
and Windows ASR (`misc_router.cpp:171` returns "There is no speech model on
Windows"). Availability is macOS + Apple silicon only.

## C. Subtitles + translate deep-dive

The transcription half of this section shipped. **The translation half is intact
and unimplemented — read it as the spec for the work, not a description of the
app.**

### Pipeline

```
mic source (from .clingfyproj capture/, post-cleanup)
  -> ASR: WhisperKit (mac) [SHIPPED] / whisper.cpp (win) [UNBUILT]
  -> timestamped Caption[] (segment + word timings)          [SHIPPED]
  -> [optional] translate to English (medium/large only)     [UNBUILT]
  -> editable CaptionTrack on the timeline (undoable)        [SHIPPED]
  -> render:  .srt/.vtt sidecar (default) AND/OR burn-in     [SHIPPED]
```

### ASR

- **macOS:** WhisperKit (Argmax, MIT), SPM, min macOS 14, Core ML on ANE/GPU.
  **Shipped. Apple silicon only** — Intel Macs are told why.
- **Windows:** whisper.cpp (MIT), Vulkan default GPU backend (cross-vendor) + CPU
  fallback, ggml `.bin` models. **Unbuilt.** This is the single largest remaining
  parity gap in the product.
- **Model selection:** shipped as `caption_model_info.dart`, backed by the
  Settings › Storage screen rather than the general `LocalModelManager` of §A.7.
- Batch on a finished recording, so real-time factor is not a blocker. Held.

### Translation (with the turbo caveat) — UNBUILT

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
returns the source language. **Nothing enforces this rule today** because nothing
calls translate — but note that the shipped model picker can already put a user on
turbo, so the rule must land *with* translation, not after it.

Arbitrary target language stays deferred:

| Tier | Engine | Notes |
|---|---|---|
| macOS 15+ | **Apple Translation framework** | on-device, free, zero app weight — *prototype the headless/batch flow before committing* (it is SwiftUI-coupled; this is the largest unknown). Still not prototyped. |
| Windows / macOS 14 | **M2M-100 418M** (MIT, ~1.5 GB, any→any) | optional download — needs `LocalModelManager` (§A.7) first. |
| Rejected | NLLB-200 | CC-BY-NC — disqualified for a paid product. |
| Future paid | DeepL/Google cloud | not default; possible Clingfy.ai studio feature. |

### Data shape — shipped, with two v4 amendments

```dart
class CaptionWord { final String text; final int startMs, endMs; }
class Caption {
  final String id; final int startMs, endMs; final String text;
  final List<CaptionWord> words;   // read on load; NO LONGER WRITTEN (1.2.0)
  final String? translatedText;    // persisted and round-trips; nothing writes it
}
class CaptionTrack extends EditTrack {
  final String language; final String? sourceLanguage;
  final CaptionStyle style; final List<Caption> captions;
  final SubtitleMode? destination;  // v4, 1.2.0 — null = follow app preference
}
```

`Caption.translatedText` being already persisted is the reason translation is a
feature-sized task and not a schema migration.

### Render — shipped

- **Sidecar `.srt`/`.vtt` (default):** portable Dart serializer. Shipped as
  `lib/core/captions/subtitle_serializer.dart` (the plan called it
  `srt_vtt_serializer.dart`).
- **Burn-in (opt-in):** one `CATextLayer` driven by a `CAKeyframeAnimation`
  (macOS) / DirectWrite per active cue (Windows). One layer regardless of caption
  count. Held. Note the burn-in seat: the obvious `CALayer` overlay gets the
  user's colour grade applied to it, so burn-in uses the writer-loop CoreImage
  seat after `LetterboxExporter:2544` instead.
- **Both:** optional, never automatic. Held.

### Bridge additions

- `generateCaptions(projectPath, modelTier, sourceLang?) -> captionTrack` —
  **shipped** (`native_bridge.dart:978`), async, progress via `workflow/events`.
- `translateCaptions(captions, targetLang) -> captions` — **does not exist.**
- `previewSetCaptions(captions, style, sessionId)` — **shipped**, both platforms.
- `exportVideo` args gain `captions` + `subtitleMode` — **shipped**, with
  per-recording destination on top.

## Export quality — AUDIO SHIPPED 2026-10-06

The ladder shipped, with different numbers than this section specified, because
the premise was wrong. It said 128 kbps was "today's default, and today's only".
It was not: `AACEncoderSettings.bitRate` yields 96 kbps per channel at 48 kHz,
so **macOS has always exported 192 kbps**. Only Windows was at 128
(`AudioEncoderConfig.avg_bitrate_bps`), which nobody had documented — the same
project exported different audio quality per platform.

Shipping 128/192/256 with Standard as the default would therefore have
**downgraded every existing macOS export** while looking like a new feature.

| Preset | macOS | Windows |
|---|---|---|
| Standard | AAC 192 kbps stereo (unchanged from before the control existed) | 192 kbps (raised from 128 — the parity fix) |
| High | AAC 256 kbps stereo | 192 kbps (clamped) |
| Best | AAC 320 kbps stereo | 192 kbps (clamped) |

**The tier is a ceiling, not a rate.** AAC-LC refuses a bitrate its sample rate
cannot carry, and refuses it late — `canAdd` and `startWriting()` both succeed
and the encoder fails on the first appended buffer as `-11861`. A recording from
a 16 kHz Bluetooth headset mic keeps the conservative rate whichever tier is
chosen, and `exportBitRate` only raises the ceiling at 48 kHz, the one rate
whose ceiling was measured.

**The ceilings are measured, not looked up.** `AACBitRateProbeTests` drives the
real `AVAssetWriter`: at 48 kHz stereo everything up to 320 kbps is accepted and
384 kbps is refused. That test is the evidence for the constants, and it asserts
each tier individually so a regression names which one broke.

**The control is macOS-only**, and that is the honest part. The Media Foundation
AAC encoder's accepted (rate, channels, bitrate) matrix has not been measured on
Windows hardware, and it refuses out-of-matrix values late as an opaque HRESULT
from `AddStream`. So `ResolveAudioBitrateBps` clamps every tier to 192 kbps
there, and offering three names for one outcome would be worse than offering
one — the same call Voice Cleanup made about its own unbuilt `highQuality` tier.
Raising it is a one-line change in `ResolveAudioBitrateBps` with a test already
pinning each tier, once somebody probes the MFT.

Two things fixed on the way past: `AudioEncoderConfig::Validate()` had no
bitrate range check at all (it only rejected zero) while the MFT refuses
out-of-range values late, and the export dialog had no height constraint, so
adding one control overflowed it by 10 px — it now scrolls, which also protects
the controls that were already there on a short screen.

Video keeps the existing bitrate presets, with one rule: **when effects force a
re-encode of text/UI/code-heavy screen video, default one step higher than the
camera-footage bitrate** — text and sharp UI edges show compression artifacts
faster than camera footage.

## D. Cross-cutting risks — re-scored

- **~100-CALayer / Core Animation render ceiling — did not bite.** The pooled
  caption layer, single CIFilter colour pass and sidecar-default subtitles all
  shipped, and no heavy stack has degraded. The Metal/`CIImage` replacement for
  `CoreAnimationTool` stays a future spike, not a blocker.
- **Windows zoom-edit gap (Phase 8.3) — closed.** Manual zoom segments (add,
  move, trim, delete, undo/redo, persisted) shipped on Windows in 1.1.0.
- **Windows audio rigidity — closed** by Phase 3.5 in 1.1.0.
- **Pre-mixed legacy audio — still live, and now permanent.** Because Phase 1.5
  landed additively, every recording still has a muxed track, so the
  `mixedFallbackPath` path is not a legacy-only concern. Any change that removes
  the embedded audio from `screen.mov` must land together with a preview fix, or
  it will break preview audio for every project (this is #217).
- **Windows ↔ macOS colour divergence — NEW, open.** The Windows D2D colour chain
  diverges from Core Image at strong grades: worst `|diff|` **2.77** against a
  **0.002** tolerance. `ColorGradeGoldenTest` is excluded in `ci.yml:703-712`
  pending a real fix to the D2D matrix chain. The golden fixtures (dumped by the
  macOS `ColorGradeGoldenDumpTests`) are committed, so the fix is verifiable the
  day someone takes it.
- **Windows licensing — still untested.** Editing stays free/feature-flagged on
  Windows until a licensing smoke pass on `lib/commercial/licensing/` passes. The
  Windows build also ships unsigned, so it remains beta and unreleased.
- **Undo is per-domain and will stay that way without a decision.** Four
  `EditSession`s means undoing a colour change cannot undo a clip split. No user
  has reported it. Unifying them now would touch four controllers to fix a
  complaint nobody has made — listed here as a known shape, not a queued task.

## E. What's actually left

In rough order of user-visible value per unit of risk.

1. **Phase 1a — audio scope and plumbing (Dart only).** Construct a real
   `AudioTrack`, add the audio `EditSession` + command, move audio state from
   app-wide prefs to per-project `post/state.json`. Brings audio in line with
   clips/zoom/colour/captions and makes it undoable. **Phase 1b** (system gain +
   per-source normalize) is native work on both platforms and is listed
   separately below — see the Phase 1 section for why the two split.
2. **Windows ↔ macOS colour parity.** Fixtures are committed and the test is
   written — it is excluded, not absent. Fixing the D2D matrix chain and deleting
   the `-E` filter in `ci.yml` is a bounded, verifiable task. Needs a Windows
   machine.
3. ~~**Finish PR-0d.**~~ **Done 2026-10-05.** 108 names, 143 call sites, 10
   files, with a ratchet test so the debt cannot regrow. The sweep also
   confirmed something worth keeping: **every** Dart method name resolves to a
   handler on at least one platform, so nothing in the bridge is dead.
4. **Subtitle translation.** `Caption.translatedText` already persists and
   round-trips; `generateCaptions` already proves the async + progress bridge
   shape. Needs `translateCaptions` on the bridge, the turbo-caveat enforcement
   from §C, and a translation-capable model download — which drags in item 6.
5. **Windows ASR.** The largest parity gap in the product: subtitles are the
   headline feature of 1.1.0 and Windows returns "There is no speech model on
   Windows." whisper.cpp + Vulkan per §C. Biggest item on this list.
6. **`LocalModelManager` as a real subsystem (§A.7).** Do not build it
   standalone. Build it with whichever of DeepFilterNet, M2M-100 or the
   whisper.cpp models arrives first, since each of those is blocked on it and it
   has no user-visible value alone.
7. **Export audio presets.** Small, self-contained, no dependencies.
8. **High Quality voice cleanup (DeepFilterNet).** The pipeline is already
   engine-agnostic and the wire value already parses, so this is a vendoring +
   model-download task. Blocked on item 6.

**Not on this list, deliberately:** unifying the four `EditSession`s (see §D), and
#217 preview/export audio divergence (see Phase 1.5 — its premise does not hold
on current code and the issue needs rewriting before it needs fixing).

## The recipe for adding a feature

Unchanged, and it worked for five phases running:

1. Add the model + command in `lib/core/timeline/` (+ tests).
2. Route the UI through `EditSession.execute` (no eager setters).
3. Add the `previewSet*` bridge method across all three sides — **as a
   `NativeMethod` constant, not a literal**; ship the Windows handler or no-op
   stub the same day.
4. Implement the macOS render/export pass; implement the Windows pass.
5. Persist via `TimelineCodec` into `post/state.json`; bump
   `kTimelineSchemaVersion` only for a breaking change, and keep `fromMap`
   reading what older writers wrote.
6. No per-feature license gate — rely on the existing export-time gate.
7. Tests on both sides; keep the bridge-contract sync tests green.

**And one rule this rewrite exists because of:** when a phase ships, update the
status table in this file in the same PR. A plan that is only corrected once a
quarter is worse than no plan, because people believe it.
