# Windows port

Clingfy is being ported to Windows alongside the macOS engine. The Flutter
shell (`lib/`) is shared; the native engine under `windows/runner/` is being
built up incrementally to mirror the same Flutter↔native contract that
`macos/Runner/` already implements.

This document is the operating manual for that port. It lives next to the
code so the plan and the build steps stay in sync with what's actually
checked in.

## High-level strategy

> Reuse Flutter/UI/domain logic, keep the same Dart bridge contract, and
> rewrite only the native engine behind it.

The Dart-side bridge surface — channel names, method names, event types,
error codes — is the source of truth. macOS Swift and Windows C++ are both
implementations of that contract.

When adding or changing anything on the boundary, update all three sides:

1. Dart constants in `lib/core/bridges/native_method_channel.dart` and
   `lib/core/bridges/native_error_codes.dart`.
2. Swift constants in `macos/Runner/Core/NativeChannel.swift` (and friends).
3. Windows constants in `windows/runner/Bridge/native_channel_names.h` and
   `windows/runner/Bridge/native_error_codes.h`.

## Native Windows stack

| Concern                | Implementation                              |
| ---------------------- | ------------------------------------------- |
| Display / window capture | Windows.Graphics.Capture (DXGI fallback)  |
| System audio           | WASAPI loopback                             |
| Microphone             | WASAPI capture                              |
| Encoding / muxing      | Media Foundation (Sink Writer, H.264 + AAC)|
| GPU composition        | Direct3D 11                                 |
| Camera                 | Media Foundation device APIs                |
| Preview playback       | Media Foundation MediaEngine                |
| Overlays               | Win32 topmost layered windows               |
| File dialogs           | Common Item Dialog (IFileDialog)            |
| Updater                | WinSparkle                                  |

## Roadmap (phased)

The port is sequenced so that each phase produces a usable app. Do not skip
ahead — the hard parts (camera, chroma key, composition) depend on a stable
lifecycle, preview, and basic export.

| Phase | Goal                                                          | Status |
| ----- | ------------------------------------------------------------- | ------ |
| 0     | App launches; native bridge stubs; no MissingPluginException  | done   |
| 1     | Full bridge contract parity (every method routed, stubbed)    | done   |
| 2     | Real device / target discovery                                | done   |
| 3     | MVP recording (full display + mic + system audio → MP4)       | done   |
| 4     | Lifecycle parity (state machine, pause/resume, recovery)      | done   |
| 5     | Preview player + project reopen                               | done   |
| 6     | Basic export + post-processing (resolution, background, etc.) | done   |
| 7     | Window + area recording                                       | done   |
| 8     | Cursor sidecar + smart zoom                                   | done   |
| 9     | Camera overlay (basic, then advanced compositing/chroma)      | design locked (9.0); 9.1 next |
| 10    | Permissions UX + installer + updater + Windows beta polish    |

Detailed scope per phase is tracked in the session task list and in
[../CLAUDE.md](../CLAUDE.md).

## Current status — Phase 9.0 (camera overlay) — DESIGN LOCKED

Phase 9 adds the camera overlay — the biggest remaining macOS-parity feature. It
touches camera capture, a second media track + sync, a live preview overlay,
project persistence, export composition, styling, chroma key, and animations.
**9.0 is a docs-only design slice — no production camera code.** The locked
architecture + slice plan lives in
[decisions/windows-phase-9-camera-overlay-architecture.md](decisions/windows-phase-9-camera-overlay-architecture.md);
this section is the short version.

### What already exists (don't rebuild)

- **Camera enumeration** — `getVideoSources` is a real Phase-2 `MFEnumDeviceSources`
  enumerator returning `{id (symbolic link), name}`.
- **Camera permission** — `getPermissionStatus.camera` / `requestCameraPermission`
  / `ms-settings:privacy-webcam` all work via WinRT `AppCapabilityAccess`. Windows
  privacy is a **global** "let desktop apps access your camera" toggle (no per-app
  prompt).
- **MF encoder + decode** — `MfSinkWriterEncoder` (H.264) and the export
  `IMFSourceReader` decode path exist; the export D2D composite loop (screen +
  cursor + zoom) is the hook for the camera bubble.
- **Dart contract** — fully wired: `CameraCompositionState` (24 `camera*` keys),
  `setVideoSource`, `getRecordingSceneInfo` (returns `cameraPath` + camera state +
  a `CameraExportCapabilities` map), and `exportVideo` spreading the `camera*` args.

The genuinely new build is **camera capture**, **export composition**, and the
**live preview overlay**. The manifest `camera` block, `PreviewEngine.camera_path`,
and `setVideoSource` / `setCameraOverlay*` are present as placeholders/stubs to
fill in.

### Locked decisions (D1–D9)

- **D1** Capture via `IMFSourceReader` on the device (dedicated thread) → a second
  `MfSinkWriterEncoder` (reuses the encoder; avoids the heavier `IMFCaptureEngine`).
- **D2** One `camera/raw.mov`, **no** macOS-style segment files + merge — the
  pause-aware `RecordingClock` stamps frames in recording-time, so pause/resume
  needs no segments.
- **D3** Sync via the **shared recording clock**, not wall-clock overlap — the
  camera sample for screen-time `tMs` is just the camera sample at `tMs`.
- **D4** Ship styling **incrementally via `CameraExportCapabilities`** — each slice
  returns an honest capabilities map so the Dart UI only exposes what Windows
  renders; unsupported `camera*` args are accepted but ignored until their slice.
- **D5** Export = a second source reader + a **masked D2D draw** in the existing
  loop; the camera is **not** under the smart-zoom transform unless
  `zoomBehavior == scaleWithScreenZoom`; cursor/zoom soft-fail discipline reused.
- **D6** Live preview bubble = a native **Win32 layered overlay** (area-picker
  pattern); post-record preview-player camera compositing is deferred.
- **D7** Capture **raw + unstyled**; all styling (mirror/shape/border/shadow/chroma)
  is applied at **export** so it stays editable (matches the cursor/zoom model).
- **D8** Make `setVideoSource` real → `WindowsSelectionState`; emit the manifest
  `camera` block **conditionally** (only when a camera was actually recorded).
- **D9** Camera device loss mid-record = clean stop of the **camera only** —
  finalize `camera/raw.mov`, continue the screen recording (mirrors Phase 7.4).

### Deliberate divergences from macOS

Single `camera/raw.mov` + pause-aware timestamps (vs segments + merge);
shared-clock sync (vs wall-clock overlap); incremental styling via capabilities (vs
all-at-once); camera not under smart zoom unless `scaleWithScreenZoom`; no
hexagon/star shapes in MVP (circle/rounded/square/squircle only).

### Slice plan

| Slice | Goal                                                          | PR     |
| ----- | ------------------------------------------------------------- | ------ |
| 9.0   | Design / inventory                                           | (this) |
| 9.1   | Camera device selection + permission readiness              | next   |
| 9.2   | Camera recording to a separate file (`camera/raw.mov`)       | #147   |
| 9.3   | Live camera preview bubble during recording                  | #150   |
| 9.3.1 | Preview reconciliation: in-app Flutter texture (screen.mov camera-free) | #154 |
| 9.3.2 | Floating native bubble + capture-exclusion + 1-click in-app fallback | #155 |
| 9.3.3 | In-app preview is the Windows default (floating opt-in)      | #156   |
| 9.4   | Export: simple circular/rounded camera bubble                | #157   |
| 9.5   | Styling: mirror / opacity / border / shadow                  | #158   |
| 9.6   | Inline preview camera compositing (WYSIWYG before export)    | (this) |
| 9.7   | Chroma key + intro/outro/zoom-emphasis animations            |        |
| 9.8   | Closeout / stress / smoke                                    |        |

**MVP path:** 9.1 → 9.2 → 9.4 (screen + camera recorded → camera file in the
project → export with a simple bubble). Preview (9.3) and styling (9.5/9.6) follow.

## Current status — Phase 8 (cursor sidecar + smart zoom) — COMPLETE

