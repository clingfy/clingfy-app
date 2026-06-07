# Windows Phase 8 — cursor sidecar + smart zoom: architecture & inventory

Status: **Phase 8.0 design — locked. No production capture/export code yet.**
Audience: whoever implements slices 8.1–8.4.
Companion: [../windows-port.md](../windows-port.md) (roadmap), and the
[Phase 7 capture architecture](windows-phase-7-capture-architecture.md) it builds on.

Phase 7 gave Windows window/area/display capture with the **cursor burned into the
video** (`IsCursorCaptureEnabled(true)`) — an explicit MVP shortcut. Phase 8 is the
"Clingfy behavior" switch: stop burning the OS cursor into the frame, record a
**cursor sidecar** (position + clicks + shape), render the cursor back at **export**
time (so size/visibility/highlight are editable), and use the cursor track to drive
**smart zoom**. This doc maps the macOS + Dart reference, the current Windows stack,
locks the architecture, and splits the work into PR-sized slices. It changes no code.

```txt
IsCursorCaptureEnabled(true)                 ← Phase 7 MVP (cursor in the pixels)
→ IsCursorCaptureEnabled(false)
  + cursor sidecar (position / click / shape)
  + export-rendered cursor (+ highlight, click animation)
  + cursor-driven smart zoom                 ← Phase 8 Clingfy behavior
```

---

## 1. macOS + Dart reference behavior (the parity contract)

There are **two** layers to mirror, and they are not the same shape — getting this
distinction right is the whole game:

### 1a. The macOS on-disk cursor sidecar (`CursorRecorder.swift`)

| Concern | macOS behavior | Anchor |
|---|---|---|
| File | `<recording>.cursor.json`, written once at **Stop** (whole object encoded) | `Capture/Cursor/CursorRecorder.swift:45` |
| Schema | `{ sprites:[{id,width,height,hotspotX,hotspotY,pixels(RGBA bytes)}], frames:[{t,x,y,spriteID}] }` | `CursorRecorder.swift` structs |
| Frame coords | `x,y` **normalized [0..1]** in capture-local space, **top-left** origin; `spriteID=-1` = cursor off-surface | `CursorRecorder.swift:251-258` |
| Sampling | **60 Hz** `DispatchSourceTimer` | `CursorRecorder.swift:379` |
| Timestamp | `t` = **seconds** since recording start, pause-aware (`accumulatedRecordedDuration`) via `ProcessInfo.systemUptime` | `CursorRecorder.swift:248-249` |
| Position | `CGEvent(source:nil).location` (screen px) → minus capture rect origin → normalized | `CursorRecorder.swift:251-258` |
| Clicks | **NOT captured in the sidecar.** (A live highlighter watches NSEvents, but nothing is baked in.) | — |
| Shape | the **actual cursor bitmap** is rasterized + stored as a deduped sprite (by `w,h,hash`); no cursor-type enum; hotspot in px | `CursorRecorder.swift:287-365` |

### 1b. The Dart cross-platform contract (what Windows must actually satisfy)

**Dart never opens `cursor.json`.** It talks to native over the method channel and
does the smart-zoom decision itself. This is the contract Windows must answer
(`lib/core/bridges/native_bridge.dart`, `lib/core/zoom/`):

- **`previewGetCursorSamples({sessionId,startMs,endMs,playheadMs})`** →
  `{ samples:[{tMs:int, x:double, y:double, visible:bool}], playheadSample?, width:double, height:double }`.
  **Note `x,y` are PIXELS** (not normalized), `width/height` are the source dims used
  to normalize. (`cursor_samples.dart:133-212`)
- **`getZoomSegments({projectPath})`** / **`getManualZoomSegments`** /
  **`saveManualZoomSegments({projectPath,segments})`** → auto + user-edited zoom
  segments. `ZoomSegment = {id, startMs, endMs, source:"auto"|"manual", baseId?, focusMode:"followCursor"|"fixedTarget", fixedTarget?:{dx,dy}}` (`app_models.dart:841-926`).
