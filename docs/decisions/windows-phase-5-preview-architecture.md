# Windows Phase 5 preview architecture decision

## Status

**Accepted** — 2026-05-26.

This note locks the runtime architecture for the Windows preview /
post-recording / project-reopen flow (Phase 5). Production code that
implements `previewOpen`, `previewPlay` / `previewPause`,
`previewSeekTo`, `player/events`, `getRecordingSceneInfo`, and
`.clingfy` project reopen MUST follow the locked choices below unless
this note is superseded by a newer decision.

## Decision

**Approach A** is accepted. Phase 5 production Windows preview runs:

```
WinRT MediaPlayer (IsVideoFrameServerEnabled = true)
    → CopyFrameToVideoSurface onto an offscreen video texture
    → clingfy::preview::PreviewCompositor (D2D + the shared
      kZoom* / kHighlight* constants from preview/zoom_easing_constants.h)
    → DXGI shared-handle D3D11 texture
      (D3D11_RESOURCE_MISC_SHARED + IDXGIResource::GetSharedHandle)
    → FlutterDesktopTextureRegistrarRegisterExternalTexture
      (kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle)
    → Flutter `Texture(textureId: ...)` widget in the Dart preview UI
```

The Flutter shell remains the preview surface. The Windows runner does
**not** open its own preview window. Timing on the Flutter-rendered
output is read through `SchedulerBinding.instance.addTimingsCallback`
(`FrameTiming.buildDuration` / `rasterDuration` / `totalSpan`); the
producer thread tracks its own copy / render / handoff buckets via
`clingfy::preview::FrameTimingCollector`.

## Context

Phase 5 of the Windows port adds the post-recording flow that the
macOS engine already ships:

- `previewOpen(projectPath)` — load the just-recorded
  `.clingfyproj/capture/screen.mp4` plus its `cursor.jsonl` sidecar.
- `previewPlay` / `previewPause` — drive transport from Dart.
- `previewSeekTo(positionMs)` — frame-accurate scrubbing.
- `player/events` — broadcast position / duration / state changes
  back to Flutter.
- `getRecordingSceneInfo` — natural video size + duration + scene
  metadata for the editor UI.
- `.clingfy` project reopen — same flow when the user picks an old
  recording from the recents list, not just the freshly-finalised one.