Phase 8 switches Windows to Clingfy's editable-cursor model: the OS cursor is no
longer burned into the recording; instead a **cursor sidecar** is recorded and the
cursor, **click animation**, and **smart zoom** are rendered at **export** time
(so they stay editable). Architecture:
[decisions/windows-phase-8-cursor-zoom-architecture.md](decisions/windows-phase-8-cursor-zoom-architecture.md).
Every slice is a merged PR with native tests, smoked on a real Windows box.

| Slice | Goal                                                              | PR    |
| ----- | --------------------------------------------------------------- | ----- |
| 8.0   | Design / inventory                                              | #140  |
| 8.1   | Cursor sidecar recording (record `cursor.jsonl`, flip cursor off) | #141  |
| 8.2   | Cursor rendering in export                                      | #142  |
| 8.3   | Smart zoom export                                               | #143  |
| 8.4   | Click animation + Phase 8 closeout                             | (this) |

### Architecture

- **Recording (8.1):** a 60 Hz `CursorSampler` thread polls `GetCursorPos`,
  maps each position into capture-local px (display monitor-origin / area
  monitor+crop / window DWM extended-frame content-origin) via the pure
  `cursor_sample_mapper`, and streams a crash-robust `capture/cursor.jsonl`
  (header + per-sample lines, deduped). A `WH_MOUSE_LL` hook on its own
  message-loop thread records clicks. Timestamps come from the sampler's own
  pause-aware `RecordingClock`. `IsCursorCaptureEnabled(false)` is flipped on the
  live WGC session only after the sampler is confirmed running — else the Phase 7
  burned-in cursor stays (no cursorless video).
- **Cursor render (8.2):** `cursor_export_renderer` parses the sidecar and draws a
  standard vector arrow at the interpolated cursor position each frame in the
  existing Direct2D composite, mapped into the content rect, honoring
  `showCursor` / `cursorSize`.
- **Smart zoom (8.3):** pure ports of `ZoomHysteresis` / `ZoomFollowSmoother` /
  `ZoomTimelineBuilder` (reusing `preview/zoom_easing_constants.h`), driven by a
  **click-based** "zoom wanted" signal (macOS uses cursor-shape changes; Windows
  has no sprite data, so it zooms around clicks). `zoom_export_controller` builds
  segments, assigns each a focus mode (12px heuristic → fixed-target at the click
  point vs follow-cursor), and emits a per-frame smoothed `{zoom, center}` applied
  as a Direct2D transform to **both the video and the cursor** (one transformed
  space). Gated by `zoomEffectEnabled` / `zoomFactor`.
- **Click animation (8.4):** `cursor_export_renderer::DrawClicks` draws an
  expanding/fading ring at each click point (the cursor position at the click
  time), under the same zoom transform so it stays aligned.