- **`previewSetZoomSegments`**, **`previewGetZoomCapabilities`** →
  `{cursorSamples,fixedTargetPreview,fixedTargetExport}`, **`previewGetSourceDimensions`**.
- **Cursor availability** is signaled by a **`CURSOR_FILE_MISSING`** player warning;
  Dart then force-disables `showCursor` (`post_processing_controller.dart:60-67`).
- **Export/preview args** carry `cursorSize` (0.5–3.0, default 1.5), `showCursor`
  (bool), `zoomFactor` (1.0–3.0, default 1.5), `zoomEffectEnabled` (bool), and
  `zoomSegments:[{startMs,endMs}]` (`post_processing_controller.dart` export map).

### 1c. The smart-zoom model (shared Dart + Swift; already partly on Windows)

- **Focus heuristic (Dart):** `chooseZoomFocusModeForRange()` filters cursor samples
  in `[startMs,endMs]`; if max pairwise spread `≤ kZoomCursorMotionThresholdPx (12px)`
  → `fixedTarget` (static cursor, anchored at the playhead/closest/center), else
  `followCursor`. (`lib/core/zoom/zoom_focus_heuristic.dart:8,33-79`)
- **Auto segment generation (Swift):** `ZoomTimelineBuilder` simulates the cursor at
  60 fps, runs `ZoomHysteresis` (zoom-in 0.2s, zoom-out 0.3s, min-on 0.30s), merges
  gaps `<120ms`, drops segments `<2 frames`. Emits `{startMs,endMs}` only; focus mode
  is assigned later by the Dart heuristic. (`macos/Runner/Capture/Zoom/*`)
- **Follow smoothing (Swift):** `ZoomFollowSmoother` exponential lerp,
  `alpha = 1-(1-strength)^(dt*refFPS)`, strength 0.15 (0.05–0.50), dt clamped
  [1/240,1/15]s, refFPS 60. Export keyframes are **linear**; smoothness comes from
  the per-frame smoother, not a bezier.
- **All of the above constants are already ported to Windows** in
  `windows/runner/preview/zoom_easing_constants.h` (verified by
  `zoom_easing_constants_test.cpp`). The *logic* that uses them is not.

**Takeaway:** Windows already has the zoom *numbers* and the Dart UI/heuristic. What
is missing is (a) a real cursor track, (b) the native query/segment endpoints that
are currently stubs, and (c) the export-time cursor + zoom rendering.

---

## 2. Windows current state after Phase 7

- **Cursor flip point — one site.** `wgc_display_capture_backend.cpp` StartWithItem:
  `session_.IsCursorCaptureEnabled(true)` in a best-effort try/catch, with a comment
  flagging it as the single greppable Phase 8 flip. Nothing else controls cursor
  visibility.
- **Capture coordinate spaces (all physical px; app is PerMonitorV2).**
  - *display*: full monitor; frame origin = monitor top-left; screen→frame =
    `GetCursorPos()` minus `rcMonitor.{left,top}`.
  - *window*: WGC `GraphicsCaptureItem.Size()` = **client content** (DWM frame
    excluded, unlike `GetWindowRect`); frame origin = content top-left; screen→frame =
    `GetCursorPos()` minus the content origin (`DWMWA_EXTENDED_FRAME_BOUNDS`).
  - *area*: `CaptureCropBox{x,y,w,h}` monitor-local even px; frame origin = crop
    top-left; screen→frame = `GetCursorPos()` minus `rcMonitor` minus crop `{x,y}`.
  - `EvenCaptureDimension`/`ResolveCropBox` are the shared even-size source of truth.
- **Target metadata the engine already holds at record time** (`recording_engine.cpp`,
  members `current_target_type_` / `current_window_id_` / `current_source_bounds_`;
  manifest `BuildScreenMetaJson` writes `targetType`, `windowId`, `sourceBounds`,
  `width`, `height`, `fps`). This is exactly what a cursor sampler needs to map
  screen→frame.
