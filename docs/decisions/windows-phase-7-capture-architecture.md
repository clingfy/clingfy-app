# Windows Phase 7 — window + area recording: architecture & inventory

Status: **Phase 7.0 design — locked. No production capture code yet.**
Audience: whoever implements slices 7.1–7.4.
Companion: [../windows-port.md](../windows-port.md) (roadmap), and the
slice-by-slice rhythm used for Phase 6 export.

Phase 6 gave Windows the full **record → preview → export** loop, but recording
is still **full-display only**. Phase 7 adds the next user-visible parity gap:
**capture targeting** — record a single window, or a dragged-out screen area.
This doc maps the macOS reference behavior and the current Windows stack, locks
the Windows architecture, and splits the work into PR-sized slices with
acceptance tests. It does not change code.

---

## 1. macOS reference behavior (the parity contract)

macOS drives all targeting through one ScreenCaptureKit backend. The pieces a
Windows port must match (or deliberately diverge from):

| Concern | macOS behavior | Anchor |
|---|---|---|
| Modes | `DisplayTargetMode` enum, raw 0–5: `explicitId`, `appWindow`, `singleAppWindow`, `areaRecording`, `mouseAtStart`, `followMouse`. Crosses the bridge by index and is persisted. | `macos/Runner/Core/Models.swift:4` |
| Target struct | `CaptureTarget{mode, displayID, cropRect?, windowID?}`. Only `singleAppWindow` carries a `windowID`; only `areaRecording` (and the window-hybrid path) carries a `cropRect`. | `CaptureTargetResolver.swift:40` |
| Window capture | True single-window capture via `SCContentFilter(desktopIndependentWindow:)` resolved from a `CGWindowID`; `sourceRect=nil`. A display+crop "hybrid" is used *only* to preserve a live camera overlay. | `CaptureBackendScreenCaptureKit.swift:1751`, `:1728` |
| Area capture | **Full-display** `SCContentFilter(display:excludingWindows:)` with `SCStreamConfiguration.sourceRect` = the chosen rect. A cropped display capture — **not** a per-rectangle API. | `…ScreenCaptureKit.swift:1779` |
| Cursor | **Always stripped** from the video (`showsCursor = false`) and re-captured into a custom 60 Hz JSON sidecar (`<video>.cursor.json`). | `…ScreenCaptureKit.swift:1840`, `Cursor/CursorRecorder.swift:95` |
| Window picker | A flat **list popover** (app + title), not click-a-window. Source: `CGWindowListCopyWindowInfo`. | `PreRecordingBarController.swift:236`, `DisplayService.swift:43` |
| Area picker | Per-display **borderless `.screenSaver`-level NSWindow**, drag-rect crosshair, Escape cancels, min 5×5 px. Returns `{displayId,x,y,width,height}` (display-local, top-left). | `Overlays/AreaSelection/AreaSelectionOverlay.swift:48`, `ScreenRecorderFacade.swift:1142` |
| Manifest | `ScreenCaptureInfo{displayMode, displayId, windowId?, cropRect?, frameRate, quality, cursorEnabled, …}`. `windowId` only written for `singleAppWindow`. | `Core/RecordingMetadata.swift:41` |
| Target-loss | **Minimal.** A 0.2 s timer polls the window's bounds and updates `sourceRect` (move-follow). Window close/minimize and display reconfig just surface a generic `didStopWithError`. No monitor-reconfig observer exists. | `…ScreenCaptureKit.swift:586`, `:2339` |

**Takeaway:** the mode vocabulary, the bridge methods, and the Dart UI already
assume window + area. macOS's target-loss story is weak, so Windows is free to
do *better* there without breaking parity.

---

## 2. Windows current state (what exists, what's a no-op)

The whole capture path is hard-wired to a monitor:

- **Backend** — `WgcDisplayCaptureBackend` is concrete (no abstract base). Its
  only entry is `Start(HMONITOR, D3DDevice&, VideoFrameQueue&)`; the WGC item is
  created exclusively via `IGraphicsCaptureItemInterop::CreateForMonitor`
  (`wgc_display_capture_backend.cpp:140`). The frame pool is **free-threaded**.
  Each `FrameArrived` extracts the `ID3D11Texture2D` and does a full-surface
  `CopyResource` into an engine-owned staging texture
  (`CopyIntoStagingTexture`, `:196`), then pushes a `CapturedVideoFrame`
  (texture + dims + timestamp) onto the queue. The encoder wraps the texture with
  **no crop/resize** (`mf_sink_writer_encoder.cpp:296`).
