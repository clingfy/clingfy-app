# Work for a Windows machine

Tasks that can only be built, tested and checked on Windows. Each one is a
self-contained brief: a Claude Code session on a Windows checkout should be
able to take one from this file alone. Open the session at the repo root and
say, for example, *"do W1 in docs/windows-machine-work.md"*.

`TODOS.md` stays the one list of open work. Each task here has an entry there
that points to this file. When a task ships, strike it here, and move its
`TODOS.md` entry to *Recently closed*.

## Before any task

- Branch from `develop` (`feature/*` or `bugfix/*`), and open the PR against
  `develop`. See `docs/branching-strategy.md`.
- `CLAUDE.md` applies, including its testing rules: tests are part of every
  change.
- Build and run (Windows takes no `--flavor`):

  ```powershell
  flutter pub get
  flutter run -d windows --dart-define-from-file=.env.dev
  ```

- Native tests (GoogleTest, under `windows/runner_tests/`). Run as CI does
  (`.github/workflows/ci.yml`), with a `flutter build windows --debug` first
  so the generated config exists:

  ```powershell
  cmake -S windows -B build/windows-tests -DBUILD_RUNNER_TESTS=ON
  cmake --build build/windows-tests --config Debug --target runner_tests
  ctest --test-dir build/windows-tests --output-on-failure -C Debug
  ```

  To run one suite: `-R GifExportPolicy` (or `-R ExportGeometry`).
- Flutter validation before finishing:

  ```powershell
  dart format --output=none --set-exit-if-changed .
  flutter analyze test
  flutter analyze lib
  flutter test
  ```

- The `.env.*` files hold live credentials and are not in the repo. Never
  commit them, and never print their values.

---

## ~~W1. GIF export parity with macOS~~ — DONE 2026-10-29

Shipped on `feat/windows-gif-export-parity`. Kept below as the record of
what was asked.


*Written 2026-10-20 from origin/develop. Line numbers drift; search for the
symbols.*