- **Threads + lifecycle.** Engine owns an encoder-drain thread and an audio-mixer
  thread; `Start/Stop/Pause/Resume` + the Phase 7.4 `HandleTargetLost`; a
  `RecordingClock` (already pause-aware); `PlatformThreadDispatcher` is a hidden
  message-only window on the platform thread (a real `GetMessage` loop exists there —
  relevant for `WH_MOUSE_LL`).
- **Export pipeline.** `export_pipeline.cpp` decodes with `IMFSourceReader` → Direct2D
  composites each frame into the fit/fill `dest_rect` (`export_geometry`) → re-encodes
  H.264. The per-frame `BeginDraw → Clear → [rounded layer] → DrawBitmap(source,
  dest_rect) → EndDraw` block is the clean insertion point for cursor draw + a zoom
  transform. **No zoom transform exists yet.**
- **Stubs.** `getZoomSegments` / `getManualZoomSegments` / cursor-sample / zoom-preview
  routes return empty (`HandleEmptyList`). `previewGetZoomCapabilities` should report
  what Windows actually supports as slices land.
- **Project layout.** Bundle at `%LOCALAPPDATA%\Clingfy\recordings\<id>.clingfyproj`
  with `capture/screen.mov` + `capture/screen.meta.json`; manifest already reserves
  `capture/cursor.json` + `capture/zoom.manual.json` slots (the sidecars sit beside
  the video).

---

## 3. Locked architecture decisions

**D1 — Cursor-burn-off is gated on a reliable sidecar; flip only in 8.1.** Keep
`IsCursorCaptureEnabled(true)` until 8.1 actually writes a cursor track. In 8.1 flip
the single site to `false`. If the sidecar fails to start (timer/hook unavailable),
**fall back to cursor-on** for that recording and skip writing the sidecar, so a
sampler failure degrades to Phase-7 behavior rather than a cursorless video. Emit
`CURSOR_FILE_MISSING` when no usable sidecar exists so Dart disables cursor render.

**D2 — Sidecar format: streaming `cursor.jsonl`, crash-robust, beside the video.**
Diverge from macOS's single-`cursor.json`-at-Stop. Write
`capture/cursor.jsonl` incrementally during recording, one JSON object per line:
- line 1 header: `{"type":"header","schemaVersion":1,"sampleRateHz":60,"targetType":"display|window|area","width":W,"height":H,"origin":{...},"recordingStartMonotonicNs":…}`
- sprite-define (emitted on first sight of a shape): `{"type":"sprite","id":N,"w":…,"h":…,"hotspotX":…,"hotspotY":…,"pixelsBase64":"…"}`
- sample: `{"type":"sample","tMs":…,"screenX":…,"screenY":…,"x":…,"y":…,"visible":true,"spriteId":N,"buttons":0}`

`x,y` are **capture-local physical px**, top-left origin, matching the encoded frame
(so `x,y` feed `previewGetCursorSamples` directly and `width/height` = encoded dims).
`screenX,screenY` are kept for debugging/re-mapping. Rationale for jsonl over a
single json: it survives a crash/target-loss mid-recording (Phase 7.4 keeps the
partial — the cursor track up to that point stays valid), and it appends without
rewriting. The reader tolerates a truncated final line.

**D3 — Position capture: poll `GetCursorPos` at 60 Hz on a dedicated sampler thread,
timestamped off `RecordingClock`.** Mirror macOS's 60 Hz. The sampler thread is owned
by the engine, started after `capture_backend_->Start*` and stopped in
`TeardownPipeline`, paused/resumed with the same gates as capture (no samples while
paused, matching the pause-aware clock so `tMs` excludes paused time). Map
screen→capture-local using the engine's already-resolved target (D1/§2): monitor
origin for display, monitor+crop for area, `DWMWA_EXTENDED_FRAME_BOUNDS` content
origin for window. Out-of-frame positions are still recorded with `visible:false`.