- **Engine gate** — `RecordingEngine::Start` **hard-rejects every mode except
  `kExplicitId`** with a `kBadMode` error (`recording_engine.cpp:98`), resolves
  an `HMONITOR` via `ResolveHMonitor(display_id)` (`:108`), and sizes the encoder
  to the **monitor** rect via `GetMonitorInfoW` (`:134`).
- **Selection state** — `WindowsSelectionState` holds only `display_id`,
  `target_mode`, `microphone_id`. The `DisplayTargetMode` enum already has all
  six values; there is **no window-HWND field and no area-rect field**
  (`windows_selection_state.h:27`, `:71`).
- **Routers** — `setDisplay` / `setDisplayTargetMode` are honored;
  `setAppWindowTarget` and the three area methods
  (`pickAreaRecordingRegion` / `revealAreaRecordingRegion` /
  `clearAreaRecordingSelection`) are **no-ops** (`devices_router.cpp:168`, `:178`).
- **Window enumeration** — `window_enumerator.cpp:144` already encodes the
  **HWND as `window_id`** (`reinterpret_cast<uintptr_t>`) plus DWM extended-frame
  bounds, `displayId`, `pid`, `title`, `app_name`. The picker input set exists.
- **Manifest** — `project.json` (schemaVersion 2) and `screen.meta.json` record
  **no** `targetType` / `sourceBounds` (`recording_project_writer.cpp:137`,
  `:169`). The reader ignores unknown keys, so adding fields is backward-compatible.
- **Dart** — **already fully wired.** `DeviceController` persists
  `selectedAppWindowId` and pushes it via `setAppWindowTarget`
  (`device_controller.dart:352`); `pickAreaRecordingRegion` expects a
  `{displayId,x,y,width,height}` map (`overlay_controller.dart:774`);
  `nativeSelectionChanged` / `areaSelectionCleared` callbacks are defined and
  dispatched but **Windows never fires them**. The `DisplayTargetMode` enum is
  aligned (`app_models.dart:688`).
- **Overlay infra** — **none.** No `WS_EX_LAYERED` / `WS_EX_TRANSPARENT` /
  topmost / `UpdateLayeredWindow` anywhere in `windows/runner`. The only Win32
  windows are the Flutter host (`win32_window.cpp`) and two message-only windows.
  A native area picker must be built from scratch (those files are the WndProc
  reference).

**Takeaway:** Phase 7 is mostly **making existing no-ops real and lifting one
gate** — not new bridge surface. The genuinely new build is the native picker
overlay (7.3).

---

## 3. Locked architecture decisions

**D1 — Backend shape: extend, don't abstract.** Add a small `CaptureTarget`
struct `{ kind: kDisplay|kWindow|kArea; HMONITOR monitor; HWND window;
RECT crop_px /*physical, area only*/ }` and a single
`Start(const CaptureTarget&, D3DDevice&, VideoFrameQueue&)` on the **existing**
`WgcDisplayCaptureBackend`. Pause/Resume/Stop/Stats/teardown are identical across
kinds, so an abstract base adds surface area without payoff. Revisit only if a
fundamentally different mechanism (DXGI duplication) is ever added.

**D2 — Window capture (7.1): WGC `CreateForWindow(HWND)`.** The direct analog of
`SCContentFilter(desktopIndependentWindow:)`. Reuses the free-threaded pool,
`FrameArrived` copy, and encoder drain unchanged (the item is already the right
size). Add `ResolveHWnd(window_id)` next to `ResolveHMonitor`, validating
`IsWindow()` (and visibility) **at Start** — never trust a stale HWND. Encoder
dimensions come from `GraphicsCaptureItem.Size()`, not the monitor.

**D3 — `kAppWindow` and `kSingleAppWindow` both map to single-HWND capture for
MVP.** macOS distinguishes "app (all windows)" from "single window"; WGC
`CreateForWindow` captures exactly one HWND. For the MVP, treat both modes as
single-window capture of the selected HWND and document the divergence;
true multi-window/app capture is out of scope.