macOS shipped three GIF behaviours in 1.0.7 (#319, #326) that Windows lacks.
The macOS code says it was ported value for value from the Windows policy,
plus these additions. This task ports them back.

### 1. Size presets and the long-edge cap

**macOS:** `macos/Runner/Capture/Export/GifExportPolicy.swift`
- Long edge capped at `small` = 480, `medium` = 720, `large` = 1080. An
  unknown, empty or missing preset falls back to 1080. The match is
  case-insensitive and trimmed (`maxLongEdge(forSizePreset:)`).
- `renderSize(canvasSize:maxLongEdge:)` keeps the aspect, rounds to whole
  pixels with a minimum of 1, and returns the canvas unchanged if it already
  fits.
- The frame rate stays 15 fps for every preset. Dimensions are the only
  file-size lever.
- `intermediateRenderSize` rounds to even dimensions. Two callers must get the
  same answer: the renderer, and the size reported to Flutter, which
  rasterises caption bitmaps against it. If they disagree, burned-in captions
  are composited at the wrong scale.
- Tests: `macos/RunnerTests/GifExportPolicyTests.swift`.

**Windows today:**
- `windows/runner/Capture/Export/export_pipeline.cpp` (about 757-758) sets
  `gif_config.width/height` to the full canvas.
- `windows/runner/Capture/Export/export_geometry.cpp` (about 161-168,
  `ResolveExportPixelSize`) reads `gif_size` and then discards it with
  `(void)gif_size`. Its comment says a Windows cap "would land exactly here".
- The bridge already receives the value (`export_router.cpp`, about 419,
  reads `"gifSize"`).
- The Flutter picker (`lib/app/home/export/widgets/export_file_dialog.dart`,
  about 351-376) is not gated by platform. Its caption, "Larger sizes look
  sharper but make bigger files", is false on Windows until this lands. Once
  it lands it is true, so no gate is needed.

**Do:**
- Add the presets, the default and `RenderSize` to `gif_export_policy.{h,cpp}`,
  value for value with the Swift.
- Make `ResolveExportPixelSize` return the capped, even-rounded size when the
  format is GIF.
- Downscale the composited frame to that size before the WIC encode, and
  pass the capped size into `gif_config`.
- Rewrite `windows/runner_tests/export_geometry_test.cpp`
  `FormatAndGifSizeNeverChangeTheAnswer` (about line 386), which pins today's
  no-cap behaviour. Do not just delete it.
- Add `gif_export_policy_test.cpp` cases mirroring `GifExportPolicyTests.swift`
  for the presets and the size.
- Extend the GIF case in `export_pipeline_test.cpp` to assert the decoded
  GIF's size for each preset.

### 2. Drift-free frame delays

**macOS:** `GifExportPolicy.DelayAccumulator` (`GifExportPolicy.swift`, about
154), used by `GifEncoder.swift`. It is fed the real gap between kept frames
and carries the fractional-centisecond remainder, so the stamped total tracks
wall-clock time. At 15 fps the delays alternate 7, 6, 7, 7, 6… and average
6.667 cs. The per-frame clamps still apply: a 2 cs floor and a 0xFFFF ceiling.

**Windows today:** `windows/runner/Encoding/gif_encoder.cpp` (about 343-345)
stamps each frame with the stateless `GifDelayCentiseconds` (in
`gif_export_policy.cpp`). That rounds every gap to 7 cs, so a 15 fps GIF plays
at about 14.3 fps, about 5% slow. `gif_export_policy.h` admits "~14.3 fps".

**Do:**
- Add a stateful accumulator to `gif_export_policy.{h,cpp}` that matches the
  Swift struct line for line, and use it in `GifEncoder::WriteVideoFrame`.
- Tests: N frames at 15 fps must sum to `round(N * 100 / 15)` cs within 1 cs.
  Also test the floor and ceiling clamps and the mix of 7s and 6s, as the
  Swift tests do.

### 3. Stale comments and docs

- `windows/runner/Capture/Export/gif_export_policy.h` (about lines 3-6) and
  `export_geometry.h` (about 149-153) still say macOS has no real GIF encoder
  and that its "gif" format downgrades to a video container. That has been
  false since #319. Say instead that macOS has a native path ported from this
  file. Once parts 1 and 2 land, the two match.
- `docs/features.md`: the Windows GIF row (about 107) is marked done with no
  note of these gaps. Keep it accurate as it ships.
- `GifExportPolicy.swift` (about 12-24) lists the cap and the accumulator as
  Windows divergences. Update it when they are gone.

### Done when

- [ ] Small, Medium and Large give 480-, 720- and 1080-long-edge GIFs on
  Windows, and an unknown or missing preset gives 1080.
- [ ] Burned-in captions on a capped GIF are laid out for the capped size.
- [ ] Cumulative delay tracks wall-clock time (tests), and a 10 s, 15 fps
  export plays in 10 s, not about 10.5 s.
- [ ] The rewritten geometry test and the new policy and pipeline tests pass
  in the `ctest` run above; Flutter validation passes.
- [ ] Checked by eye: export one GIF per preset from a real recording and
  open each in a browser. Check its size, its duration against the source,
  and that it looks sharp.
- [ ] Comments and `docs/features.md` updated, and the `TODOS.md` entry moved
  to *Recently closed*.

---

## ~~W2. GIF length cap: the Windows native backstop~~ — DONE 2026-10-29

Shipped on `feat/windows-gif-length-backstop`. Kept below as the record of
what was asked.


*Written 2026-10-20, when the cap shipped on macOS.*

GIF exports are capped at **60 s of exported duration** (after cuts, trims
and reordering), with no silent trimming.
- **Dialog:** the export dialog is shared Dart, so it already refuses a long
  GIF on Windows. It disables Export and shows the reason
  (`kGifMaxExportDurationMs`, `export_settings_types.dart`).
- **macOS backstop:** `ExportEngine.export` refuses before rendering, with
  `EXPORT_GIF_TOO_LONG` and details `{durationMs, maxDurationMs}`. The
  arithmetic is in `GifExportPolicy.exportedDurationMs` and
  `exceedsDurationCap` (`macos/Runner/Capture/Export/GifExportPolicy.swift`).
  No clips means the whole file. Each range is clamped to the file before
  summing. The comparison is strictly greater than the cap plus 100 ms of
  slack, so the backstop never refuses what the dialog allowed.
- **Windows:** has no backstop. An older Flutter build, or any path that
  skips the dialog, would still render a GIF of any length.

**Do (touchpoints mapped from origin/develop; search for the symbols):**
- `windows/runner/Bridge/native_error_codes.h`: add
  `kExportGifTooLong = "EXPORT_GIF_TOO_LONG"`. The Dart constant already
  exists, so `native_error_codes_sync_test.dart` keeps passing.
- `windows/runner/Capture/Export/gif_export_policy.{h,cpp}`: add
  `kGifMaxExportedDurationMs = 60'000`, a 100 ms slack, and pure
  `ExportedDurationMs(clips, asset_ms)` and `GifExceedsDurationCap(ms)`,
  value for value with the Swift.
- `export_pipeline.cpp`, where the GIF fork knows `duration_hns`, before any
  encoder or file is created: compute the exported length (clip planner sum,
  clamped, or `duration_hns / 10000`). Over the cap, fail with a new
  `gif_too_long` flag on the result (`export_pipeline.h`). Unknown duration
  with no clips: let it through, matching the dialog's "unknown length is
  allowed".
- `export_passthrough.{h,cpp}`: a `kGifTooLong` `PassthroughError` carrying
  both lengths. Map `render_result.gif_too_long` to it, and keep it out of
  the device-loss retry.
- `Bridge/Routers/export_router.cpp` `ReplyForExportOutcome`: reply
  `EXPORT_GIF_TOO_LONG` with `{durationMs, maxDurationMs}`, the same shape
  as macOS.

**Tests:**
- `gif_export_policy_test.cpp`: the constant; empty clips; a sum in any
  order; clamping; the boundary and the slack. Mirror
  `GifExportPolicyTests.swift` (testTheBoundaryAndTheSlack and its
  neighbours).
- `export_passthrough_test.cpp`: `gif_too_long` maps to `kGifTooLong` and is
  not retried.
- `router_stub_shapes_test.cpp`: the reply's code and details.
- A pipeline case for a source over 60 s: refused before any output file
  exists.

**Done when:**
- [ ] A 61 s GIF export on Windows is refused with `EXPORT_GIF_TOO_LONG`.
- [ ] The app shows "GIFs can be at most 60 seconds long…".
- [ ] A long recording trimmed under 60 s exports.
- [ ] MP4 and MOV are unaffected.
- [ ] Tests pass, and the `TODOS.md` entry is moved to *Recently closed*.

---

## ~~W3. Export destination pre-flight~~ — DONE 2026-10-29

*Written 2026-10-29 from the TODOS entry and `docs/windows-port.md`
("Open parity gap — export destination is not pre-flighted").*

macOS checks the export folder before it renders anything
(`ExportEngine.destinationProblem(folder:)`, 1.0.x). Windows rendered the whole
export and failed only at the Sink Writer when the drive or share was gone,
with an error naming neither. The save folder is a remembered plain path, so
an ejected USB drive, a disconnected mapped drive or a reassigned drive letter
all look valid in the dialog.

**Do:**
- `ExportDestinationProblem(folder)` in `export_passthrough.{h,cpp}`: the
  drive or share is not connected (said separately from a missing folder),
  the folder is gone, it is not a folder, or a real probe write fails.
- Call it in `ExportPassthroughCopy` right after the folder is resolved, so it
  covers the byte-copy path as well as the render.
- New `PassthroughError::kDestinationUnavailable`; the router replies
  `EXPORT_ERROR`, the reason as the message, and the folder as details, the
  same as macOS.

**Tests:** each reason in `ExportDestinationProblemTest`, a passthrough case
for an unplugged drive that refuses before any progress, and the router
reply shape.

**Done when:** an export to a disconnected drive fails at once with "not
connected", not after the render; tests pass.

---

## ~~W4. 'Screen under mouse' recording target~~ — DONE 2026-10-29

*Written 2026-10-29 from the TODOS entry.*

The shared picker offers "Screen under mouse" (`DisplayTargetMode.mouseAtStart`)
on every platform, but `RecordingEngine::Start` refused it on Windows with
`BAD_MODE` ("mouse-follow modes land in a later slice"). macOS resolves it at
start to the display under the cursor (`CaptureTargetResolver`).

**Do:** resolve `kMouseAtStart` in `RecordingEngine::Start` to
`MonitorFromPoint(GetCursorPos(), MONITOR_DEFAULTTONEAREST)` through a new
`devices::MonitorUnderCursor()`, and record it as a display target. The
recording stays on that display if the cursor later moves. `followMouse` is not
in the picker and stays refused.

**Tests:** `RecordingEngineTest.StartAcceptsScreenUnderMouseMode` (the real
pipeline starts and stops), `MonitorUnderCursorTest`, and the follow-mouse
refusal kept.

---

## ~~W5. Hover frame-peek on the timeline ruler~~ — DONE 2026-10-29

*Written 2026-10-29 from the TODOS entry.* (W5 is the number; the camera
layouts, picked up later, take the next free one.)

Hovering the ruler calls `previewPeekTo` (`video_timeline.dart`), which Windows
registered as a no-op, so hovering never showed the frame. macOS seeks the
inline view. Dart keeps its own playhead while peeking and seeks back on
`previewPeekEnd`, so natively a peek is a seek.

**Do:** `HandlePreviewPeekTo` drives `PreviewEngine::SeekTo`, and never
errors: a malformed hover call is dropped and replied null, as macOS replies
nil.

**Tests:** stale session replies null; missing args, missing `ms` and a
double `ms` never reply `BAD_ARGS`; the registration is no longer the shared
no-op handler.

---

## ~~W6. Export audio tiers above 192 kbps~~ — DONE 2026-10-29

*Written 2026-10-29 from the TODOS entry.*

macOS offers 192 / 256 / 320 kbps AAC; Windows clamped every tier to 192 and
hid the picker, because nobody had measured the Media Foundation AAC encoder.

**Measured** (`aac_encoder_bitrate_test.cpp`, Windows 11): the in-box encoder
MFT accepts 256 and 320 at 48 kHz stereo and produces them (256103 / 320091
bps on 10 s of white noise). Microsoft documents only 96-192, so older builds
may refuse.

**Done:** `ResolveAudioBitrateBps` returns macOS's ladder; the pipeline asks
`AacEncoderAcceptsBitrate` (cached MFT probe, ~5 ms) and
`ClampAudioBitrateToEncoder` steps down to 192 where the encoder refuses;
`AudioEncoderConfig::Validate` allows up to 320; the export dialog shows the
picker on Windows.

**Tests:** the probe, measured-equals-asked within 3%, every tier lands on an
accepted rate, the pure clamp, the validate range, an export per tier whose
output AAC track declares the expected bitrate, and the dialog on Windows.

---

## ~~W7. Camera panel layouts: side-by-side, stacked, background~~ — DONE 2026-10-29

*Written 2026-10-29 from the TODOS entry.*

The shared UI offers seven camera layouts. Windows rendered only the four
corner bubbles; side-by-side (left / right), stacked (top / bottom) and
background-behind all fell back to a bottom-right bubble.

**Done**, value for value with macOS `CameraLayoutResolver.resolve`:
- `ComputeCameraBubbleRect` returns macOS's panel frames (y-UP converted to
  Direct2D y-DOWN): a 32%-wide full-height column, a 28%-tall full-width band,
  or the whole canvas, inset by max(16, 3% of the short side). Panels ignore
  the size factor and the bubble floor; a dragged panel becomes a square
  bubble at the drag point (macOS `manualFrame`).