**D4 — Click capture: `WH_MOUSE_LL` low-level hook on its own message-loop thread.**
A `WH_MOUSE_LL` hook must live on a thread that pumps messages and its proc must
return fast (Windows silently drops a slow hook past `LowLevelHooksTimeout`). Run the
hook on a **dedicated thread with its own `GetMessage` loop** (do not block the
Flutter platform thread; do not do work in the proc beyond timestamp+enqueue).
Capture L/R/M button down/up with a `RecordingClock` timestamp; store as `buttons`
bitmask + edge events in the sample stream. **This goes beyond macOS** (which records
no clicks) and exists to drive click animation (8.4). Clicks are captured in 8.1
(schema-complete, so we never re-record) but only *rendered* in 8.4.

**D5 — Cursor shape: sample the real cursor bitmap into a deduped sprite table
(mirror macOS), with a bundled-arrow fallback.** At each sample, read the shape via
`GetCursorInfo` → `hCursor`; dedup by `HCURSOR` handle (cheap) and rasterize once via
`GetIconInfo` + `DrawIconEx`/`GetDIBits` into premultiplied BGRA, storing hotspot.
Emit a `sprite` line on first sight; samples reference `spriteId`. Capturing the
shape in 8.1 (while we already have the cursor) avoids a re-record later and gives
I-beam/hand/resize accuracy parity with macOS. Export (8.2) renders the sprite, and
falls back to a single bundled arrow asset when a sprite is missing/unreadable.

**D6 — Export cursor render: extend the existing Direct2D composite.** In
`export_pipeline.cpp`, after `DrawBitmap(source, dest_rect)` and before `EndDraw()`:
sample the sidecar at the frame's **source timestamp**, map capture-local px →
canvas px through the same `dest_rect` + `scale = dest_rect.width / source_w`, and
`DrawBitmap` the cursor sprite at `(pos - hotspot)*scale*cursorSize`. Honor the Dart
export args `showCursor` + `cursorSize` (0.5–3.0). Respect zoom: when a zoom transform
is active (D8), the cursor maps through the same transform so it stays glued to the
content. Click animation + highlight ring are layered in 8.4.

**D7 — Smart zoom reuses the Dart model + the ported constants; Windows fills the
native gaps.** Do **not** invent a Windows zoom model. Instead:
- Answer **`previewGetCursorSamples`** from `cursor.jsonl` (pixels + width/height) so
  the existing Dart focus heuristic works unchanged.
- Port **`ZoomTimelineBuilder` + `ZoomHysteresis`** to C++ (driven by the sidecar's
  shape-change/in-bounds signal) to answer **`getZoomSegments`** (auto segments);
  reuse `zoom_easing_constants.h` for every threshold so Windows and Swift agree by
  construction. Pure logic → unit-testable without GPU.
- Persist user edits in `capture/zoom.manual.json` for
  **`saveManualZoomSegments`/`getManualZoomSegments`**.
- Report honest **`previewGetZoomCapabilities`** as each piece lands.

**D8 — Zoom-in-export transform: scale the content mapping about a smoothed center.**
Extend `export_geometry`/`export_pipeline` so a frame inside a zoom segment maps the
source into `dest_rect` scaled by `zoomFactor` about a center: `followCursor` →
the cursor position fed through `ZoomFollowSmoother` (strength/dt/refFPS from the
constants); `fixedTarget` → the normalized `{dx,dy}`. Linear keyframe interpolation
between segment boundaries + per-frame exponential smoothing (matches macOS).
Clamp the center so the scaled content still fills the canvas (no exposed edge). The
cursor (D6) maps through the same transform.