**D4 — Area capture (7.2): full-monitor WGC + crop.** Mirror macOS exactly:
capture the rect's `HMONITOR` (reuse `CreateForMonitor`) and crop in the frame
path with `ID3D11DeviceContext::CopySubresourceRegion` + a `D3D11_BOX` into an
**encoder-sized** staging texture (1:1, no scale — cheapest; the export
pipeline's D2D `DrawBitmap(srcRect,destRect)` is the fallback only if scaling is
later needed). Size the encoder to the **even-rounded crop rect**. No
per-rectangle WGC item exists; do not invent one.

**D5 — Coordinate transform is the #1 correctness risk → one tested helper.**
The app is PerMonitorV2 (`runner.exe.manifest`), so HMONITOR/window rects are
physical pixels. A single helper converts the picker's per-monitor logical drag
rect → physical capture pixels → `D3D11_BOX` crop on the full-display texture,
using the monitor's `rcMonitor` origin offset + `GetDpiForMonitor` scale (both
already surfaced by `display_enumerator.cpp:50`). Windows is top-left (no
bottom-left flip like macOS). Unit-test multi-monitor + non-100 % DPI cases.

**D6 — Area selection surface (7.3): native Win32 overlay, matching the
contract.** The Dart contract (`pickAreaRecordingRegion` → map; `areaSelectionCleared`
callback) already expects a **native** picker, so build one — a topmost,
layered/transparent, per-monitor window with a crosshair drag-rect, dimmed
outside + bright border, Escape-to-cancel, <5 px reject — returning
`{displayId,x,y,width,height}` exactly like `ScreenRecorderFacade.swift:1158`.
Model the WndProc/class-registrar on `win32_window.cpp`; marshal the modal result
back to the MethodChannel via `PostMessage` (mirror `platform_thread_dispatcher`),
never by blocking the platform thread. Tear the overlay down **before**
`StartCapture` (WGC has no per-window exclusion in the basic API).

**D7 — Cursor MVP policy: keep the WGC default (cursor in the video), made
explicit.** This is a deliberate **divergence** from macOS (which strips the
cursor + sidecar). Windows has no cursor sidecar until Phase 8; stripping now
would mean MVP recordings show *no* cursor at all — worse UX. Add an explicit
`session.IsCursorCaptureEnabled(true)` with a comment so the Phase 8 sidecar flip
is a single greppable change.

**D8 — Yellow capture border: best-effort disable, degrade silently.** Attempt
`GraphicsCaptureSession.IsBorderRequired = false` behind a runtime capability
check (`ApiInformation` / `GraphicsCaptureSession2`); leave the border on older
Win10. Document the min-OS. Acceptable to ship MVP with the border if the
capability is absent.

**D9 — Target-loss (7.4): add what macOS lacks. — IMPLEMENTED (7.4).** Subscribe
to `GraphicsCaptureItem.Closed` for **every** kind (it also fires when a captured
*monitor* is unplugged, so display + area + window are all covered by one
signal). The backend forwards the close to the engine
(`WgcDisplayCaptureBackend::SetTargetLostCallback`), marshaled onto the platform
thread via `PlatformThreadDispatcher`; the engine's `RecordingEngine::HandleTargetLost`
does a **clean stop + finalize**, re-validating the session under the mutex so it
is **exactly-once** vs. a racing user `Stop` (whoever wins resets the state; the
loser no-ops).

The original plan said emit `recordingFailed` and discard. The **shipped
behavior keeps the partial** (user decision, 2026-06-07): when at least one frame
was captured and the project writer succeeds, emit `recordingWarning` (friendly
"the window/display you were recording closed; your recording was saved") **then**
`recordingFinalized` so the app opens the partial into preview/export. Only when
nothing usable was captured (zero frames or a writer failure) does it fall back
to `recordingFailed` (`TARGET_ERROR`). This is strictly better UX than macOS,
which discards.

The Closed token is revoked in `Stop` with the same snapshot-under-lock /
revoke-outside-lock discipline as `FrameArrived` (revoking from the platform
thread, never from inside the Closed handler, so no deadlock).