- `CameraBubblePainter` takes any w x h (cover / fit, centre and shadow were
  square-only).
- `CameraRenderPlan.behind_screen`: backgroundBehind draws over the canvas
  background and UNDER the screen, in the export (`draw_camera` before the
  content) and the preview (`ComposeFrame`'s new `after_background` hook).

**Tests:** each frame and the margin floor, tiny canvases, the drag override,
the plan flag, an export whose pixels show the camera in the letterbox and the
screen on top for backgroundBehind and the camera on top for side-by-side, and
the preview hook drawing under the screen.

**Not checked by eye:** a real recording with a camera in each layout.

---

## ~~W8. Colour-grade parity with Core Image~~ — DONE 2026-10-29

*Written 2026-10-29 from the TODOS entry.*

The TODO said the D2D colour chain diverged from Core Image by up to 2.77 at
strong grades and that `ColorGradeGoldenTest` was excluded from CI until fixed.
Measured on this machine, it already passes: #275 recalibrated the
temperature/tint model, and the worst `|diff|` against the macOS goldens is
0.0017 against a 0.002 tolerance. The CI exclusion was simply never lifted.

The golden test only proves the CPU matrix, though. **Done:**
- `ColorGradeEffectGpuTest`: the real `ColorGradeEffectChain` (sRGB → scRGB,
  5x4 matrix in FP16, re-encode) over 216 8-bit colours and 25 grades
  (each axis at ±0.5 and ±1, all-axes composites) matches the golden-pinned
  matrix within one 8-bit step (worst 0.0032).
- `ci.yml` no longer excludes `ColorGradeGoldenTest`.

---

## ~~W9. Capture frame-rate control (30 / 60 fps)~~ — DONE 2026-10-29

*Written 2026-10-29 from the TODOS entry.*

The Frame rate dropdown was hidden on Windows because `setCaptureFrameRate`
is a no-op. Dart already sends the setting as `startRecording`'s `frameRate`,
but Windows only used it as the encoder's rate attribute: WGC delivers a frame
whenever the display composes one, so a busy 144 Hz screen recorded at up to
144 fps whatever was picked.

**Done:** `CaptureFramePacer` drops frames that arrive before the next slot,
in the recording drain loop, on a grid anchored at the first kept frame
(jitter-tolerant, snaps forward after a gap, quarter-interval slack). The
dropdown shows on Windows. `setCaptureFrameRate` stays a no-op natively: the
value travels with `startRecording`.

`setRecordingQuality` (the other half of the TODO) has no caller in the Dart
UI on either platform, so there is nothing to show.

**Tests:** the pacer (60 Hz -> 30 keeps every other frame; 60-240 Hz sources
capped at 30 / 60 within a frame over 10 s; slower sources untouched; +/-1.5 ms
jitter neither drops nor adds; no burst after a 2 s gap), the engine suite, and
the Windows dropdown visible in `windows_control_hides_test.dart`.

**Not checked:** a recording of a busy 144 Hz screen measured with ffprobe.

---

## ~~W10. Fixed-target zoom (draggable focus point)~~ — DONE 2026-10-29

*Unblocked 2026-10-29 by the owner's call: save the point and export it.*

macOS honours the dragged point only in the live preview: `zoom.manual.json`
never stores it, so it is lost on reopen and never exported. Windows does not
copy that gap. The store format gains two optional keys, the ones Dart's
`ZoomSegment.toMap` already sends on save:

    "focusMode": "fixedTarget", "fixedTarget": {"dx": 0.3, "dy": 0.6}

Both are optional, so old files load as before and a reader that ignores
unknown keys (macOS today) still loads new ones.

**Done:**
- `zoom_manual_store` reads and writes both keys (the point only with
  `fixedTarget`, clamped to [0,1]). Its scanner now skips nested unknown
  values whole instead of stopping at the first comma inside them.
- `MergeZoomSegments` carries the point into `ZoomSegment`; the export
  (`ZoomExportController`) zooms on it instead of running the cursor
  heuristic. Unpinned segments keep the heuristic.
- One wire parser, `Bridge/Routers/zoom_focus_args`, for both
  `saveManualZoomSegments` and `previewSetZoomSegments`.
- The preview (`PreviewCompositor`) aims a pinned segment at its point. The
  preview halo now marks the cursor where the zoom puts it, not the zoom
  centre, which only differed once the centre could be somewhere else.
- `previewGetCursorSamples` answers from the open session's cursor sidecar
  (Dart's "cursor is still here" hint and its default focus for a new
  segment); `previewGetSourceDimensions` answers the video size (the sidecar
  header's before the first frame).
- `previewGetZoomCapabilities` reports all three capabilities true, so Dart
  offers the draggable target and the follow / fixed toggle. No Dart change:
  the UI was capability-gated all along.

**Tests:** store round-trip, Dart's exact shape, clamping and bad points,
nested unknown values, mode-without-point; merge carries the point; the
export zooms on a pin while the cursor moves and clamps a corner pin;
`ZoomSegmentStateAt` reports it; sample selection (inclusive range, nearest
with ties to the earlier); the parser; a router save → reopen round trip; the
compositor aims at the pin; capability and no-session shapes.

**Not checked:** dragging the target in the running app and exporting the
result (owner, with the other visual checks). **macOS** still drops the point:
queued on the macOS follow-up list.

---

## W11. Live cursor highlight while recording — BUILT 2026-10-30, control hidden until checked

*Owner's call 2026-10-30: build the overlays now, check them on screen
later, keep the controls hidden until then.*

macOS draws a 60 pt, 25% systemYellow disc that follows the pointer, with an
outline that pulses (scale 1 -> 1.35, fade, 0.35 s ease-out) on each left
click. It is a plain on-screen panel, so it is recorded into the video.
Linked to recording, it shows only while recording (not while paused);
unlinked, whenever it is on. The request's `disableCursorHighlight` turns it
off for the session.

**Done:**
- `Overlay/cursor_highlight_model`: the show rule, the pulse curve (the real
  ease-out bezier), and the pixels (premultiplied, anti-aliased, 120 dip
  window scaled per monitor DPI).
- `Overlay/cursor_highlight_overlay`: a topmost, click-through, per-pixel
  alpha layered window on its own thread. A 60 Hz timer follows
  `GetCursorPos` and watches the primary button (honouring swapped
  buttons); polling because the recording's `CursorClickHook` already owns
  the process's low-level mouse hook. No display affinity: it is meant to be
  recorded, as on macOS.
- `setCursorHighlightEnabled` / `setCursorHighlightLinkedToRecording` are
  real; the engine reports start / pause / resume / every end path.

**Still hidden:** the Pointer control in `recording_options_sidebar.dart`.
Dart pushes the saved setting, which defaults to off, and Windows has never
shown the control, so nothing appears until it is unhidden.

**Tests:** the show rule (linked, unlinked, suppression through pause), the
pulse (endpoints, monotonic, ease-out not linear), the raster (60 dip disc
at 25%, premultiplied, DPI scaling, the outline's position and fade, the
largest pulse inside the window), and the overlay's window coming up and
going with the recording state.

**Owner check, then unhide:** the halo follows the pointer on every
monitor, at mixed DPI, pulses on click, and shows in the recorded video.

---

## W12. Reveal Area overlay — BUILT 2026-10-30, button hidden until checked

*Same owner's call as W11.*

macOS `AreaPreviewOverlay` strokes a 2 pt white line around the selected area
for one second: on Reveal Area and right after a pick. Clearing the area or
starting a recording hides it.

**Done:**
- `Overlay/area_reveal_overlay`: the geometry (the area clamped to its
  monitor as the recording clamps it, grown by the line's outer half and
  kept on that monitor, line scaled per DPI), the pixels (opaque white band,
  clear inside), and a click-through layered window on the platform thread
  with a 1 s auto-hide that restarts on each reveal.
- `revealAreaRecordingRegion` is real; a pick shows the outline; clearing
  hides it; `startRecording` hides it before the engine starts, so it is
  never recorded.

**Checked:** with the test window made PerMonitorV2 like the app, a
screenshot at 125% put the 3 px line exactly on the area's edge (1 px out,
2 px in). This window is not capture-excluded, so the screenshot is a real
oracle here.

**Still hidden:** the Reveal Area button in `recording_source_section.dart`.

**Tests:** geometry (centred line, DPI scaling, monitor edges, an area
larger than or off its monitor), the raster, and the lifecycle (no selection
is a no-op; shows on the primary monitor and hides itself after 1 s; hide is
immediate).

**Owner check, then unhide:** reveal on each monitor, at mixed DPI, after
a pick and from the button.

---

## Not briefed yet — triage, 2026-10-29

`TODOS.md` → *Feature backlog* → *Windows parity (Windows machine)* lists the
remaining gaps, each with its source. After W1-W10, none of them is a
self-contained task a session can finish and verify alone. Each one is
waiting on something:

**Needs the owner watching a real capture.** `WDA_EXCLUDEFROMCAPTURE` makes
screenshots a false oracle, so these cannot be verified unsupervised:
- Exclude Clingfy from capture (`setExcludeRecorderApp`). The obvious WDA
  approach risks the hybrid-GPU blank-window failure, and there is an open
  hide-vs-show product call for the four capture-excluded windows.
- ~~Live cursor highlight while recording.~~ Built as W11, control hidden
  until checked on screen.
- ~~The Reveal Area overlay.~~ Built as W12, button hidden until checked on
  screen.

**Blocked on a design decision:**
- Preview mic gain / voice cleanup before the first cut, and preview
  speaker-echo removal. Both need a host for the DSP on the passthrough path,
  which `docs/decisions/windows-editing-step4-7-preview-audio.md` (D6.1)
  blocks on the preview audio clock, not the maths.
- GPU-end-to-end preview decode (#296): the compositor's upload seam needs a
  redesign first.

**Parked by an earlier decision:** area selection remembered across restarts,
window capture following resizes, crash salvage via fragmented MP4, the true
squircle mask, automatic updates (WinSparkle), and code signing (not planned).

**Ideas, not started:** the burned-in desktop bubble mode and mic-out-of-
loopback cancellation.

When one is unblocked, write its brief here as W10, W11, and so on, in the
shape of W1.