- **Soft-fail everywhere:** a missing/malformed sidecar, no clicks, or no zoom
  segments → that effect simply doesn't render; the export never fails because of
  cursor/zoom. Cursor or zoom being active forces the composition path (a
  byte-copy can't draw them).

### Known deliberate edges / divergences from macOS (not bugs)

- **Cursor shape is a standard arrow, not the real per-frame cursor bitmap.**
  Sprite-accurate shapes (I-beam/hand) need record-time sprite capture, deferred
  from 8.1/8.2 — a future enhancement to the sampler.
- **Clicks are recorded and drive zoom + click animation; macOS records no
  clicks** (it triggers zoom from cursor-shape changes). This is a deliberate
  Windows substitute because sprite data isn't captured.
- **Cursor/zoom/click are export-rendered only.** The live preview player does not
  draw them yet.
- **Auto-zoom only.** Manual zoom-segment editing is not wired — the
  `getZoomSegments` / `saveManualZoomSegments` bridge methods remain stubs.
- **No export-time cursor-highlight halo.** The `cursorHighlight` setting is a
  live-recording feature ("active only when recording"); no export setting exposes
  a halo, so none is rendered (8.4 ships the click animation instead).
- **With cursor/zoom on (the defaults), an auto/auto export re-encodes** instead of
  byte-copying — necessary to draw them.

### Manual smoke checklist (cursor / zoom / click)

On a real Windows box, record a clip (move the mouse, click a few things), then
export and verify:

**Recording**
- [ ] The raw recording has NO cursor in the pixels; `capture/cursor.jsonl` exists
      with header + sample + click lines; `screen.meta.json` has `cursorEnabled`.
- [ ] Pause/resume: sidecar `tMs` excludes paused time; a target-loss partial still
      has a valid `cursor.jsonl`.

**Export**
- [ ] The cursor appears in the export (arrow), tracking the recorded path;
      `showCursor=false` hides it; `cursorSize` scales it.
- [ ] Smart zoom zooms toward clicks, holds, and eases back out; follow vs fixed
      behaves; the cursor stays glued inside the zoomed view.
- [ ] Clicks produce a visible expanding ring at the click point, aligned under
      zoom.
- [ ] MP4, MOV, AND GIF all render cursor + zoom + clicks; progress + cancel work;
      audio unaffected.
- [ ] An older recording with no sidecar (or effects off) exports cleanly with no
      cursor/zoom/clicks.

## Current status — Phase 7 (window + area recording) — COMPLETE

Phase 7 adds capture targeting on top of the Phase 6 full-display loop: record a
single **window**, a dragged-out screen **area**, plus clean handling when the
captured target disappears. The architecture is locked in
[decisions/windows-phase-7-capture-architecture.md](decisions/windows-phase-7-capture-architecture.md);
every slice is a merged PR with native tests, and the whole matrix has passed a
manual smoke on a real Windows box.

| Slice | Goal                                                              | PR    |
| ----- | --------------------------------------------------------------- | ----- |
| 7.0   | Design / inventory (architecture decisions, slice plan)         | #134  |
| 7.1   | Window recording via WGC `CreateForWindow(HWND)`                | #135  |
| 7.2   | Area recording (full-monitor capture + GPU crop)               | #136  |
| 7.3   | Native per-monitor area-picker overlay                          | #137  |
| 7.4   | Target-loss + polish (window close / monitor unplug)           | #138  |

### Architecture

- **Window capture** uses WGC `IGraphicsCaptureItemInterop::CreateForWindow(HWND)`
  (the analog of the existing `CreateForMonitor`). `kAppWindow` and
  `kSingleAppWindow` both map to single-HWND capture for the MVP. The encoder is
  sized from `GraphicsCaptureItem.Size()`, not the monitor.
- **Area capture** is full-monitor WGC capture cropped per frame with
  `CopySubresourceRegion` + a `D3D11_BOX` into an encoder-sized staging texture
  (mirroring macOS's `sourceRect` crop — there is no per-rectangle WGC item).
- **`EvenCaptureDimension` + `ResolveCropBox`** are the single source of truth for
  the encoder-vs-frame even-size and crop contract, shared by the engine
  (encoder config) and the backend (frame copy), so the two agree by construction
  (H.264 needs even, fixed dimensions — a 1px drift corrupts the stream).
- **Area picker** is a native per-monitor layered Win32 overlay
  (`WS_POPUP|WS_EX_TOPMOST|WS_EX_LAYERED`), modal drag-select with Esc / right-click
  cancel, returning `{displayId,x,y,width,height}` into `WindowsSelectionState`,
  reusing the 7.2 crop path. The selection geometry (`area_picker_geometry`) is
  pure and unit-tested; the overlay itself is human-smoked.
- **Target-loss** subscribes to `GraphicsCaptureItem.Closed` — one signal that
  fires for a window close AND a captured-monitor unplug (display / area /
  window). The backend forwards it (a lifetime-independent shared guard, never a
  raw `this`, and the token is never revoked) → `PlatformThreadDispatcher::Post` →
  `RecordingEngine::HandleTargetLost`, which finalizes the partial **exactly once**
  (engine mutex + session-id re-check, so a racing user Stop / stale close is a
  no-op).

### Known deliberate edges (not bugs)

- **Cursor is burned into the video.** Windows has no cursor sidecar yet, so the
  OS cursor is captured into the MVP recording (explicit
  `IsCursorCaptureEnabled(true)`). The Phase 8 sidecar flips this to `false`.
- **`kAppWindow` == single-window capture.** macOS captures all of an app's
  windows; the Windows MVP captures the one selected HWND.
- **Target-loss keeps the partial (better than macOS).** When the captured target
  is lost mid-recording, Windows finalizes and KEEPS what was recorded
  (`recordingWarning` + `recordingFinalized` → the partial opens into
  preview/export); only a zero-frame loss or a writer failure surfaces
  `recordingFailed`. macOS discards on target loss — this is a deliberate
  divergence from the original D9 (which also discarded).
- **Window resize mid-recording keeps the initial size.** The frame pool is
  fixed-size and the copy box is pinned to the even initial capture size, so a
  resized window never changes the encoder dims (a grown window is cropped to the
  original rect; resize-follow is out of MVP scope). Output is never corrupted.
- **Area selection is a dimmed box, not a transparent cut-out.** The picker dims
  the screen and draws a bright-bordered selection rectangle (not a clear hole).

### Deferred (tracked for closeout / a follow-up, not blocking Phase 7)

- **Area selection does not survive an app restart.** The native area region
  (`WindowsSelectionState::AreaRegion`) is process-memory only, so a Dart-restored
  selection passes the UI gate but `RecordingEngine::Start` fails ("pick an area
  first") after a relaunch — re-pick to record. Fix by persisting/rehydrating the
  region natively, or clearing the Dart prefs on launch.
- **Yellow capture border not yet disabled (D8).** Best-effort
  `IsBorderRequired=false` behind a capability check is not wired up.
- **No selection-clear for a *non-captured* monitor on display change.** A
  `WM_DISPLAYCHANGE`-driven clear of a stale selection (macOS's
  `screenParamsChanged`) is not implemented; the captured-target-loss case is fully
  handled via `GraphicsCaptureItem.Closed`.

### Manual smoke checklist (window / area / target-loss)

Native tests cover the engine lifecycle, exactly-once finalize, the pure picker
geometry, and a real GPU capture round-trip, but visual correctness and the modal
overlay are human checks. On a real Windows box:

**Window**
- [ ] Recording a selected window produces an MP4 of that window's content at its
      size; full-display recording is unaffected.
- [ ] A stale/closed window picked before Start fails with a friendly error (no
      crash, no empty file).
- [ ] Closing the window mid-recording stops cleanly, shows a "the window you were
      recording closed; your recording was saved" notice, and opens the partial
      into preview/export (which plays and exports).
- [ ] Minimizing / resizing the window mid-recording does not crash or corrupt the
      output (video holds the original size).

**Area**
- [ ] Drag-select on any monitor (incl. a secondary / negative-origin display)
      records exactly that region; Esc and right-click cancel cleanly with no stray
      overlay; a tiny (<16px) drag is rejected.
- [ ] The overlay is torn down before capture (not visible in the recording).

**Display / target-loss**
- [ ] Unplugging the captured monitor mid-recording stops + finalizes cleanly
      (same keep-partial flow).
- [ ] Pressing Stop normally still finalizes exactly one recording (no duplicate
      preview / error).

## Current status — Phase 6 (export + post-processing) — COMPLETE

Phase 6 is feature-complete: Windows now does the full **record → preview →
export** loop. Export was built slice-by-slice; each slice is a merged PR with
native tests, and the whole matrix has passed a manual GIF + no-regression smoke
on a real Windows box.

| Slice | Goal                                                                | PR(s)      |
| ----- | ------------------------------------------------------------------- | ---------- |
| 1     | Export baseline / fast byte-copy passthrough (auto/auto MOV)        | #125, #127 |
| 2     | Resolution / layout / fit-fill composition                         | #126       |
| 3     | Background color / padding / corner radius                         | #128       |
| 4     | Audio gain / volume / normalize                                     | #130       |
| 5A    | MP4 container + bitrate + progress events + cancel                  | #131       |
| 5B    | Animated GIF export (WIC)                                           | #132       |

### Architecture

- **MOV / MP4** ride Media Foundation. The identity transform (auto/auto, no
  Slice 3 styling, no Slice 4 audio change, `.mov` output) byte-copies the
  source; anything else decodes with `IMFSourceReader`, composites each frame
  with Direct2D (`export_geometry` + `export_pipeline`), and re-encodes H.264 via
  `MfSinkWriterEncoder` (`.mp4` vs `.mov` is chosen by the destination
  extension). Bitrate preset → H.264 average bitrate (`export_format`).
- **GIF** is a separate output path: Media Foundation has no GIF sink, so GIF
  reuses the same decode → Direct2D composite → progress/cancel loop but forks
  the encoder to a WIC `IWICBitmapEncoder` (`GUID_ContainerFormatGif`,
  `Encoding/gif_encoder.{h,cpp}`) — composited GPU texture read back to CPU via a
  staging texture, 256-color adaptive palette per frame with error-diffusion
  dither, NETSCAPE2.0 infinite loop, frames decimated to ~15 fps on an ideal grid
  (`Capture/Export/gif_export_policy.{h,cpp}`).
- **Progress / cancel** run the export on a worker thread (`export_session`,
  `export_progress_publisher`); cancel aborts mid-flight, deletes any partial
  output, and resolves the Dart future as a clean cancel. Every export result
  path answers the Dart `MethodResult` exactly once (no hangs).

### Known deliberate edges (not bugs)

- **HEVC falls back to H.264.** A Dart `codec: hevc` request renders as H.264;
  codec selection is a future slice.
- **GIF is opaque — no partial alpha.** GIF cannot represent partial
  transparency, so the GIF background (and rounded-corner / padding regions) is
  forced fully opaque and shows the solid background color.
- **GIF uses WIC; MP4/MOV use Media Foundation.** Two distinct encoder paths by
  design.
- **No background image yet.** Slice 3 is solid color only; image / preset
  backgrounds are future work.
- **No advanced export presets.** Bitrate is auto / low / medium / high; finer
  preset surface area is later.

### Manual smoke checklist (MOV / MP4 / GIF)

Native tests cover the math plus a GPU round-trip, but visual correctness is a
human check. On a real Windows box, record a short clip, then export and verify:

**MOV**
- [ ] auto/auto exports near-instantly (byte-copy fast path) and plays.
- [ ] a resolution/layout change re-encodes with correct framing / letterboxing.

**MP4**
- [ ] output is a real `.mp4` that plays; low vs high bitrate changes file size.
- [ ] progress advances to 100% on a longer export.

**GIF**
- [ ] output is a real animated `.gif` that loops in a browser / image viewer.
- [ ] styling (resolution, background color, padding, corner radius) is
      reflected; corners / margins show the solid background color (opaque).
- [ ] ~15 fps and the file size is sane for the clip length.
- [ ] progress reaches 100% on a longer GIF.

**Cancel + cross-cutting**
- [ ] cancel mid-export (any format) stops cleanly, leaves no stray / partial
      file, and a new export starts afterward.
- [ ] combined MP4 + styling + audio still works.

## Current status — Phase 4 (lifecycle parity)

Phase 4 adds pause / resume on top of the Phase 3 MVP recording. The
state machine grows three transitional states (`Pausing`, `Paused`,
`Resuming`); the clock learns to subtract the cumulative paused time
so the encoder's timestamps stay continuous; and WGC + the two WASAPI
captures gain per-session pause hooks so they don't waste host
resources while paused.

### Changes summary

| File | What changed |
| ---- | ------------ |
| `Capture/recording_clock.{h,cpp}` | `Pause()` / `Resume()` accumulate `paused_hns_`; `ElapsedHns()` subtracts both completed pauses and any in-progress pause's partial duration so the encoder never sees the clock advance while paused. |
| `Capture/recording_session_state.{h,cpp}` | New `kPausing` / `kPaused` / `kResuming` states. `BeginPause` only valid from Recording; `BeginResume` only from Paused. `BeginStop` widened to accept Paused (the user can press Stop after Pause to finalize the partial recording). |
| `Capture/wgc_display_capture_backend.{h,cpp}` | Atomic `paused_` flag short-circuits the FrameArrived handler before the texture copy — WGC keeps producing but the frame auto-closes immediately. No queue push, no GPU work. |
| `Audio/wasapi_audio_capture.{h,cpp}` | `Pause()` calls `IAudioClient::Stop` (the buffer event simply stops firing, the capture thread idles on its WaitForMultipleObjects timeout); `Resume()` calls `Start`. Both idempotent. |
| `Capture/recording_engine.{h,cpp}` | New `Pause(session_id)` / `Resume(session_id)`. Idempotent at the engine level — already-paused / already-recording returns success. `kNotRecording` when no session is active. Pause order: clock → WGC → mic → loopback; reverse on resume so capture is live before the clock starts producing new timestamps. Emits `recordingPaused` / `recordingResumed` workflow events. |
| `Bridge/Routers/recording_router.cpp` | `pauseRecording` / `resumeRecording` / `togglePauseRecording` swap from the Phase-1 no-op stubs to real engine calls. `getRecordingCapabilities` flips `canPauseResume:true` with `strategy:"windows_mf_pause"`. |
| `Bridge/workflow_event_publisher.{h,cpp}` | `EmitRecordingPaused` / `EmitRecordingResumed` helpers matching the macOS `ScreenRecorderEventBridge` payload exactly. |

### What works after Phase 4

- Mid-recording Pause from the Flutter UI freezes audio + video capture. The MP4 the engine eventually writes has no audible / visible discontinuity at the seam — the timestamps "skip" the paused interval.
- Resume restarts capture from the paused instant. Multiple pause cycles in one recording accumulate cleanly.
- Stop from Paused finalizes a shorter MP4 rather than refusing the call.
- `getRecordingCapabilities` reports `canPauseResume:true` so Dart's UI no longer hides the pause button on Windows.
- Idempotent: double-pause / double-resume / pause-when-idle / resume-when-idle all return the right code (`success`, `success`, `NOT_RECORDING`, `NOT_RECORDING`) without breaking the recording.

### What still doesn't work after Phase 4

- No mid-recording recovery: if the WGC capture session, IAudioClient, or the encoder fail mid-flight, the engine's drain thread logs and continues — the next Stop still finalizes whatever made it through, but there's no proactive watchdog that aborts a broken session.
- Preview playback (Phase 5) is still the Phase 1 no-op. Once the user clicks the recording in the post-record list, Dart's `previewOpen(projectPath)` reaches the Windows bridge and silently succeeds with nothing to show. The renderer that fills this gap is locked — see "Phase 5 POC — architecture decision" below — but production code has not been written yet.

## Phase 5 POC — architecture decision (between Phase 4 and Phase 5)

Phase 5 production is gated on a runtime architecture decision: how a decoded video frame becomes pixels inside the Flutter preview view. To make that decision on evidence rather than speculation, the port ran a sequenced POC under `windows/runner/preview/` (gated by the `BUILD_LIVE_COMPOSITOR_POC` CMake option for the standalone demos and by `--dart-define=POC_STAGE_2A=true` for the in-app debug screen). Nothing in the POC ships in production builds: `flutter build windows` never enters the POC CMakeLists, and the dart-define-gated debug screen tree-shakes out of release Dart.

POC sequence (most recent last; all merged into `develop`):

| PR  | Stage  | What it proved |
| --- | ------ | -------------- |
| #96 | Step 0 | Zoom / easing constants moved to a shared Windows header, parity-tested against macOS Swift. |
| #97 | 1A0    | Direct2D on an HWND swap chain — 2D rendering / Present is alive in our build. |
| #98 | 1B     | MediaPlayer frame-server → Direct2D on HWND. Real decoded video at the per-frame budget. |
| #100 | 1C    | Stage 1B + cursor JSONL → smart-zoom + radial halo composition. |
| #101 | 1D    | Stage 1C + scrub slider + 30 s measurement window + Markdown verdict artifact. Total median **4.040 ms**, p99 **4.991 ms**. |
| #102 | 2A-1  | DXGI shared-handle texture (solid-color animated) → Flutter `Texture(textureId:)`. Raster median **0.865 ms**, p99 **1.858 ms**. Confirmed legacy `IDXGIResource::GetSharedHandle` is required; NT handles + keyed mutex crash. |
| #103 | 2A-2 Phase A | Extract `PreviewCompositor` into the shared `preview_poc_common` static lib so the HWND demo and the Flutter bridge consume the same composition logic. |
| #104 | 2A-2 Phase B+ | Real MediaPlayer → `PreviewCompositor` → DXGI shared handle → Flutter `Texture`. Native total median **4.178 ms**, p99 **6.001 ms**; Flutter raster median **0.886 ms**, p99 **10.741 ms**; 712 frames, 0 dropped — all under the 16 / 25 ms design-doc bar. |

The resulting decision is recorded in [decisions/windows-phase-5-preview-architecture.md](decisions/windows-phase-5-preview-architecture.md). Summary: **Approach A is accepted** — WinRT MediaPlayer frame-server + `PreviewCompositor` + `D3D11_RESOURCE_MISC_SHARED` + Flutter `Texture` widget, with the Flutter shell as the visible preview surface. That note also lists the locked technical choices (legacy shared handle only, multi-thread-protected D3D11 + `MULTI_THREADED` D2D factory, explicit `Flush` before mark-frame-available) and the known follow-ups that production must address before ship (texture unregister stability on Intel iGPU, audio path, multi-GPU validation, the move out of `poc_stage_2a/` into `preview/` proper).

The Phase 5 design v2 — the production implementation order for `previewOpen`, `previewPlay` / `previewPause`, `previewSeekTo`, `player/events`, `getRecordingSceneInfo`, `.clingfy` project reopen — is recorded in [decisions/windows-phase-5-implementation-plan.md](decisions/windows-phase-5-implementation-plan.md). The plan splits Phase 5 into eight PRs (5.0 → 5.7), with Step 5.7 (multi-GPU validation + texture-unregister fix) gating the ship. Production work on `previewOpen` does not start until Step 5.0 (lift the Stage 2A-2 bridge out of `poc_stage_2a/` and rename to `PreviewEngine`) lands.

## Permissions handling (between Phase 3 and Phase 4)

The recording flow's preflight (`lib/app/home/home_actions.dart` → `recording_start_preflight_rules.dart`) checks four permission slots: `screenRecording`, `microphone`, `camera`, `accessibility`. Windows handles them as follows:

| Slot              | Windows behavior |
| ----------------- | ---------------- |
| `screenRecording` | Always `true`. WGC requires no system grant. |
| `microphone`      | Probed via `Windows.Security.Authorization.AppCapabilityAccess.AppCapability::Create("microphone").CheckAccess()`. Reflects both the global "Allow desktop apps to access your microphone" toggle and the per-app entry in `Settings > Privacy > Microphone`. |
| `camera`          | Same probe with `"webcam"`. |
| `accessibility`   | Always `true`. Windows has no AX-trust gate for input / cursor capture. |

The `request*` handlers cannot trigger the Windows TCC-style prompt (it doesn't exist for non-packaged Win32 apps); when the probe reports denied they deep-link into the relevant `ms-settings:` page so the user can flip the toggle and retry. `requestScreenRecordingPermission` / `isAccessibilityTrusted` always return `true`.

`openSystemSettings(pane)` accepts `"microphone"` / `"camera"` (or `"webcam"`) / `"screenRecording"` / `"accessibility"` and launches the matching `ms-settings:` URI via `ShellExecuteW`. Unknown panes are a silent no-op so a forward-compatible Dart client doesn't crash here.

Source files:
- `windows/runner/Permissions/permission_probe.{h,cpp}` — probe + URI table + ShellExecuteW launcher.
- `windows/runner/Bridge/Routers/permissions_router.cpp` — handler wiring.

## Current status — Phase 3E (Phase 3 complete)

Phase 3E closes the MVP recording slice. The end-to-end path now
mirrors what the macOS engine does: a Windows recording produces a
`.clingfyproj` bundle that Dart's `RecordingProjectRef.open` accepts,
and the workflow lifecycle events fire on the `workflow/events`
channel exactly the way the Dart `recording_controller` listener
expects.

### New files

```
windows/runner/Bridge/
  workflow_event_publisher.{h,cpp}    Process-level singleton owning
                                       the workflow channel's EventSink.
                                       Helpers for the four lifecycle
                                       events (started / finalized /
                                       failed / warning) match the
                                       macOS payload shape exactly.

windows/runner/Capture/
  recording_project_writer.{h,cpp}    Reshapes the encoder's temp MP4
                                       into a `.clingfyproj` folder:
                                       project.json (status:"ready"),
                                       capture/screen.mov,
                                       capture/screen.meta.json,
                                       post/state.json. Pure file I/O —
                                       unit-tested by pointing the
                                       recordings root at a temp dir.
```

### `event_channel_stubs` lost a stub

The Phase 0 `EventChannelStubs` registered a no-op handler for all four
event channels. Phase 3E replaces the `workflow/events` handler with
one that forwards `listen` / `cancel` into `WorkflowEventPublisher`;
the other three channels stay no-op until later phases pick them up
(player events in 5, screen-recorder device-change events in 4,
updater in 10).

### Engine integration

`RecordingEngine::Start` now emits `recordingStarted` after
`MarkStarted` succeeds. Every early-return on the start path emits
`recordingFailed{sessionId, stage:"start", code, error}` so Dart's UI
flips out of "starting" regardless of which gate refused. Stop
snapshots `Diagnostics()` before `TeardownPipeline`, runs
`RecordingProjectWriter`, and emits `recordingFinalized{sessionId,
projectPath}` on success or `recordingFailed{..., stage:"finalize"}`
on writer failure. Mismatched-sessionId stops still return the
structured error but do NOT emit — the active recording is unaffected
and we don't want to race a finalize event for the wrong session.

### `getCaptureDiagnostics`

Returns a live map keyed by `backend` (`"windows_mf"`), the frame /
audio counters from `RecordingEngine::Diagnostics()`, and the
in-flight `outputPath`. Free-space counters (`captureDestinationFreeBytes`
etc. that macOS surfaces) are deferred to Phase 10 alongside the
storage UX.

### What works after Phase 3E

- Start → record for N seconds → Stop produces a `.clingfyproj` bundle
  under `%LOCALAPPDATA%\Clingfy\recordings\<sessionId>.clingfyproj\`,
  ready for Dart to open via `nativeBridge.previewOpen(projectPath)`.
- Flutter's recording UI transitions out of "starting" on
  `recordingStarted`, into preview / post-processing on
  `recordingFinalized`, and back to idle on `recordingFailed` —
  matching the macOS flow with no Windows-only branches.
- Recording warnings surface as toasts via the existing
  `recordingWarning` listener.
- The picker shows real device counts via the live
  `getCaptureDiagnostics`.

### What still doesn't work after Phase 3E

- Phase 4: no pause / resume (the bridge methods stay as no-op
  success; the recording continues straight through).
- Phase 4: no recovery if WASAPI / WGC mid-recording — a capture
  failure shows up only at finalize, not in real time.
- Phase 5: preview playback once Dart opens the project — the Windows
  `previewOpen` handler is still the Phase 1 no-op. Project opens but
  the preview view shows an empty timeline.
- Phase 6+: post-processing, window / area / camera / zoom remain
  capability-gated off.

## Current status — Phase 3D

Phase 3D adds the audio half of the MVP recording slice: the captured
display is now muxed alongside the user's microphone and the system
audio loopback into a single MP4 file via an AAC audio track.

### New files

```
windows/runner/Audio/
  audio_format.{h,cpp}           WAVEFORMATEX → AudioFormatSnapshot,
                                 plus IsPipelineCompatible(snapshot)
                                 and ClampFloat32ToInt16. Pure helpers,
                                 unit-tested without WASAPI.
  audio_packet.h                 POD packet: interleaved float32 stereo
                                 samples + 100-ns timestamp + silent
                                 flag.
  audio_packet_queue.{h,cpp}     Bounded thread-safe queue mirroring
                                 VideoFrameQueue's drop-oldest contract.
  audio_mixer.{h,cpp}            Sums two streams element-wise into
                                 interleaved int16 PCM. Pads the shorter
                                 stream with silence, honors the
                                 producer's `silent` flag, tracks a
                                 monotonic sample-position counter so
                                 the AAC stream never sees a tied
                                 timestamp.
  wasapi_audio_capture.{h,cpp}   Unified mic / system-loopback client
                                 via WASAPI shared-mode + event-driven
                                 IAudioCaptureClient. Pimpl keeps the
                                 IMMDevice / IAudioClient COM pointers
                                 out of consumer headers. Pinned to
                                 48 kHz float32 stereo input (rejected
                                 otherwise — Phase 3D does not yet
                                 resample). Capture thread runs at
                                 Pro Audio MMCSS priority so an OS
                                 preempt doesn't blow the buffer.
```

### Encoder extension

`MfSinkWriterEncoder::Open(...)` grew an optional `AudioEncoderConfig`
parameter. When supplied, the encoder adds an AAC LC output stream
(48 kHz / 128 kbps / stereo) alongside the existing H.264 video
stream — the same Sink Writer instance owns both. The new
`WriteAudioPacket(MixedPacket)` writes one PCM int16 sample into the
audio stream, tagged as a clean point (every AAC sample is a sync
sample, no inter-sample dependency). Audio bookkeeping is reset on
Cancel().

### Engine orchestration

`RecordingEngine::Start` reads two new boolean gates from the Dart
`StartRecordingRequest`:
- `disable_microphone` → if false, mic capture starts via
  `WasapiAudioCapture(kMicrophone, MicrophoneId, mic_queue_)`.
- `system_audio_enabled` → if true, loopback capture starts via
  `WasapiAudioCapture(kSystemLoopback, "", loopback_queue_)`.

Either capture is best-effort: if mic open fails, the recording
continues with system audio only and vice versa. If both fail (or
both flags are off), the encoder is opened video-only.

A dedicated mixer thread blocks on `mic_queue_->Pop()` and grabs the
matching loopback packet via `TryPop` (so missing system audio doesn't
stall the mixer); both packets are summed via `AudioMixer::Mix`, and
the result is handed to `encoder_->WriteAudioPacket`. When only
loopback is alive, the mixer flips to a blocking Pop on the loopback
queue so it doesn't busy-spin.

Stop tears down in this order: capture producers → close queues → join
encoder + mixer threads → encoder.Finalize() (writes MOOV atom with
both tracks) → release D3D device.

### What works after Phase 3D

- Mic-only recording (request `disable_microphone=false`,
  `systemAudioEnabled=false`) produces an MP4 with one video track and
  one mic audio track.
- System-audio-only recording (mic disabled, system audio enabled)
  records whatever is playing through the default render endpoint.
- Mic + system audio together → both streams mixed into one AAC track.
- Selecting a mic via `setAudioSource` is honored — `MicrophoneId` from
  `WindowsSelectionState` is passed to the capture; a stale id falls
  back to the default capture endpoint without failing the recording.
- A missing or unsupported mix format (anything other than 48 kHz
  float32 stereo) skips that capture and logs; the recording continues
  with the other source.

### What still doesn't work after Phase 3D

- The MP4 still lands in `%TEMP%`; project folder + recent-recordings
  routing is Phase 3E.
- No workflow events on `workflow/events` — Flutter UI parks in
  "starting" after a successful `startRecording`. Phase 3E.
- Audio-format conversion (e.g. headsets that default to 44.1 kHz or
  16-bit PCM) is a hard reject in 3D; the capture is dropped with a
  structured warning. A resampler shim can land in a follow-up if
  prod telemetry shows real-world hosts are affected.

## Current status — Phase 3C

Phase 3C drains the `VideoFrameQueue` Phase 3B set up and writes a
playable MP4 to disk. The recording lifecycle is now end-to-end at the
video level: start → frames arrive → samples encoded → stop → MP4
finalized.

### New files

```
windows/runner/Encoding/
  mf_encoder_config.{h,cpp}      Plain config struct (width, height, fps,
                                 bitrate, output path) + Validate(). Pure,
                                 unit-tested without touching MF.
  encoder_output_path.{h,cpp}    Phase-3C output-path helper. Sanitizes
                                 sessionId (any non `[A-Za-z0-9._-]` →
                                 `_`) and joins under %TEMP%. Phase 3E
                                 swaps this for the real project folder.
  mf_dxgi_manager.{h,cpp}        Tiny RAII wrapper around
                                 IMFDXGIDeviceManager — required to
                                 engage the hardware H.264 encoder MFT,
                                 without it MF silently falls back to
                                 software encode.
  mf_sink_writer_encoder.{h,cpp} Wraps IMFSinkWriter. Open() configures
                                 hardware H.264 output + ARGB32 input
                                 over MP4. WriteVideoFrame() translates a
                                 CapturedVideoFrame into an IMFSample via
                                 MFCreateDXGISurfaceBuffer. Finalize()
                                 closes the MOOV atom out so the file is
                                 playable. Re-bases timestamps so the
                                 MP4 always starts at t=0.
```

### Capture-side change

The Phase 3B FrameArrived handler pushed metadata with `texture =
nullptr` because the WGC frame-pool surface gets recycled as soon as
the `Direct3D11CaptureFrame` auto-closes. Phase 3C extracts the
underlying `ID3D11Texture2D`, copies it into a freshly-allocated
staging texture via `ID3D11DeviceContext::CopyResource`, and pushes
that into the queue instead. The encoder can hold the staging texture
through `WriteSample` and release it via the IMFSample's normal COM
refcount path.

### Engine integration

`RecordingEngine::Start` now spins up the MP4 encoder + a dedicated
drain thread that blocks on `frame_queue_->Pop()` and feeds frames to
the encoder. `RecordingEngine::Stop` closes the queue (wakes the
drain), joins the thread, then calls `encoder_->Finalize()` so the MP4
footer is written before `stopRecording` returns success to Dart. If
any of the start steps fails, `TeardownPipeline` rolls everything back
in the right order so the next Start is a clean retry.

`getRecordingCapabilities` still reports `canPauseResume: false` and
`backend: "windows_mf"`. The engine's `Diagnostics()` now also tracks
`samples_written` and `output_path` so 3E can wire those onto the
bridge.

### Output

`%TEMP%\clingfy_<sanitized-sessionId>.mp4`. Pickable in any media
player. Phase 3E moves this into the real Clingfy project folder.

### What works after Phase 3C

- 5–10 second display recording produces a playable MP4.
- Stop finalizes the MOOV atom — file is not 0 bytes; duration is
  roughly correct (within a few hundred ms of wall-clock).
- A second startRecording after stopRecording works (the engine resets
  cleanly).
- `BAD_MODE` for non-display targets, `BAD_ARGS` for invalid frame
  rates, `RECORDING_ERROR` for D3D / MF setup failures.

### What still doesn't work after Phase 3C

- No audio at all (Phase 3D — WASAPI mic + system loopback, AAC
  encoded into the same MP4).
- No workflow events on `workflow/events` — Flutter UI still parks in
  "starting" after a successful `startRecording`. Phase 3E.
- The MP4 lands in `%TEMP%`; recent recordings + project format land
  alongside the workflow events in 3E.

## Current status — Phase 3B

Phase 3B builds on the 3A skeleton by spinning up a real
Windows.Graphics.Capture pipeline behind `startRecording`. Frames now
arrive on a WinRT thread-pool callback, get tagged with a 100-ns
timestamp, and land in a bounded queue waiting for the encoder that
lands in 3C. No MP4 file is produced yet — the queue's frames are
dropped on the floor when the queue fills.

### New files

```
windows/runner/
  Graphics/
    d3d_device.{h,cpp}              D3D11CreateDevice with the mandatory
                                    BGRA_SUPPORT flag, hardware → WARP
                                    fallback for headless / VM hosts.
  Capture/
    captured_video_frame.h          Frame metadata struct (timestamp,
                                    size, optional ID3D11Texture2D).
    video_frame_queue.{h,cpp}       Bounded thread-safe queue. Drops
                                    oldest frame when full; surfaces
                                    drop / total counters so diagnostics
                                    can spot a backed-up encoder.
    wgc_display_capture_backend.{h,cpp}
                                    GraphicsCaptureItem from HMONITOR via
                                    the interop activation factory.
                                    Direct3D11CaptureFramePool::Create-
                                    FreeThreaded; FrameArrived pushes
                                    metadata into the queue. Pimpl keeps
                                    `<winrt/...>` out of public headers.
    windows_selection_state.{h,cpp} Process-level singleton for the user's
                                    display + target-mode + microphone
                                    choices. Phase 1/2 setters now write
                                    here; the engine snapshots at Start.
```

### Capability gate

`RecordingEngine::Start` rejects every target mode except
`explicitId` with a structured `BAD_MODE` error so Dart's existing
"feature not supported" path lights up. The roadmap for the other
modes:

| Target mode | Lands in |
| ----------- | -------- |
| `appWindow` / `singleAppWindow` | Phase 7 (window recording) |
| `areaRecording` | Phase 7 (window + area recording) |
| `mouseAtStart` / `followMouse` | Phase 8 (cursor sidecar + zoom) |

### Display resolution

`setDisplay` stores the hashed display id from Phase 2 in
`WindowsSelectionState`. At `Start` time the engine calls
`display_enumerator::ResolveHMonitor(id)` to re-walk monitors and find
the live HMONITOR — that re-resolution catches docked / undocked
monitors that change between the picker render and the record click.
A null selection falls back to the primary monitor.

### What works after Phase 3B

- `startRecording` (with explicit-display target mode) walks the full
  pipeline: D3D device → WGC item → frame pool → capture session.
  FrameArrived fires on a thread-pool thread and pushes metadata into
  `VideoFrameQueue` until the queue is full or `stopRecording` runs.
- `getCaptureDiagnostics` still returns an empty map on the bridge —
  the engine's `Diagnostics()` is wired internally but not yet surfaced
  to Dart; that happens with the rest of the 3E workflow integration.
- `stopRecording` tears the WGC session, frame pool, and D3D device
  down in order. Safe to call repeatedly.
- `setDisplay`, `setDisplayTargetMode`, `setAudioSource` no longer
  no-op; they feed `WindowsSelectionState`.
- 4 new error codes surface via the existing bridge:
  `BAD_MODE` (unsupported target mode), `TARGET_ERROR` (no monitor
  found), `RECORDING_ERROR` (D3D / WGC initialization failure).

### What still doesn't work after Phase 3B

- No MP4 file. The frame queue fills and frames get dropped. Phase 3C
  adds the Media Foundation Sink Writer that drains the queue and
  writes H.264 video into an MP4.
- No audio at all. Phase 3D.
- No workflow events — Flutter UI still parks in "starting". Phase 3E.
- Window / area / follow-mouse modes return `BAD_MODE` and are gated
  off the picker until later phases.

## Current status — Phase 3A

Phase 3 is split into five vertical slices so each one ships a real PR
against develop instead of one giant landing:

| Sub-phase | Goal | Status |
| --------- | ---- | ------ |
| 3A | Recording engine skeleton + honest capability gate | done |
| 3B | WGC full-display video capture (frames arrive, no MP4 yet) | done |
| 3C | MP4 / H.264 video writer (Media Foundation Sink Writer) | done |
| 3D | WASAPI microphone + system-audio capture, mixed into the MP4 | done |
| 3E | Project manifest + workflow events so Flutter sees a real recording | done |

Phase 3A introduces `windows/runner/Capture/`:

| File | What it does |
| ---- | ------------ |
| `recording_session_state.{h,cpp}` | Pure state machine: `Idle → Starting → Recording → Stopping → Stopped` (`Failed` reachable from any active state). Illegal transitions return `false` so the engine can map them to structured `ALREADY_RECORDING` / `NOT_RECORDING` / `INVALID_RECORDING_STATE` errors instead of throwing. |
| `recording_clock.{h,cpp}` | QueryPerformanceCounter wrapper that converts ticks to 100-ns units (Media Foundation sample timestamp unit). The QPC source is injectable so the unit tests can exercise the conversion math with a fake clock. |
| `recording_engine.{h,cpp}` | Singleton orchestrator. `Start(StartRecordingRequest)` validates args (`sessionId` required, `frameRate > 0`), drives the state machine, and stamps the clock. `Stop(sessionId)` is idempotent and rejects mismatched session ids. No capture or encoding yet — those land in 3B / 3C / 3D. Thread-safe via `std::mutex` so later phases can call it from the capture / audio threads. |

`recording_router.cpp` no longer returns `WINDOWS_NOT_IMPLEMENTED` for
`startRecording` / `stopRecording`; it parses the Dart-shaped argument map
into a `StartRecordingRequest` and forwards to the engine. The
`getRecordingCapabilities` reply flips its `backend` field from the
placeholder `"windows-stub"` to the honest `"windows_mf"` while
`canPauseResume` stays `false` (pause/resume lands in Phase 4).

### What works after Phase 3A

- `startRecording` succeeds when given a valid `sessionId`; the engine
  transitions to `Recording` and stamps a wall clock.
- `stopRecording` succeeds and returns the engine to `Idle`. A
  double-stop is idempotent. A mismatched `sessionId` returns a structured
  `INVALID_RECORDING_STATE` error rather than silently stopping the wrong
  session.
- A second `startRecording` while one is in flight returns
  `ALREADY_RECORDING` (mapped from the state machine).
- Bad args (empty `sessionId` or non-positive `frameRate`) return
  `BAD_ARGS` and leave the engine in `Idle`.

### What still doesn't work after Phase 3A

- No actual capture — no frames, no audio, no MP4 file. Phases 3B–3D.
- No workflow events on `workflow/events` (`recordingStarted` /
  `recordingFinalized` / `recordingFailed`). Phase 3E.
- The Flutter UI will hang in "starting" after a successful
  `startRecording` because it waits for the `recordingStarted` event the
  engine has not learned to emit yet. This is expected and is the
  motivating reason 3E lands before the slice is declared "done".

## Current status — Phase 2

Phase 0 stood up the bridge scaffolding (a catch-all method handler plus
no-op event-channel stubs) so the app could boot without throwing
`MissingPluginException` at startup.

Phase 1 — **full bridge contract parity** — replaces that catch-all with a
per-method router. Every method on the Dart bridge contract has an explicit
handler that returns a shape-correct stub. The Flutter UI can now walk
through its full startup sequence (settings hydration, permissions probe,
device enumeration, post-processing prefs) without the bridge surfacing a
wall of errors.

Phase 2 — **real device / target discovery** — replaces the empty-list
stubs for the four discovery getters with live OS enumerations under
`windows/runner/Bridge/Devices/`:

| Getter             | Backed by                                              |
| ------------------ | ------------------------------------------------------ |
| `getDisplays`      | `EnumDisplayMonitors` + `GetMonitorInfoW` + `GetDpiForMonitor` |
| `getAppWindows`    | `EnumWindows` filtered by visibility / cloak / tool-window / extended-frame bounds, plus `QueryFullProcessImageNameW` for the app name |
| `getAudioSources`  | WASAPI `IMMDeviceEnumerator::EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE)` + `PKEY_Device_FriendlyName` |
| `getVideoSources`  | Media Foundation `MFEnumDeviceSources(VIDCAP)` reading the symbolic-link id and friendly-name attributes |

The picker UI now lists real monitors, app windows, microphones, and
cameras. Setters (`setDisplay`, `setAudioSource`, etc.) are still no-op
success — the recording engine that consumes those selections lands in
Phase 3. Device-change notifications (audio / video source hot-plug events
on the `screen_recorder/events` channel) also land in Phase 3 alongside
the recording lifecycle.

### Layout

```
windows/runner/Bridge/
  method_dispatcher.{h,cpp}      table-based dispatch; unknown method →
                                 WINDOWS_NOT_IMPLEMENTED
  result_helpers.h               small reply helpers
  native_channel_names.h         channel name constants
  native_error_codes.h           error code constants
  event_channel_stubs.{h,cpp}    no-op event channels

  Devices/                       Phase 2 device enumerators
    device_record.{h,cpp}        plain-data records + `ToEncodable` helpers
                                 (pure formatters, unit-tested in isolation)
    display_enumerator.{h,cpp}   EnumDisplayMonitors → DisplayRecord
    window_enumerator.{h,cpp}    EnumWindows → AppWindowRecord, with the
                                 visibility / cloak / tool-window filters
    audio_source_enumerator.{h,cpp}
                                 WASAPI capture endpoints → AudioSourceRecord
    video_source_enumerator.{h,cpp}
                                 Media Foundation video capture devices →
                                 VideoSourceRecord

  Routers/
    recording_router.{h,cpp}     startRecording, lifecycle, capabilities,
                                 recording settings
    devices_router.{h,cpp}       getDisplays / getAppWindows / get*Sources
                                 (Phase 2 real), selection setters, area
                                 selection
    camera_overlay_router.{h,cpp} all setCameraOverlay*, chroma key,
                                 cursor highlight
    indicator_router.{h,cpp}     recording indicator + pre-recording bar
    preview_router.{h,cpp}       preview/player/zoom queries + setters
    export_router.{h,cpp}        exportVideo, processVideo, scene info,
                                 zoom segment store
    permissions_router.{h,cpp}   permission status/requests, open settings,
                                 relaunchApp
    storage_router.{h,cpp}       save folder, reveal helpers,
                                 storage snapshot, clear cache
    misc_router.{h,cpp}          pickImage, cacheLocalizedStrings,
                                 checkForUpdates
```

### Stub-response policy

| Category | Behavior |
|---|---|
| Setters and fire-and-forget actions | `result.Success(null)` |
| Getters returning a list | `[]` |
| Getters returning a map / model | shape-correct empty (zero-filled `StorageSnapshot`, `{canPauseResume:false}`, etc.) |
| Boolean getters | `false` (Dart parsers treat this as "feature off" / "not granted") |
| `previewGetZoomCapabilities` | all-`false` so the smart fixed-target UX hides |
| `previewGetCursorSamples` | empty samples + zero dimensions |
| `getRecordingSceneInfo` | echo `projectPath` as both `projectPath` and `screenPath` (matches Dart's own fallback) |
| `clearCachedRecordings` | `{deletedCount: 0}` |
| `startRecording`, `stopRecording`, `exportVideo`, `processVideo` | `WINDOWS_NOT_IMPLEMENTED` error so the user gets a clean "not on Windows yet" message |
| Unknown / unrouted methods | `WINDOWS_NOT_IMPLEMENTED` — keeps bridge drift visible |

### What works after Phase 2

- `flutter run -d windows --dart-define-from-file=.env.dev` launches the
  app.
- Home shell, settings, post-processing, permissions onboarding, and
  licensing UI all render under fluent_ui without surfacing a wall of
  bridge errors.
- The display, window, microphone, and camera pickers list real devices
  from the host machine. Selecting any of them round-trips through the
  no-op setters cleanly — Phase 3 picks up the selection state.
- Pre-recording flows (selecting a quality preset, toggling the recorder
  exclusion, opening the camera overlay settings) round-trip cleanly.
- Hitting **Record** or **Export** surfaces a clean
  `WINDOWS_NOT_IMPLEMENTED` error rather than crashing.

### What does not work yet

- No actual recording, preview, or export. Those land in Phases 3–6.
- No device hot-plug notifications: plugging in a new mic / camera does
  not refresh the picker until the user re-opens it. Audio (WASAPI
  `IMMNotificationClient`) and video (WM_DEVICECHANGE) notifications
  arrive alongside the recording engine in Phase 3.
- Permission resolution still returns "not granted". Phase 10.
- File reveal / "open folder" actions accept the call but do nothing — a
  real ShellExecute pass arrives in Phase 10.

## Building and running on Windows

Prereqs (one-time on the Windows machine):

```powershell
# Enable the Windows desktop target for this Flutter install.
flutter config --enable-windows-desktop

# Verify the Windows toolchain is set up (Visual Studio 2022 with
# "Desktop development with C++").
flutter doctor -v
```

Run the app:

```powershell
flutter pub get

flutter run -d windows --dart-define-from-file=.env.dev
```

Build a release exe:

```powershell
flutter build windows --dart-define-from-file=.env.dev
flutter build windows --dart-define-from-file=.env.prod
```

> `flutter build windows` does not accept `--flavor` — Windows builds are
> distinguished only by which dotenv is passed via `--dart-define-from-file`.
> Per-flavor installers (bundle id, app name, icon) land in Phase 10.

## Native Windows test layout

Tests live under `windows/runner_tests/` and use **GoogleTest**, fetched on
demand via CMake `FetchContent`. They mirror what `macos/RunnerTests/` does
for the Swift engine — exercise the bridge code without spinning up the
Flutter engine.

### What the tests cover

| File | What it asserts |
|---|---|
| `method_router_test.cpp` | Unknown methods fall back to `WINDOWS_NOT_IMPLEMENTED`; `HasHandler` reflects registration state. |
| `bridge_contract_coverage_test.cpp` | Every method on the Dart bridge contract has an explicit registered handler — the drift-detection net. Update the list here when you add a method to either side. |
| `router_stub_shapes_test.cpp` | Per-method stub shapes: setters return success+null, getters return the documented list/map/bool/null, `startRecording` / `stopRecording` return `WINDOWS_NOT_IMPLEMENTED` in the stub router; the live Phase 6 `exportVideo` / `processVideo` handlers surface their documented shapes (input-missing error vs null preview). `getStorageSnapshot` carries all ten required keys, etc. The Phase 2 `DeviceListGettersReturnList` case checks `getDisplays` / `getAppWindows` / `getAudioSources` / `getVideoSources` shape (list-of-maps with the documented keys) without assuming any particular count. |
| `device_record_test.cpp` | Pure formatters that translate the Phase 2 `DisplayRecord` / `AppWindowRecord` / `AudioSourceRecord` / `VideoSourceRecord` structs into the EncodableMap shape Dart parses. Bounds-omission for incomplete `AppWindowRecord`, int64 widths for ids, double widths for coordinates. |
| `export_geometry_test.cpp` | Phase 6 Slice 2 resolution/layout/fit math: `ResolveTargetSize` (ported 1:1 from macOS `ExportPrepTests.swift`), `ToEvenPixelSize` (H.264 even-dimension rounding), `ComputeContentRect` (fit/fill scale + centering), `ParseFitMode`, and the `IsIdentityTransform` copy fast-path gate. Pure math, no GPU. |
| `export_audio_test.cpp` | Phase 6 Slice 4 audio math: `RequiresAudioProcessing` gate (volume `!= 100`, not `!= 0`), `ResolveAudioGainStages` (amplify-only gain dB→linear, attenuate-only volume %, peak-normalize toward target), and the two-stage `ApplyAudioGain` with intermediate int16 clamp + truncate-toward-zero (matches macOS `Int16()`). Pure, no GPU. |
| `export_format_test.cpp` | Phase 6 Slice 5A/5B pure format/bitrate resolution: `ResolveExportExtension` (`mp4`→`.mp4`, `gif`→`.gif`, else `.mov`), `FormatWasDowngraded` (always false — Windows emits all three natively), and `ResolveVideoBitrateBps` (resolution-aware preset → H.264 bps, clamped). |
| `gif_export_policy_test.cpp` | Phase 6 Slice 5B GIF sampling/timing: grid-anchored `ShouldKeepGifFrame` / `AdvanceGifEmitTarget` decimation to ~15 fps (incl. a jittered-timestamp regression case), `GifDelayCentiseconds` rounding + 2cs floor + 16-bit ceiling, and `IsGifDestination`. Pure, no GPU. |
| `export_session_test.cpp` | Phase 6 Slice 5A export reentrancy/cancel singleton: `BeginExport` rejects a concurrent export and clears a stale cancel flag; `RequestCancel` / `IsCancelled`; a cancelled export does not pre-cancel the next one. |
| `export_progress_publisher_test.cpp` | Phase 6 Slice 5A reverse-channel progress: `EmitProgress` is a safe no-op when no method channel is attached (the export worker can outlive teardown), guarding a late tick from dereferencing a freed channel. |
| `export_passthrough_test.cpp` | Phase 6 Slices 1–5B routing: `ResolveExportDestination` extension/sanitization/collision rules (`.mov`/`.mp4`/`.gif`), the copy-vs-re-encode gate (mov auto/auto byte-copies; mp4 and gif force composition), the input-missing / default-save-folder / cancel-before-work paths. Filesystem-touching, no GPU. |
| `export_pipeline_test.cpp` | Phase 6 Slices 2–5B heavy round-trip: synthesizes a tiny source `.mov` with the real encoder, runs `RenderComposedExport`, and re-opens the output to assert dimensions, audio carry-through (and gain/volume/normalize level deltas), the `.mp4` container, monotonic progress→1.0, and the GIF path (WIC-probed real `.gif`, audio dropped, frame decimation, cancel removes the partial file). `GTEST_SKIP`s when no GPU / MF encoder is available — visual correctness (orientation, color, dither) stays a human smoke-test. |

### Why a separate static library

`windows/runner/CMakeLists.txt` builds the bridge sources into a
`runner_bridge` STATIC library. The runner executable links against it,
and so does the test executable — no source duplication, no test-only
includes of `flutter_window.cpp`, and the test binary never needs a live
Flutter engine.

### Running the tests

`flutter build windows` does **not** enable the test target (it would
otherwise pay the GoogleTest FetchContent cost on every app build). Tests
are an opt-in CMake build:

```powershell
# One-time configure (downloads GoogleTest on first run).
cmake -S windows -B build/windows-tests -DBUILD_RUNNER_TESTS=ON `
  -DFLUTTER_VERSION="3.44.0" `
  -DFLUTTER_VERSION_MAJOR=3 -DFLUTTER_VERSION_MINOR=44 `
  -DFLUTTER_VERSION_PATCH=0 -DFLUTTER_VERSION_BUILD=0

# Build the test binary.
cmake --build build/windows-tests --config Debug --target runner_tests

# Run everything.
ctest --test-dir build/windows-tests --output-on-failure -C Debug

# Run a single test by name.
ctest --test-dir build/windows-tests --output-on-failure -C Debug `
  -R "MethodRouterTest.UnknownMethodFallsBackToWindowsNotImplemented"
```

> The configure step requires a Windows-host CMake and that `flutter build
> windows` has run at least once (so `windows/flutter/ephemeral/` is
> populated). The flutter version `-D` values do not need to be exact —
> they just satisfy the runner's `target_compile_definitions` for the
> bundled version metadata.

## Validation before committing Windows changes

For changes that touch Dart code:

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze test
flutter analyze lib
flutter test
```

For changes to `windows/runner/`, build the Windows target on a Windows host
(macOS CI cannot build the Windows runner) and run the native tests:

```powershell
flutter build windows --dart-define-from-file=.env.dev
ctest --test-dir build/windows-tests --output-on-failure -C Debug
```

Windows-side native tests will land alongside the engine in Phase 3+. Until
then, manual verification on a real Windows box is the bar.

## Risks to watch

- Trying to port camera overlay before basic recording is stable.
- Scattering raw Media Foundation calls instead of wrapping them.
- Audio/video sync — log timestamps from day one.
- Assuming macOS TCC semantics; Windows uses per-device privacy settings.
- Overengineering toward full parity instead of shipping an MVP first.