**Window resize/DPI-change mid-recording: keep the initial size — IMPLEMENTED.**
The free-threaded frame pool is fixed-size (never `Recreate()`'d), and the
non-crop copy path now pins the staging texture to the even-clamped **initial**
capture size (`capture_w_/capture_h_`), so the encoder input dims never drift.
A window that grows is cropped to the original rect; one that shrinks below it
drops frames (the last good frame holds) — never a corrupt/mismatched frame.
Resize-follow remains out of MVP scope.

> Deferred from this slice (not in the 7.4 spec, low risk, separable): the
> best-effort yellow-border disable (D8) and a `WM_DISPLAYCHANGE`-driven
> *selection*-clear for a non-captured monitor (macOS's `screenParamsChanged`).
> The captured-target-loss case — what the spec asked for — is fully handled by
> `GraphicsCaptureItem.Closed`.

**D10 — Manifest: add `targetType` + `sourceBounds`, schemaVersion stays 2.**
Write `targetType` (`"display"|"window"|"area"`) and `sourceBounds`
`{x,y,width,height}` (plus `windowId` for window mode) into `screen.meta.json`;
read them back into `RecordingMetadata`. Backward-compatible (reader ignores
unknown keys). Confirm field names against the macOS `ScreenCaptureInfo` shape so
projects stay cross-platform-readable.

**D11 — Target transport: keep the setter + `WindowsSelectionState` pattern.**
Make `setAppWindowTarget` write the HWND into `WindowsSelectionState`, and add an
area-rect (+ area display id) field set by the picker. Re-validate at Start
(closes the small TOCTOU window). **No new bridge method is required** for the
common path; only the native picker (7.3) makes Windows *fire*
`nativeSelectionChanged` / `areaSelectionCleared`, which then need constants added
to `native_channel_names.h` + a contract-test entry.

---

## 4. Deliberate divergences from macOS (call them out in PRs)

1. **Cursor is burned into the MVP video** (D7) until the Phase 8 sidecar; macOS
   strips it. Flip at Phase 8.
2. **`kAppWindow` == single-window capture** on Windows MVP (D3); macOS captures
   all of an app's windows.
3. **Target-loss is handled** (D9); macOS just fails generically. Windows is
   strictly better here — it **keeps** the partial recording (warning +
   `recordingFinalized`) instead of discarding it.
4. **HWND is session-only** — do not persist a window selection across app
   restarts (a relaunched HWND is meaningless); drop/re-match `selectedAppWindowId`
   on launch.

---

## 5. Slice plan (PR-sized) + acceptance tests

Same gated rhythm as Phase 6: explore → implement → adversarial review → ship →
user smoke → next. GPU-touching tests follow the existing `D3DDevice::Create()`
`GTEST_SKIP` pattern.

### 7.1 — Window recording  (`feature/windows-phase-7-1-window-recording`)
Scope: `CaptureTarget` struct + `Start(CaptureTarget)` (D1); `CreateForWindow`
path (D2); `ResolveHWnd` + Start-time validation; real `setAppWindowTarget` →
`WindowsSelectionState`; lift the `kBadMode` gate for `kAppWindow`/`kSingleAppWindow`
(D3); encoder sized from item size; manifest `targetType:"window"` + `windowId`
(D10); explicit `IsCursorCaptureEnabled(true)` (D7). MP4/MOV display path
unchanged.
Acceptance:
- [ ] Recording a selected window produces an MP4 of that window's content at its size.
- [ ] A stale/closed HWND at Start fails with a structured target error (no crash, no empty file).
- [ ] Full-display recording is byte-for-byte unaffected.
- [ ] Tests: `windows_selection_state_test` (HWND field), `recording_engine_test` (window mode admitted; HWND-invalid failure path), manifest round-trip for `targetType:"window"`.

### 7.2 — Area recording  (`feature/windows-phase-7-2-area-recording`)
Scope: crop in `CopyIntoStagingTexture` via `CopySubresourceRegion`+`D3D11_BOX`
into an encoder-sized texture (D4); the coordinate-transform helper (D5); encoder
sized to even-rounded crop rect; area-rect field in `WindowsSelectionState`;
`kAreaRecording` admitted; manifest `targetType:"area"` + `sourceBounds`. Rect is
fed programmatically/persisted for this slice (picker UI is 7.3).
Acceptance:
- [ ] A given crop rect on a chosen display yields an MP4 of exactly that region (even dims).
- [ ] Coordinate-transform unit test passes for multi-monitor + 125 %/150 % DPI + non-primary-origin cases.
- [ ] Display + window paths unchanged.
- [ ] Tests: transform helper unit tests (pure, no GPU); `recording_engine_test` area sizing; manifest round-trip for `targetType:"area"`/`sourceBounds`.

### 7.3 — Area picker overlay  (`feature/windows-phase-7-3-area-picker`)
Scope: native per-monitor layered topmost crosshair overlay (D6); real
`pickAreaRecordingRegion` returning `{displayId,x,y,width,height}` / null on
cancel; `revealAreaRecordingRegion` border preview; `clearAreaRecordingSelection`;
Windows fires `nativeSelectionChanged` / `areaSelectionCleared` (+ constants in
`native_channel_names.h` + contract-test entry).
Acceptance:
- [ ] Drag-select on any monitor returns the correct logical rect; Escape returns null; <5 px rejected.
- [ ] The returned rect, fed to 7.2, records the intended region.
- [ ] Overlay is torn down before capture (not visible in the recording).
- [ ] Tests: `bridge_contract_coverage` + `router_stub_shapes` for the new reply shapes; any pure geometry split out and unit-tested.

### 7.4 — Target-loss + polish  (`feature/windows-phase-7-4-target-loss`)
Scope: `GraphicsCaptureItem.Closed` handler → clean stop+finalize + structured
error (D9); monitor-unplug handling for display/area; best-effort
`IsBorderRequired=false` (D8); confirm encoder/clock tolerate WGC idle-frame gaps
for small/static windows.
Acceptance:
- [ ] Closing the captured window mid-recording finalizes a playable partial MP4 and surfaces a "target lost" error (no deadlock).
- [ ] Unplugging the captured monitor stops cleanly with a clear error.
- [ ] Tests: a `Closed`-path teardown test asserting no deadlock (mirrors the Stop discipline).

---

## 6. Cross-cutting risks

- **Coordinate math** (D5) — highest correctness risk; gate it behind the tested helper.
- **WGC idle frames** — a static small window delivers no new frames; verify the encoder/`RecordingClock` already hold/duplicate the last frame (display mode tolerates it today; window/area amplify it).
- **DPI / even dimensions** — odd crop rects need the same `RoundUpToEven` the monitor path uses; a 1 px drift between the `D3D11_BOX` and encoder size corrupts the image.
- **Overlay threading** (D6) — must not block the platform message loop; `PostMessage` the result back.
- **HWND lifetime** (D11) — re-validate at Start; never persist across restarts.

## 7. Deferred (later phases, not Phase 7)

- Cursor sidecar + `IsCursorCaptureEnabled(false)` flip → **Phase 8**.
- True multi-window "app" capture (`kAppWindow` all-windows) → future.
- Window resize-follow / DPI-change-follow mid-recording → future.
- `mouseAtStart` / `followMouse` modes → remain `kBadMode` until scoped.
- Camera-overlay WGC exclusion (`SetWindowDisplayAffinity`) → **Phase 9**.

## 8. Key references

macOS: `Capture/Backends/CaptureBackendScreenCaptureKit.swift`,
`Capture/Targeting/CaptureTargetResolver.swift`,
`Overlays/AreaSelection/AreaSelectionOverlay.swift`, `Core/RecordingMetadata.swift`.
Windows: `Capture/wgc_display_capture_backend.cpp`, `Capture/recording_engine.cpp`,
`Capture/windows_selection_state.{h,cpp}`, `Bridge/Routers/devices_router.cpp`,
`Bridge/Devices/window_enumerator.cpp`, `Bridge/Devices/display_enumerator.cpp`,
`Capture/recording_project_writer.cpp`, `win32_window.cpp`.
Dart: `lib/core/devices/device_controller.dart`, `lib/app/home/overlay/overlay_controller.dart`,
`lib/core/models/app_models.dart`.
