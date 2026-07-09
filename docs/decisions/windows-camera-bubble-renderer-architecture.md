# Windows live camera bubble — renderer redesign (D3D/D2D core + DirectComposition presenter)

Status: **P0–P4 complete; DirectComposition is the default presenter** (updated 2026-07-09)
Supersedes the presentation layer of [windows-phase-9-camera-overlay-architecture.md](windows-phase-9-camera-overlay-architecture.md); the capture, exclusion-gating, and style-store decisions there remain in force.

## Status update (2026-07-09)

This document was written pre-implementation; P0–P4 have since landed on `develop`
exactly as designed, the P3 GO/NO-GO gate **passed**, and P4d flipped the default:

- **P0** — #220 (editorSeed persistence), #221 (geometry store + live position/size).
- **P1** — #224 (`83182be`): drag write-back + `cameraOverlayMoved` emitter + glow
  fields wired (not rendered). Review hardening: `AdoptDragRevision` guard so a drag
  write-back cannot swallow a concurrent platform-thread geometry mutation.
- **P2** — #225 (`8d2db36`): `ICameraOverlayPresenter` seam, byte-identical GDI
  presenter, factory + kill switch. Review hardening: env reads use Win32
  `GetEnvironmentVariableW` (the CRT snapshot is invisible to
  `SetEnvironmentVariableW`, which had made the kill switch untestable).
- **P3** — #226 (`f60dbd1`): DComp presenter POC. **GO verdict on the hybrid-GPU dev
  box**: renders on-screen AND absent from screen capture, with all presenter/POC
  tests passing armed (`CLINGFY_REQUIRE_PIXEL_TESTS=1`). Additions beyond the plan:
  `CLINGFY_TEST_DCOMP_WDA_FAIL` fault injection exercises the WDA-fail fallback
  ladder end-to-end without afflicted hardware; a failed swapchain resize leaves the
  geometry revision unconsumed (retry next tick) instead of stranding a target-less
  context.
- **Fallback hardening** — #230 (`3125130`): the mandatory GDI fallback's
  camera-then-border `Paint` was unbuffered, letting DWM compose borderless
  mid-paint frames (user-visible border flicker at streaming cadence, 12/180 screen
  samples); now double-buffered (0/181). Headless pixel tests
  (`camera_bubble_border_pixel_test.cpp`) pin the painter/DComp border paths per the
  §7 test strategy.
- **P4a** — #232 (`e084808`): effect-padding halo + click-through (window outsizes
  the content square by the painter's real bake extents; halo is `HTTRANSPARENT` +
  cursor-tracked `WS_EX_TRANSPARENT`, WDA re-verified after each flip).
- **P4b** — #233 (`ed83826`): the recording glow ring, presenter-drawn and live-only
  (macOS pulse math), baked per style/geometry change, never in the shared painter.