Up to Phase 4 (PR #95) the Windows `previewOpen` is the Phase 1
contract no-op: Dart's request succeeds and the preview view sits on
an empty timeline. The blocker is not the bridge contract — that's
been in place since Phase 1 — but the renderer underneath it.

The risk the design doc flagged at the start of Phase 5 was **not**
whether C++ could decode + composite frames (Windows has multiple
decoders), but whether the resulting GPU surface could be handed back
across the Flutter Windows embedder boundary on the GPUs the product
actually ships against (notably Intel Iris Xe iGPUs, which surface
several driver quirks around shared-handle import). The POC sequence
that produced this decision was structured around exercising that
boundary at progressively higher fidelity.

## Alternatives considered

### A — MediaPlayer frame-server + PreviewCompositor + Flutter Texture (**accepted**)

WinRT MediaPlayer in frame-server mode decodes the MP4 and seeks. The
existing `PreviewCompositor` (extracted in #103 from the Stage 1B/C/D
HWND demo so the same logic feeds both the POC HWND target and the
Flutter texture target) handles cursor zoom + halo composition through
Direct2D. The D3D11 texture the compositor writes into is allocated
with `D3D11_RESOURCE_MISC_SHARED` and exposed to Flutter via the legacy
shared-handle path that
`flutter_texture_registrar.h` /
`kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle` documents.

Pros:

- Reuses the production-grade WinRT decoder pipeline, including HW
  acceleration, hardware-accelerated colour conversion, the existing
  seek + duration API, and the audio playback path.
- Single source of truth for cursor / zoom timing constants
  (`preview/zoom_easing_constants.h`) — already shared with macOS via
  the parity tests in `windows/runner_tests/`.
- Keeps the Flutter shell as the visible product UI. No second native
  window to position, focus-manage, or DPI-track on top of the
  Flutter view.
- Proven end-to-end on Intel Iris Xe (the lowest-headroom GPU the
  product currently targets) — see Evidence below.

Cons:

- Texture lifecycle on shutdown has a known instability
  (`FlutterDesktopTextureRegistrarUnregisterExternalTexture` crashes
  inside Flutter's ANGLE consumer with 0xC0000005 on Intel iGPUs).
  The POC works around it by skipping unregister and leaking the
  texture until process exit; **production must fix this before
  ship.** See "Known follow-ups" below.
- Frame-server mode requires the producer to do the GPU work
  synchronously inside `VideoFrameAvailable` callbacks on WinRT
  thread-pool workers. The D3D11 device + D2D factory must be
  multi-thread protected; this is set up at bridge init and is not
  optional.

### B — Media Foundation Source Reader + custom D3D11 compositor

Skip MediaPlayer entirely. Open the MP4 via `IMFSourceReader`, drive
sample decode + seek manually, do the same Direct2D composition on
the decoded samples, write into the same shared texture.

Pros:

- Tighter control over decode timing (no MediaPlayer scheduler in
  the loop).
- One fewer WinRT runtime dependency.

Cons:

- Reimplements seek, end-of-stream handling, audio sync, decoder
  selection, and back-pressure from scratch. MediaPlayer already
  handles all of these and the POC numbers show the resulting
  per-frame budget is comfortably under the design-doc bar.
- No measurable upside on the POC fixture. Stage 2A-2's total p99 of
  **6.001 ms** vs the **25 ms** bar leaves 19 ms of headroom — there
  is nothing to optimise for.

**Rejected for now.** Approach B is the documented fallback if a
future product requirement (e.g. real-time audio routing through
WASAPI on the preview path, or some MediaPlayer-specific bug that
can't be worked around) makes MediaPlayer untenable.

### Kill-switch fallback

A "open the recording in the system default video player" path was
considered as a degraded fallback while the bridge was unproven.

**Not needed.** The bridge is proven (Stage 2A-1) and the real
compositor on top of it is proven (Stage 2A-2). Shipping a fallback
path now would add maintenance burden without de-risking anything we
haven't already de-risked.

## Evidence

Three POC milestones validated the path at increasing fidelity. All
runs used Intel Iris Xe Graphics on Windows 10.0 build 26200. Pass
bar from the Phase 5 design doc: total median ≤ 16 ms AND total p99
≤ 25 ms.

### Stage 1D — HWND compositor path (PR #101)

Same `PreviewCompositor` rendering directly into a Direct2D-on-HWND
swap chain over a 30-second measurement window with the
real-recording fixture (1600 × 900 `.mov`, 7-event hand-authored
`cursor.jsonl`), zoom + highlight active, two programmed seeks fired
inside the window.

| bucket  | frames | min (ms) | median (ms) | p99 (ms) | max (ms) |
| ------- | -----: | -------: | ----------: | -------: | -------: |
| total   |    875 |    3.054 |       4.040 |    4.991 |   23.651 |
| copy    |    875 |    2.422 |       3.275 |    4.167 |   22.923 |
| render  |    875 |    0.313 |       0.502 |    0.722 |    1.273 |
| present |    875 |    0.145 |       0.199 |    0.366 |    0.487 |

Verdict: **PASS** (median 4.040 ms, p99 4.991 ms).

Conclusion: the compositor itself is bounded well below the design-doc
bar on the target hardware. Any headroom problems in the Flutter path
will come from the bridge, not the renderer.

### Stage 2A-1 — Flutter Texture / shared-handle bridge (PR #102)

Solid-color animated D3D11 texture (no MediaPlayer, no compositor)
fed into Flutter via `kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle`
across a 25-second window, with the Dart-side `Texture(textureId:)`
widget mounted.

| bucket | median (ms) | p99 (ms) |
| ------ | ----------: | -------: |
| build  |       7.069 |   12.230 |
| raster |       0.865 |    1.858 |
| total  |       9.114 |   48.653 |

Verdict: **PASS** on the raster bucket (median 0.865 ms,
p99 1.858 ms).

What this run proved:

- `D3D11_RESOURCE_MISC_SHARED` + `IDXGIResource::GetSharedHandle`
  imports cleanly into Flutter's ANGLE consumer on Intel Iris Xe.
- NT shared handles + `IDXGIKeyedMutex` do **not** work over this
  path — earlier iterations crashed on first frame as Flutter
  dereferenced a handle it couldn't open. See "Locked technical
  choices" below.
- Unregistering the texture on shutdown crashes Flutter's consumer
  device with 0xC0000005 on this GPU. Documented in the bridge .cpp
  and tracked in "Known follow-ups."

### Stage 2A-2 — real compositor through Flutter Texture (PR #104)

Same fixture as Stage 1D, but the compositor's output goes into the
DXGI shared texture (not an HWND swap chain) and Flutter samples it
through the `Texture` widget. 25-second window, cursor zoom + halo
active.

Native producer timings (per `VideoFrameAvailable` callback):

| bucket  | frames | min (ms) | median (ms) | p99 (ms) | max (ms) |
| ------- | -----: | -------: | ----------: | -------: | -------: |
| total   |    712 |    2.979 |       4.178 |    6.001 |   21.160 |
| copy    |    712 |    2.546 |       3.689 |    5.280 |    6.285 |
| render  |    712 |    0.154 |       0.334 |    0.539 |   12.490 |
| handoff |    712 |    0.062 |       0.096 |    0.422 |    0.741 |

Flutter `SchedulerBinding` timings:

| bucket | median (ms) | p99 (ms) |
| ------ | ----------: | -------: |
| build  |       0.585 |    2.734 |
| raster |       0.886 |   10.741 |
| total  |       2.710 |   86.251 |

Verdict: **PASS** across all four required signals
(shared-handle ok, ≥ 1 frame consumed, native total median/p99 ≤
16/25, Flutter raster median/p99 ≤ 16/25). 712 frames consumed,
0 dropped.

This is the architecture-decision-grade evidence: the real production
shape end-to-end produces frames inside the design-doc budget on the
hardware that has historically failed first.

## Locked technical choices

These follow from the POC and are binding on Phase 5 production code:

1. **Decode / seek API:** WinRT MediaPlayer in
   `IsVideoFrameServerEnabled` mode. `Source` is built from the MP4
   path via `MediaSource::CreateFromUri(file:///...)`.
   `IsLoopingEnabled` is a POC convenience and will NOT carry into
   production (the editor's loop state is driven from Dart).
2. **Composition:** `clingfy::preview::PreviewCompositor` from
   `windows/runner/preview/preview_compositor.{h,cpp}`. Same instance
   shape both the HWND demo and the Flutter bridge consume —
   production must not fork the compositor.
3. **Zoom / cursor constants:** the parity-checked
   `windows/runner/preview/zoom_easing_constants.h`. Any new constant
   added for the production preview must be parity-checked against
   Swift in `RunnerTests` the same way the existing constants are.
4. **Shared texture:**
   `D3D11_RESOURCE_MISC_SHARED` + `IDXGIResource::GetSharedHandle`.
   **Do not** use `D3D11_RESOURCE_MISC_SHARED_NTHANDLE` and **do not**
   use `IDXGIKeyedMutex` on this surface. The Flutter Windows
   embedder's ANGLE import path documents only the legacy shared-handle
   form; the POC confirmed NT handles + keyed mutexes crash on first
   frame against Intel Iris Xe.
5. **Bridge surface:**
   `FlutterDesktopTextureRegistrarRegisterExternalTexture` with
   `info.type = kFlutterDesktopGpuSurfaceTexture` and
   `info.gpu_surface_config.type = kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle`.
   The descriptor (`FlutterDesktopGpuSurfaceDescriptor`) stays pointer-
   stable across calls — same struct returned every frame.
6. **D3D11 / D2D threading:** D3D11 immediate context is
   `ID3D11Multithread::SetMultithreadProtected(TRUE)`; D2D factory is
   `D2D1_FACTORY_TYPE_MULTI_THREADED`. The compositor runs on the
   WinRT thread-pool worker that delivers `VideoFrameAvailable`; no
   producer thread of our own.
7. **GPU handoff:** explicit `ID3D11DeviceContext::Flush()` after
   `EndDraw` and before
   `FlutterDesktopTextureRegistrarMarkExternalTextureFrameAvailable`.
   Without the Flush, Intel iGPUs produce intermittent torn / stale
   frames.
8. **Flutter-side timing source:**
   `SchedulerBinding.instance.addTimingsCallback` (Flutter's documented
   API for receiving `FrameTiming` data). Production preview must
   keep instrumentation hooks (behind a debug flag) so we can re-run
   the verdict on real customer GPUs.
9. **UI surface:** `Texture(textureId: ...)` mounted by the production
   preview Flutter widget. The Windows runner never opens its own
   preview HWND.

## Known follow-ups (must land before ship, not in PR #105)

These are POC-acceptable shortcuts; production cannot ship with them.

- **Texture unregister stability.**
  `FlutterDesktopTextureRegistrarUnregisterExternalTexture` crashes
  Flutter's ANGLE consumer on Intel Iris Xe (0xC0000005). The POC
  workaround is "never unregister, let the texture leak until process
  exit." Production opens / closes the preview many times per session;
  the leak is not acceptable. Triage paths:
  - Wait for the next Flutter embedder release and re-test against
    the same Intel driver.
  - Defer the unregister to a quiet point (no `Texture` widget mounted
    on the surface) and queue Stop work behind a confirmed teardown
    barrier.
  - File the bug upstream with a reduced repro.
- **Audio.** The POC drives MediaPlayer with frame-server mode for the
  video path only. Audio output is not wired. Production preview needs
  audio synchronised with the Dart-driven play / pause / seek; decide
  between MediaPlayer's default audio renderer and routing audio
  packets through Flutter for unified mix control.
- **Multi-GPU validation.** All POC runs are Intel Iris Xe. Production
  needs the same `stage2a_2_result.md` shape produced on at least one
  NVIDIA discrete GPU and one AMD APU before the beta gate.
- **Surface resize.** The POC uses a fixed 1280 × 720 shared texture
  with the compositor letterboxing arbitrary source resolutions into
  it. Production needs the shared surface to track the Flutter
  widget's logical size + DPI so we don't waste pixels on 4K screens
  or downscale 720p sources unnecessarily.
- **Production location.** The bridge currently lives under
  `windows/runner/preview/poc_stage_2a/`. Production code moves it
  into `windows/runner/preview/` proper alongside the compositor, and
  the POC method-channel surface (`pocStage2aStart`/`Stop`) collapses
  into the production `previewOpen` / `previewClose` handlers.
- **Cursor sidecar capture.** The POC reads a hand-authored
  `cursor.jsonl`. Production needs the WGC display capture backend
  to emit a real cursor sidecar during the recording so preview
  has something to read; that work lives in Phase 8 of the roadmap
  but the bridge must accept the production format from day one.

## Consequences

Positive:

- Phase 5 implementation does not need to write a Media Foundation
  Source Reader decode + seek loop. WinRT MediaPlayer covers it.
- Phase 5 implementation reuses the proven `PreviewCompositor` from
  Stages 1B–1D and 2A-2. The same composition logic ships in
  production as ran the verdict runs.
- Preview UI stays inside the Flutter shell with the same widget
  tree, theme, and layout the macOS preview uses. No second native
  window to position / focus / DPI-track.
- The bridge contract that #102 / #103 / #104 exercised
  (`pocStage2aStart` / `pocStage2aStop`) becomes the obvious shape
  for the production `previewOpen` / `previewClose` calls — same
  shared texture, same `Texture` widget, just different lifecycle.

Negative / risks to plan against in Phase 5 design v2:

- Texture lifecycle / unregister has a known bug — see Known
  follow-ups. Production cannot ship the "leak forever" workaround.
- We do not yet have a real audio path for preview. Phase 5 design v2
  needs to pick one before implementation starts.
- We do not yet have GPU coverage beyond Intel Iris Xe. Phase 5
  design v2 needs to include the validation matrix.
- We do not yet have a project-reopen story for older `.clingfy`
  bundles. Phase 5 design v2 needs to specify which fields it reads,
  what version skew tolerance it has, and how `getRecordingSceneInfo`
  composes from the on-disk manifest.

## Next steps

This note is binding for production but it is not a plan. The next
PR (intended #106) is the **Phase 5 design v2** which turns the
locked architecture into a concrete production implementation order:

1. `previewOpen` — open the `.clingfyproj`, mount the bridge, return
   the texture id and scene info.
2. `previewPlay` / `previewPause`.
3. `previewSeekTo`.
4. `player/events` event channel (position / duration / state).
5. `getRecordingSceneInfo` — natural size + duration + cursor sidecar
   path. Designed so the editor can render its UI before the player
   has decoded its first frame.
6. `.clingfy` project reopen — same flow from the recents list.

Production work on `previewOpen` does not start until Phase 5 design
v2 is reviewed and merged.

## References

- POC artifacts (regenerated per run, not committed):
  - `build/windows-poc/stage1d_result.md`
  - `build/windows-poc/stage2a_result.md`
  - `build/windows-poc/stage2a_2_result.md`
- POC code:
  - `windows/runner/preview/preview_compositor.{h,cpp}` (#103)
  - `windows/runner/preview/poc_stage_2a/stage2a_texture_bridge.{h,cpp}`
    (#102, #104)
  - `windows/runner/preview/zoom_easing_constants.h` (#96)
- Roadmap row: `docs/windows-port.md` "Roadmap (phased)" — Phase 5.
- Flutter Windows embedder texture surfaces:
  `flutter_texture_registrar.h` upstream
  (`kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle`).
- Flutter timing source:
  `SchedulerBinding.addTimingsCallback` (Flutter docs).