**D9 — Timestamps: one `RecordingClock`, pause-aware, milliseconds.** Cursor sample
`tMs` and click `tMs` come from the same clock the engine pauses/resumes, so the
cursor track aligns to the video frame timestamps and excludes paused time (matches
macOS `accumulatedRecordedDuration`). Export samples the sidecar at the frame's
source-relative time.

**D10 — Manifest: additive `cursor` + `zoom` fields, schemaVersion stays 2.** Write
the sidecar relative paths (`capture/cursor.jsonl`, `capture/zoom.manual.json` when
present) and a `cursorEnabled` flag into `screen.meta.json`, mirroring the macOS
`CaptureFiles.cursorData`/`zoomManual` shape. Additive — the reader ignores unknown
keys, so no schema bump (same discipline as Phase 7's `targetType`/`sourceBounds`).

---

## 4. Deliberate divergences from macOS (call them out in PRs)

1. **Windows records clicks (D4); macOS does not.** Enables an export click
   animation macOS lacks. (Phase 8.4.)
2. **Streaming `cursor.jsonl` (D2) vs macOS's single `cursor.json`-at-Stop.** Crash-
   robust and aligned with Phase 7.4 keep-the-partial; the schema still carries the
   same sprite + position information.
3. **Capture-local pixels in the sidecar (D2) vs macOS normalized [0..1].** Windows
   stores px (with dims in the header) because the Dart `previewGetCursorSamples`
   contract is in pixels; normalization is trivial from the header dims.
4. **Coordinate mapping is PerMonitorV2 physical px** with an explicit window
   DWM-frame offset — no macOS bottom-left flip; Windows is top-left throughout.

---

## 5. Slice plan (PR-sized) + acceptance tests

Same gated rhythm as Phases 6–7: explore → implement → adversarial review → ship →
user smoke → next. GPU/IO-touching tests follow the existing `D3DDevice::Create()`
`GTEST_SKIP` / real-pipeline patterns; pure logic (coordinate mapping, jsonl
parse/serialize, zoom timeline/hysteresis) is unit-tested without a GPU.

### 8.1 — Cursor sidecar recording (`feature/windows-phase-8-1-cursor-sidecar`)
Flip `IsCursorCaptureEnabled(false)` (with cursor-on fallback, D1); 60 Hz
`GetCursorPos` sampler thread clocked off `RecordingClock` (D3, D9); per-target
screen→capture-local mapping helper (D3, pure + unit-tested); `WH_MOUSE_LL` click
hook on its own message-loop thread (D4); cursor-shape sprite capture + dedup (D5);
stream `capture/cursor.jsonl` (D2); manifest `cursorEnabled` + path (D10); answer
`previewGetCursorSamples` from the sidecar; emit `CURSOR_FILE_MISSING` when absent.
Acceptance:
- [ ] A recording produces `cursor.jsonl` with header + samples; cursor is NOT in the
      video pixels (flip worked); display/window/area each map positions correctly
      (pure mapping unit tests for monitor origin, crop offset, window DWM offset, DPI).
- [ ] `previewGetCursorSamples` returns pixel samples + dims matching the encoded video.
- [ ] Clicks are recorded (button edges with timestamps).
- [ ] Sampler/hook failure falls back to cursor-on + `CURSOR_FILE_MISSING` (no crash,
      no cursorless video).
- [ ] Pause excludes samples; a target-loss partial still has a valid jsonl.

### 8.2 — Cursor rendering in export (`feature/windows-phase-8-2-cursor-render`)
Direct2D cursor draw in the export composite (D6); honor `showCursor`/`cursorSize`;
sprite render with bundled-arrow fallback; coordinate map through `dest_rect`/scale.
Acceptance:
- [ ] Exported video shows the cursor at the right place/size; `showCursor=false`
      hides it; `cursorSize` scales it; hotspot is correct.
- [ ] Shape parity (I-beam/hand) when sprites exist; arrow fallback otherwise.
- [ ] Display/window/area exports all place the cursor correctly; no regression to the
      Phase 6 no-cursor export path.

### 8.3 — Smart zoom export (`feature/windows-phase-8-3-smart-zoom`)
Port `ZoomTimelineBuilder` + `ZoomHysteresis` (pure, reuse `zoom_easing_constants.h`)
for `getZoomSegments`; `zoom.manual.json` persistence for `save/getManualZoomSegments`;
`previewSetZoomSegments`; zoom transform in export with `ZoomFollowSmoother` +
fixed-target (D7, D8); cursor maps through the zoom transform.
Acceptance:
- [ ] Auto segments match the Swift builder on shared fixtures (gap-merge 120ms, min 2
      frames, hysteresis 0.2/0.3/0.30s) — pure unit tests vs the ported constants.
- [ ] `followCursor` zoom tracks the smoothed cursor; `fixedTarget` zooms the point;
      content always fills the canvas (no exposed edge); cursor stays glued.
- [ ] Manual segments round-trip; `previewGetZoomCapabilities` reports the truth.

### 8.4 — Live cursor highlight / click animation / polish (`feature/windows-phase-8-4-cursor-polish`)
Export click ripple/animation from the recorded click edges; optional cursor
highlight ring; smoothing/visibility polish; final Phase 8 closeout smoke.
Acceptance:
- [ ] A click produces a visible ripple/animation at the click point/time.
- [ ] Highlight (if enabled) renders without obscuring content; toggles honor settings.

---

## 6. Cross-cutting risks

- **Coordinate mapping** is the #1 correctness risk (window DWM-frame offset, area
  crop offset, non-100% DPI, negative-origin monitors) — gate it behind one tested
  pure helper, like Phase 7's `ResolveCropBox`.