- **P4c** — device-lost rebuild (#234, retains the DComp tree and rebuilds only render
  resources), DPI self-detection (#235, the tick re-syncs on scale divergence — no
  `WM_DPICHANGED` dependency), mid-session GDI fallback (#236, `CameraOverlayHost`
  swaps DComp→GDI when the rebuild budget is spent; the never-show-unexcluded invariant
  is enforced atomically at the swap), and capture-display retarget (#237, the bubble
  lands on the recorded window's monitor).
- **P4d** — DirectComposition is now the **default** presenter; `CLINGFY_FORCE_GDI_OVERLAY`
  stays the kill switch and the retired `CLINGFY_OVERLAY_DCOMP` opt-in is gone. Because
  the ADR's hardware-matrix gate (NVIDIA/AMD) never ran, `Start` runs a one-time **render
  self-check**: it rasterizes a known opaque probe, reads the swapchain back buffer
  straight back (a direct GPU-resource copy — WDA does not blind it, so it works in
  production unlike the on-screen probe), and falls the factory back to the GDI bubble if
  the adapter produced no pixels. This closes the in-process subset of the hybrid-GPU
  "renders nothing" scar on any adapter without waiting on the matrix (a pure DWM-
  composition drop remains observable only through the armed on-screen probe). The
  resolved presenter is logged once per recording (`active = dcomp` / `gdi`). Fault
  injection: `CLINGFY_TEST_DCOMP_RENDER_NOTHING` drives the fallback rung in tests.

## 1. Problem

The live floating camera bubble is an **opaque** Win32 `WS_POPUP` window painted with
GDI (`windows/runner/Capture/Camera/camera_floating_overlay.cpp`). Opaque means no
per-pixel alpha, so live parity with macOS stops at: shape, roundness, mirror, border,
and (since the geometry store landed) position + size. **Opacity, shadow, glow-when-
recording, and chroma key cannot render live** — they appear only in exports and the
post-record preview, where the shared `CameraBubblePainter` (Direct2D) draws them.

macOS renders all of these live: the bubble is a square, transparent `NSPanel` with a
CALayer stack (mask, border, shadow, pulsing glow ring, CoreImage chroma), excluded
from capture via the ScreenCaptureKit excluded-windows list
(`macos/Runner/Overlays/Camera/CameraOverlay.swift`).

## 2. Decision

> **Keep `CameraBubblePainter` as the one effects core. Replace only the
> presentation: a DirectComposition presenter (`WS_EX_NOREDIRECTIONBITMAP` window +
> premultiplied-alpha composition swapchain + D2D) behind a presenter abstraction,
> with the current opaque GDI window retained as a mandatory runtime fallback.**

Explicitly rejected:

- **Building a new "Direct3D camera renderer"** — the effects engine already exists.
  `CameraBubblePainter` renders mask/mirror/opacity/border/baked-shadow/chroma for
  export (`camera_export_renderer.cpp`) and the post-record preview
  (`preview_camera_renderer.cpp`), is proven per-frame realtime (30–60 fps inside the
  preview engine's frame callback), and is pure 8-bit premultiplied BGRA — directly
  compatible with a composition swapchain. A second engine would duplicate it and
  break WYSIWYG-by-construction (same painter ⇒ live == export). This mirrors the
  color-grade precedent: one shared `ColorGradeEffectChain` for preview + export.
- **`UpdateLayeredWindow` (layered windows) as the long-term path** — per-pixel-alpha
  layered windows are the documented failure class on hybrid GPUs (Godot #76167:
  composite-alpha renders opaque black on Optimus; assorted Electron reports), have
  known capture-exclusion leaks (robmikh/Win32CaptureSample #51: WGC still captures a
  layered semitransparent window), and forfeit `SetWindowRgn`/`WM_PAINT` semantics
  (PowerToys ZoomIt source comments). Acceptable POC tech; wrong foundation.
- **`Microsoft.UI.Composition` / Windows App SDK** — pulls a framework dependency into
  a Flutter+Win32 app to render one native overlay. Raw DirectComposition is a
  Win32-native API and is exactly what first-party tools use (below). Revisit only if
  the Windows shell ever adopts WinUI 3.

## 3. Evidence (verified 2026-07-07)

**The proposed stack is shipping, first-party practice.** PowerToys **MeasureTool**
uses this exact combination: `CreateWindowExW(WS_EX_NOREDIRECTIONBITMAP |
WS_EX_TOOLWINDOW, ...)` → `DCompositionCreateDevice` → `CreateTargetForHwnd` →
`visual->SetContent(swapchain)` with `CreateSwapChainForComposition(B8G8R8A8_UNORM,
FLIP_SEQUENTIAL, DXGI_SCALING_STRETCH, DXGI_ALPHA_MODE_PREMULTIPLIED, 2 buffers)` and
D2D drawing the content — then `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)`
(`src/modules/MeasureTool/MeasureToolCore/OverlayUI.cpp`, `DxgiAPI.cpp`). PowerToys
**ZoomIt** ships a capture-excluded floating **webcam preview bubble** — our exact
product shape — albeit on the fragile layered-window path. Electron's
`setContentProtection(true)` applies the same affinity to DComp-presented Chromium
windows at large scale.

**Capture exclusion is best-effort, not guaranteed — the fallback is mandatory.**
Adversarial review surfaced a documented, unresolved Windows 11 defect: on a subset of
machines `SetWindowDisplayAffinity` fails outright (`ERROR_NOT_ENOUGH_MEMORY`, bug in
`ChangeWindowTreeProtection` in win32kfull.sys) — and the failures cluster on
**DirectComposition-presented** processes (Chrome/Edge/Teams fail; plain GDI apps
succeed). On exactly those machines our GDI window is likelier to get affinity than
the DComp window. Microsoft's own docs say affinity works "only when DWM is composing
the desktop" and offers "no guarantee". Consequences baked into this design:

1. The existing invariant stands: **never Show a floating bubble whose affinity call
   did not succeed** (`camera_floating_overlay.h` — `wda_excluded()` gate).
2. Presenter selection is a **runtime probe**, not a static choice (§5).
3. Never set `DXGI_SWAP_CHAIN_FLAG_HW_PROTECTED` (separate 24H2 capture-black
   regression), never toggle window styles after creation, and re-verify affinity
   (`GetWindowDisplayAffinity`) after any unavoidable window mutation (Electron
   #47834 regression lesson).

**Hybrid GPUs favor DComp over layered.** The DComp path has no
`UpdateLayeredWindow` staging bitmap and no driver composite-alpha involvement — DWM
composites the premultiplied flip-model buffer on whichever adapter owns the display.
No credible report of a premultiplied composition swapchain rendering nothing on
Optimus was found, while the layered path has several. Engineering obligations:
create the D3D device on the **default adapter**, handle
`DXGI_ERROR_DEVICE_REMOVED/RESET` by rebuilding, and treat repeated device loss as a
fallback trigger.

## 4. Architecture

```text
CameraRecorder (capture thread, ~15fps, ≤384px tightly-packed BGRA, REUSED buffer)
      │  on_preview_frame — must copy, must not block (camera_recorder.h:69-76)
      ▼
frame mailbox (mutex + dirty flag — existing pattern)
                                          CameraOverlayStyleStore ──┐ (+ glow fields)
                                          CameraOverlayGeometryStore┤ revision-based
      ▼                                                             ▼
ICameraOverlayPresenter        (owned by the overlay thread + message pump — unchanged model)
  ├── DCompPresenter (new, premium)
  │     WS_EX_NOREDIRECTIONBITMAP | TOPMOST | TOOLWINDOW | NOACTIVATE window
  │     own D3D11 device (BGRA_SUPPORT, default adapter) + D2D device context
  │     CreateSwapChainForComposition(B8G8R8A8, FLIP_SEQUENTIAL, STRETCH,
  │                                   PREMULTIPLIED, 2) — explicit pixel sizes
  │     DComp device → target(hwnd) → visual → SetContent(swapchain) → Commit once
  │     per frame: CopyFromMemory upload → Clear(transparent) →
  │                CameraBubblePainter::Draw → glow ring (host-drawn) → Present
  │     per style change: painter Prepare OUTSIDE BeginDraw, re-bind target after
  │                       (shadow bake does SetTarget round-trips — preview_engine
  │                        already models this at preview_engine.cpp:985-999)
  └── GdiOpaquePresenter (current camera_floating_overlay code, byte-identical
        behavior — safe-mode fallback, kill-switch selectable)
```

Key semantic decisions:

- **Square window, like macOS.** The macOS bubble window is a square of side
  `size + 2*effectPadding`; the painter's `Prepare` assumes a square bubble
  (`camera_bubble_painter.cpp:132` — "// square bubble"). The current 16:9 Windows
  window is the deviation, and it is what forces the compact-shape inscribed-square
  workaround. The DComp presenter adopts the square model: painter unmodified,
  roundedRect/squircle become rounded **squares** (true macOS parity — the current
  full-window 16:9 silhouettes diverge from the Mac look). The GDI fallback keeps its
  current 16:9 geometry until retired.
- **Effect padding + click-through halo.** The window outsizes the video content to
  fit border/shadow/glow (macOS: `lineWidth + 2*shadowRadius + 6`). `WM_NCHITTEST`
  returns `HTCAPTION` over the content rect and `HTTRANSPARENT` over the halo so
  clicks pass through to windows beneath (macOS `hitTest` parity).
- **Glow is presenter-drawn, not painter-drawn.** On macOS the recording glow ring is
  the ONE style that exists only live — zero references in the export pipeline. So it
  must NOT enter the shared painter (which would leak it into exports). The presenter
  draws it: red stroke + blurred halo scaled by strength (macOS: lineWidth=3+7s,
  shadowRadius=6+20s, alpha 0.60+0.40s), opacity-pulsed on the existing ~30fps tick
  (period 0.95−0.35s seconds, autoreversing). Store: add `glow_enabled` /
  `glow_strength` (0.10..1.00) to `CameraOverlayStyleStore`; wire the two no-op
  handlers `setCameraOverlayHighlight{enabled}` / `setCameraOverlayHighlightStrength
  {strength}`. Dart already gates enabled = pref AND recording AND camera-on.
- **Drag write-back (fixes a live bug).** macOS reports drags to Dart as
  `cameraOverlayMoved {normalizedX, normalizedY}` (ScreenRecorderEventBridge);
  Windows has no emitter, so an OS drag is invisible to the geometry store and to
  Dart — the next store revision (e.g. moving the size slider) teleports the bubble
  back. Fix at the store level, presenter-independent: on drag end
  (`WM_EXITSIZEMOVE`), compute the normalized work-area center →
  `CameraOverlayGeometryStore::SetCustomPosition` (suppressing the self-echo) + emit
  `cameraOverlayMoved` to Dart via the platform-thread dispatcher (pattern:
  `export_progress_publisher.cpp`).
- **Painter obligations for the new host** (all already modeled by existing hosts):
  context-affine, no internal locking → mutex+dirty+snapshot wrapper per
  `preview_camera_renderer.h:108-111`; `Prepare` outside `BeginDraw` + target re-bind;
  device-lost recovery = rebuild device/context/swapchain/bitmaps + re-`Prepare`
  (painter `Reset()`s its COM resources cleanly on re-Prepare).
- **Shape gaps stay documented, painter change optional.** The painter lacks
  hexagon/star geometry (falls back squircle/circle) — a pre-existing export parity
  gap. Adding polygon geometries to `CreateShapeGeometry` would fix live + preview +
  export in one change, fenced behind the enhanced path with the static fast path
  kept byte-identical (the chroma/animation fencing precedent,
  `camera_bubble_painter.cpp:313-318`). Scheduled last; not a gate.

## 5. Presenter selection policy

```text
Start(placement):
  if kill-switch (env CLINGFY_FORCE_GDI_OVERLAY or pref) → GDI
  try DCompPresenter:
    create window → D3D device → swapchain → DComp commit
    SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)   // can FAIL (Win11 bug, §3)
    all succeeded → use DComp (log "overlay presenter: dcomp")
  any failure → destroy, try GdiOpaquePresenter (same window class as today):
    WDA succeeded → use GDI (log "overlay presenter: gdi (<reason>)")
  WDA failed on BOTH → no floating bubble (existing rule), in-app texture only
Runtime:
  DXGI_ERROR_DEVICE_REMOVED/RESET → rebuild once; repeated loss → swap to GDI
  presenter mid-recording (Hide → swap → Show; stores are the state, nothing lost)
```

Every selection and fallback logs to `device_probe.log`, and the active presenter is
reported once per recording for beta telemetry.

## 6. Phasing

| Phase | Scope | Gate |
|---|---|---|
| **P0** ✅ | Geometry store + live position/size (PR #221); editorSeed persistence (PR #220) | merged stack |
| **P1** ✅ | Drag write-back + `cameraOverlayMoved` emitter; glow fields in style store + wire the two no-op handlers (GDI presenter ignores glow) | merged as #224 (`83182be`); drag→slider no longer teleports |
| **P2** ✅ | Extract `ICameraOverlayPresenter`; `GdiOpaquePresenter` = current behavior byte-identical; selection scaffolding, kill switch, logging | merged as #225 (`8d2db36`); full suite green |
| **P3** ✅ | `DCompPresenter` POC behind the kill switch: square window, frame upload, painter mask + opacity + border, WDA probe | merged as #226 (`f60dbd1`); **GO** on the hybrid-GPU dev box: renders on-screen AND absent from screen capture, armed probes green |
| **P4** ✅ | Full presenter: shadow, chroma (a/b, #232–#237), glow ring + pulse, effect padding + click-through halo, DPI self-detection, capture-display retarget, device-lost rebuild + mid-session fallback, **default flip to DComp** guarded by the render self-check | headless D2D pixel tests + armed on-screen probes green; the hardware-matrix gate is replaced for the flip by the start-time render self-check (§2, P4d) |
| **P5** (backlog) | Hexagon/star geometry in the painter (fixes export gap too); styled in-app texture (Dart bubble already styles everything but chroma — low urgency) | — |

P0–P4 are merged (see the status update above); P5 is backlog.

## 7. Test strategy

- **Pure logic**: presenter-selection policy, effect-padding math, glow scaling,
  normalized drag round-trip — plain gtest, no device.
- **Pixel**: presenter draw path exercised headlessly via the `HeadlessD2D` pattern
  (windowless D3D+D2D, staging-texture readback) — opacity/shadow/chroma/glow
  asserted against known inputs, same as the color-grade preview tests.
- **Exclusion**: manual/scripted probe on real hardware — show overlay over a color
  field, record via WGC, assert the bubble pixels are absent. Not automatable in CI
  (CI is macOS-only); runs on the dev box per the pixel-canary convention
  (`CLINGFY_REQUIRE_PIXEL_TESTS=1`).
- **Fallback**: kill switch forces GDI; a fault-injection hook forces the WDA-fail
  path so the selection ladder is testable without afflicted hardware.

## 8. References

- PowerToys MeasureTool (the stack, shipping): `src/modules/MeasureTool/MeasureToolCore/OverlayUI.cpp`, `DxgiAPI.cpp`
- PowerToys ZoomIt `WebcamPreviewWindow.cpp` (same product shape, layered-window cautionary tale)
- Kenny Kerr, "High-Performance Window Layering Using the Windows Composition Engine" (MSDN Magazine, canonical swapchain+D2D pattern)
- `SetWindowDisplayAffinity` docs (19041 floor; DWM-composition dependency; "no guarantee")
- Win11 affinity failure: learn.microsoft.com/en-us/answers/questions/700122 (win32kfull.sys `ChangeWindowTreeProtection`)
- Layered-window failure class: robmikh/Win32CaptureSample #51, Godot #76167, Electron #29085/#31340/#47834
- macOS reference: `macos/Runner/Overlays/Camera/CameraOverlay.swift` (layer stack, glow math, effect padding, drag reporting)
- Windows painter + hosts: `windows/runner/Capture/Camera/camera_bubble_painter.{h,cpp}`, `preview/preview_camera_renderer.cpp`, `preview/preview_engine.cpp:985-1008`