- **`WH_MOUSE_LL` discipline** — must run on a message-pumping thread and return fast,
  or Windows silently removes the hook; never do work in the proc. Don't leak the
  hook/thread across Stop.
- **Sample/frame timestamp alignment** — cursor `tMs` must share the video clock
  (pause-aware) or the cursor drifts from the content in export.
- **Cursor-off must not regress capture** — flipping `IsCursorCaptureEnabled(false)`
  must leave display/window/area capture otherwise byte-identical; keep the cursor-on
  fallback.
- **Performance** — 60 Hz sampling + per-sample `GetCursorInfo` is light, but sprite
  rasterization must be deduped (by `HCURSOR`) so a cursor that never changes
  rasterizes once.
- **Export zoom edge clamp** — a zoom center near an edge must not expose the canvas
  background; clamp the scaled mapping.

## 7. Deferred / out of scope for Phase 8

- Camera overlay compositing/chroma → **Phase 9**.
- The three Phase 7.4 deferrals (area-region persistence across restart, yellow-border
  disable, non-captured-monitor selection clear) — independent of Phase 8.
- HEVC export, background image/preset work — unrelated export slices.

## 8. Key references

macOS: `Capture/Cursor/CursorRecorder.swift`, `Capture/Export/CompositionBuilder.swift`
(cursor render), `Capture/Zoom/{ZoomTimelineBuilder,ZoomHysteresis,ZoomFollowSmoother}.swift`,
`Capture/Export/ScreenZoomCursorIntermediatePipeline.swift`.
Dart: `lib/core/zoom/{cursor_samples,zoom_focus_heuristic,zoom_editor_controller}.dart`,
`lib/core/models/app_models.dart` (`ZoomSegment`), `lib/core/bridges/native_bridge.dart`,
`lib/app/home/post_processing/` (export args + cursor/zoom sections).
Windows: `windows/runner/Capture/wgc_display_capture_backend.cpp` (cursor flip + coord
spaces), `Capture/recording_engine.cpp` (target metadata + threads + clock),
`Capture/recording_project_writer.cpp` (manifest), `preview/zoom_easing_constants.h`
(already ported), `Capture/Export/{export_pipeline,export_geometry}.{h,cpp}`.
