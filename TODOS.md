# TODOS

Deferred work captured during reviews. Each item has enough context to pick up cold.

## Editor — clip lane

### Persistent scissors tool mode (Premiere-style razor)
- **What:** A button-activated cut tool that stays active across multiple cuts without holding a modifier.
- **Why:** Some users coming from Premiere/Final Cut expect a sticky "blade" tool (select tool ↔ razor tool).
- **Context:** Deferred in the 2026-06-28 eng review of the scissors-split feature. We shipped modifier-click instead (hold Option → cut at pointer) because a persistent opaque overlay fought the timeline's scroll/pan and the trim-handle gestures, and put interaction state in lib/core where it didn't belong. The modifier-click approach delivers the same cut-at-pointer with none of those conflicts. See the design doc `*-scissors-split-design-*.md` in the gstack project dir for the full rationale (objections 1-4).
- **Pros:** Familiar to pro-editor users; no key to hold for long cutting sessions.
- **Cons:** Modal UX (the friction casual users complain about); reintroduces the gesture-conflict landmines the modifier approach avoided.
- **Start at:** `lib/app/home/preview/widgets/video_timeline.dart` (mode state would live local in `_VideoTimelineState`, next to `_panModeEnabled`), `lib/app/home/preview/widgets/timeline/timeline_editor_viewport.dart` (a non-opaque hit layer inside `TimelineScrollableCanvas`).
- **Depends on:** The modifier-click cut layer landing first (this is its evolution).
- **Gate:** Only build on real user demand.

### Frame-preview (previewPeekTo) on the clip lane during cut-hover
- **What:** Extend the hover→`previewPeekTo` pipeline to the clip-lane region, not just the ruler, while cut-hovering.
- **Why:** Today hover-peek is wired only on the ruler strip (`timeline_editor_viewport.dart:489-494`). With modifier-click cutting, hovering the lane shows a guide line but not the actual frame you're about to cut on — so cuts on the lane area are "blind."
- **Context:** Raised by the outside-voice review (2026-06-28). Enhancement, not required for the scissors-split feature to work.
- **Pros:** You see the exact frame under the cut point anywhere on the timeline, not just on the ruler.
- **Cons:** More hover→native traffic on the lane; needs the same coalescing/peek-end hardening the ruler path already has.
- **Start at:** `lib/app/home/preview/widgets/video_timeline.dart` (`onHoverSeek`/`previewPeekTo` wiring), `lib/app/home/preview/widgets/timeline/timeline_editor_viewport.dart`.
- **Depends on:** Scissors-split cut layer (shares the cut-hover state).

## Export — colour

### Exported video does not match the inline preview's colour

- **What:** The same frame is visibly different between the inline preview and the exported file. Reported 2026-07-28 with a matched pair of screenshots one second apart.
- **Measured, not eyeballed.** Sampling matching wallpaper patches (decoded to sRGB so both are compared in one space) gives export-minus-preview deltas of roughly `+9 +7 +9`, `+5 +11 +9`, `+16 +17 +14` (R G B, 0-255). Two things follow: the export is lifted overall, and **midtones lift most** — in one patch green went `68 -> 79` while red in the same patch went `29 -> 34`. That is a transfer-function signature. A wrong YCbCr matrix would shift hue roughly uniformly instead, so the matrix is probably not the culprit.
- **Two concrete inconsistencies exist in the export path, either of which could contribute:**
  1. `VideoColorPipeline.tag(pixelBuffer:)` attaches `kCVImageBufferCGColorSpaceKey = sRGB` **and** `kCVImageBufferTransferFunctionKey = ITU_R_709_2` to the same buffer. Those are different curves, and consumers disagree about which wins: Core Image reads the CGColorSpace attachment, AVFoundation/VideoToolbox read the discrete transfer tag. The preview and the export therefore need not agree even from identical pixels.
  2. The written file reports `FullRangeVideo: 0` (limited range, 16-235) while Core Image renders full-range 0-255. If the data really is full-range, a decoder honouring the tag shifts everything.
- **Do NOT guess at the fix.** Both "tag sRGB transfer instead of 709" and "convert the data to 709" are one-line changes that alter every export, and only one is right. `docs/windows-port.md` already records a colour-parity divergence, so this area punishes confident guesses.
- **Decide it by measurement:** render one known test frame (a greyscale ramp plus primary patches) through the preview path and the export path, sample both, and fit the transform. The ramp separates the two candidates immediately — range shows as a straight-line offset with clipped ends, gamma as a curve.
- **Start at:** `macos/Runner/Capture/Export/CompositionBuilder.swift:16` (`workingColorSpace`), `:118` (`tag(pixelBuffer:)`), and the export render loop at `macos/Runner/Capture/Export/LetterboxExporter.swift:2383-2393` where the buffer is tagged before it is appended.
- **Evidence:** the reported screenshot pair, and the exported file's own extensions dump (`CVImageBufferColorPrimaries: ITU_R_709_2`, `FullRangeVideo: 0`).
- **Effort:** human ~4h / CC ~45min once the ramp measurement exists.

## Windows — preview/export parity

### ~~Camera border width and shadow blur are raw pixels on both surfaces (preview reads ~3x heavier)~~ — DONE

Fixed. The wire value stays absolute export-canvas px (no wire change, so macOS is
untouched) and the painter resolves it onto whatever surface it is drawing, via
`CameraBubblePainter::Style::effect_scale` =
`short_side(surface) / short_side(export)`. The bubble's 96px min-side floor —
the other non-proportional term, which bound for most of the size-factor band in
portrait/reel916 — takes the same scale through a defaulted
`ComputeCameraBubbleRect(..., min_side_px)` parameter.

Residual, deliberately not fixed here: the LIVE overlay has the same class of
defect internally (`ComputeFloatingRect` scales the bubble by `dpi_scale` while
`ResolveOverlayBubbleStyle` passes `border_width` through unscaled), so at 150%
display scaling the live bubble's border is proportionally thinner than at 100%.
Separate surface, separate fix, and macOS shares the absolute constants — raise
it with macOS in scope rather than diverging one platform at a time.

### Should the live camera bubble hide while a recording is paused? (product call)

- **What:** `RecordingEngine::Pause` pauses the camera recorder and `CameraRecorder` drops every preview frame while paused, but nothing hides or stops the floating bubble. It stays on screen showing its last frame for an unbounded, user-controlled time.
- **Why it is on this list and not already fixed:** it surfaced while closing the frameless-park gap, which needed to know every way frames stop. The park fix makes the stale-pixels case safe (a parked presenter now hides its own window), but a PAUSE is not a fault — the bubble is deliberately still up, showing a frozen frame. Whether that is correct is a product decision, not a bug fix, so it was left alone rather than changed unasked.
- **The argument for hiding:** a paused recording showing a live-looking camera bubble misrepresents state, and it is the widest window in which a mid-session presenter swap would surface an empty bubble.
- **The argument against:** the bubble is also the user's placement handle; hiding it mid-session moves it out of reach and makes resume feel like a restart.
- **Start at:** `RecordingEngine::Pause` / `Resume`, mirroring the `wda_excluded()` gate `SetCameraPreviewFloating` already uses. macOS parity should be checked first — it may already have an answer.
- **Effort:** human ~2h / CC ~20min once the product call is made.

### Camera render-plan extraction (make derivation parity structural, not just tested)

- **What:** Both surfaces independently derive the same five things from their parsed composition — bubble rect, painter `Style`, `CameraAnimationParams`, slide edge, and the shape/radius/content-mode passed to `painter_.Prepare`. The derivations are currently line-for-line equivalent (audited field by field), but that equivalence is maintained by hand in two files.
- **Proposed seam:** `BuildCameraRenderPlan(spec, canvas_w, canvas_h) -> CameraRenderPlan` plus a per-frame `ResolveCameraFrame(plan, clock_ms, total_ms, screen_zoom)`, in a D2D-free header. Each surface collapses to one call. It is a pure refactor — the moved lines call identical functions with identical arguments in identical order.
- **Why it is NOT done yet:** the parse side was the surface that actually drifted (twice), and that is now unified with a mapper plus a guard test. The derivation side has never drifted, so this is hardening rather than a fix, and it is wide: it touches export_router, export_passthrough, export_pipeline, camera_export_renderer, preview_camera_renderer and their tests. Worth doing as its own commit so a regression bisects cleanly.
- **One real snag to fix while doing it:** the preview assigns its cached animation state INSIDE the `factory1 != nullptr && frame_bitmap_ != nullptr` guard, so a one-time bitmap-creation failure leaves `zoom_behavior_` / `layout_preset_` / `slide_edge_` stale. Harmless today because `painter_ready_` stays false, but the pure plan build should be hoisted out of that guard.
- **Note `CameraBubblePainter::Style` lives in a header that pulls in `d2d1_1.h`** — move it down into `camera_export_layout.h` with a painter-side alias, or the "pure" plan drags D2D into every test translation unit.
- **Effort:** human ~1 day / CC ~1h.

### Camera zoom emphasis (the pulse) is not ported — deferred, with the reason

- **What:** `cameraZoomEmphasisPreset` (`none` / `pulse`) + `cameraZoomEmphasisStrength`. The editor controls exist and round-trip to disk on Windows; nothing renders them. macOS ships it. Scale-with-zoom, the other half of what used to be one features.md row, IS ported — these are separate features and the row is now split.
- **What it actually is, which the name hides:** not a one-shot bump on the zoom edge. macOS runs `1 + strength*0.5*(1 - cos(2π · 2Hz · localTime))` for the WHOLE time a zoom segment is active — a continuous 2 Hz throb, amplitude `strength` (clamped 0…0.20), starting at exactly 1.0 and snapping back to 1.0 when the segment ends. Roughly three full cycles across a typical segment. Default is OFF (`none`).
- **Why it is deferred: it is a zoom-subsystem job, not a camera job.** The pulse needs a zoom-local clock — `(isActive, localTime since this segment started)`. On the EXPORT that is nearly free: `ZoomExportController::Advance` already locates the active `ResolvedSegment` and that struct carries `start_ms`, so it is ~6 lines onto `ZoomExportController::Frame`. On the PREVIEW there is no onset at any distance: the preview zoom is a different algorithm entirely — click-hold with a hardcoded activation window, no segments, no hysteresis, no gap-merge, no minimum-segment rule. Shipping the pulse means building real segments in the preview and reconciling them with its own activation rule.
- **The cheap shortcut is actively wrong.** Deriving the preview's local time from `zoom.last_click_ts_us` looks obvious and produces a visible defect: the export's segment starts ~200 ms after the click (hysteresis), and at 2 Hz a 200 ms offset is ~144° of phase — the editor would show the bubble growing at the exact timestamp where the export shows it shrinking. Worse than not shipping it.
- **Two more decisions with no macOS answer to copy:** (1) `zf.active` on Windows means "smoothed zoom > 1+eps", which stays true through the whole ease-out tail after the segment's `end_ms` — a literal port either cuts the throb dead mid-cycle at a hard scale discontinuity, or throbs with no owning segment. (2) Zoom segments are SOURCE-keyed while the camera animation clock is EDITED-keyed, so a cut landing inside a zoom segment makes the pulse phase jump. macOS's segment model differs enough that neither has a copyable answer.
- **The composition is already correct for it.** `CameraAnimationParams::zoom_scale` and the intro/outro scale already compose multiplicatively about the same bubble centre, and the canvas clamp runs before the slide translation — a pulse scale would drop into the same product with no restructuring. That part is done.
- **Start at:** `windows/runner/Capture/Zoom/zoom_export_controller.{h,cpp}` (add `segment_active` / `segment_start_ms` to `Frame`), then the preview's segment problem at `windows/runner/preview/preview_compositor.cpp` (the click-hold block) — note `getZoomSegments` proves segments CAN be built from the cursor sidecar the preview already loads, and `previewSetZoomSegments` is a registered no-op.
- **Effort:** human ~1 week / CC ~1 day, nearly all of it the preview zoom convergence, plus on-device phase comparison that CI cannot do.



### Camera intro/outro may run on a different time base in the preview vs the export (UNTRIMMED clips only)

- **What:** On a clip with no cuts, the preview and the export derive the animation clock from different sources, so a fade-in / slide-out could start and finish at slightly different absolute times on each side. Trimmed projects are NOT affected — both sides use the edited position and edited duration there, which is the case the animation port was built and reasoned about.
- **The specific divergence.** Export rebases to the first decoded video frame: `frame_ms = (timestamp - first_video_hns) / 10000` and `camera_total_ms = (duration_hns - first_video_hns) / 10000` (`windows/runner/Capture/Export/export_pipeline.cpp:1097-1103`, `:1385-1394`). The preview uses the MediaPlayer's own clock: `CurrentPlaybackUs()` and `PlaybackSession().NaturalDuration()` (`windows/runner/preview/preview_engine.cpp:1434-1446`). Those agree only when the container's PTS base is zero.
- **Why the export bothers to rebase**, per its own comment: raw `MF_PD_DURATION` keeps the container's PTS base, and an unrebased duration pushes the outro window past the last reachable `frame_ms`, so the outro never completes. That is the failure this rebasing exists to prevent — which is the reason to suspect the un-rebased preview side rather than the export.
- **Not observed, only derived.** Found by reading both clocks while wiring the preview animation (PR #419); no recording has been measured. Our own screen recordings may well have a zero PTS base, in which case the two agree today and this is latent rather than live. Do not "fix" it before measuring.
- **How to settle it:** open a real untrimmed recording, log `first_video_hns` from the export path and `NaturalDuration` / position from the preview path for the same file, and compare. Zero base and equal durations → close this as a non-issue and record that. Non-zero → rebase the preview clock the same way the export does, which keeps one definition of "clip time" instead of two.
- **Start at:** `windows/runner/preview/preview_engine.cpp:1434-1446` (where `emit_pos_ms` / `emit_dur_ms` are produced on the MediaPlayer path) and `windows/runner/Capture/Export/export_pipeline.cpp:1385-1394` (the rebasing it should match).
- **Effort:** human ~2h / CC ~30min, most of it the measurement.

## Windows — bridge routers

### ~~Camera-composition arg-parsing dedupe (shared Bridge/Routers helper)~~ — DONE
- Landed with the intro/outro preview slice as
  `Bridge/Routers/camera_composition_args.{h,cpp}`, following the
  `color_grade_args` pattern. Both `preview_router`
  (previewSetCameraPlacement) and `export_router` (processVideo) now call
  `clingfy::bridge::ReadCameraComposition`.
- The prediction in this entry was correct twice over: after the
  missing-chroma bug, the two parsers had drifted AGAIN — neither read the four
  `cameraIntroPreset` / `cameraOutroPreset` / `cameraIntroDurationMs` /
  `cameraOutroDurationMs` keys, so the inline preview never animated while the
  export did. Covered by `camera_composition_args_test.cpp`.

### Log files lose their beginning while the app is still running

- **What:** The current day's log file is silently rewritten mid-session, losing everything written before some point. The app never recovers the lost lines; it just keeps appending after them.
- **Reproduced twice, with evidence.**
  - `logs_2026-07-27.jsonl` was 313,453 bytes / 917 rows at 22:31 local. Four minutes later: 3,439 bytes / 7 rows.
  - `logs_2026-07-28.jsonl` carries `sessionId 2026-07-27T22:12:15Z`, but its earliest surviving row is `22:14:39Z` — **2.4 minutes of that session's own output is missing from the front**, and the file contains no `Logger initialized` line even though `Log.init` emits one on every launch.
- **Therefore it is not launch-time truncation.** The loss happens while a session is running, and appends continue normally afterwards (the file was back to 138 KB / 294 rows within minutes).
- **Why it matters:** Diagnosis has now been blocked by this twice. The camera-finalize root cause is still unknown specifically because the deciding lines were destroyed while being investigated. Every logging improvement is worth less than it looks until this is fixed.
- **Ruled out, each by reading the code:** `FileLogSink` only ever appends (`FileMode.append`, `file_log_sink.dart:125`) and its single `delete()` (:183) is inside `_pruneOldLogs`, which compares the *filename* date against `today - 30 days` and so cannot touch the current file. `Log.init` (`logger_service.dart:159`) creates no file and truncates nothing. On macOS the native side only ever *reads* the path — `getTodayLogFilePath`, `revealTodayLogFile`, `revealLogsFolder` and `StorageDiagnosticsService` all stat or reveal, none write. `AppPaths.ensureDirectory` calls `createDirectory(withIntermediateDirectories:)`, which does not delete. There is no log-clearing UI; `logsBytes` is display-only.
- **So the writer is outside the app's logging path.** Candidates, in the order worth testing: a second app instance sharing the file, an external tail/editor/sync tool rewriting it, or a crash-and-restart cycle that reopens the path without append.
- **How to reproduce cheaply:** `while :; do stat -f "%z %m" logs_$(date +%F).jsonl; sleep 5; done` while using the app, and note what is on screen when the size drops.
- **Start at:** `lib/core/logging/file_log_sink.dart`, `lib/core/logging/logger_service.dart:159`.
- **Effort:** human ~2h / CC ~30min once the drop is caught in the act.

### Confirm a Bluetooth SPEAKER is warned about
- **What:** Verify that a Bluetooth loudspeaker (not a headset) triggers the speaker-bleed warning.
- **Why:** This is the last unresolved half of the old "disambiguate Bluetooth and USB routes" item. `AudioOutputRouteProbe` now prefers `kAudioStreamPropertyTerminalType`, which resolved the headset case on real hardware — a JBL WAVE100TWS earbud reports `'hdph'` and correctly produces no warning, verified live. A Bluetooth *speaker* has never been measured: if it reports `'spkr'` or a USB-AC speaker code it is already handled, but if it reports `'hdph'` or `0` the warning will be missed, and a missed warning ruins an unrepeatable take.
- **Also unmeasured:** USB headsets and USB desk speakers. Both fall back to the transport type, which returns `unknown` for USB, i.e. no warning either way.
- **How (10 seconds per device):** connect the device, run `tools/audio/probe_audio_output_route.swift`, and add the row to that file's header table. Only extend `routeFromTerminalType` for codes actually observed — mapping from the USB spec alone is how a confident wrong answer gets shipped.
- **Start at:** `macos/Runner/Capture/Audio/AudioOutputRoute.swift` (`routeFromTerminalType`), `macos/RunnerTests/RunnerTests.swift` (`testTerminalTypeResolvesRoutesTransportTypeCannot`).
- **Effort:** human ~15min / CC ~10min once a row exists.

### Windows AAC profile-level is pinned to "2ch / 48 kHz" while the rate is configurable
- **What:** Both Media Foundation AAC writers hardcode `MF_MT_AAC_AUDIO_PROFILE_LEVEL_INDICATION = 0x29`, which specifies AAC-LC at **2 channels, 48 kHz**, while the surrounding encoder config (`mf_encoder_config.h`) validates and permits **44.1 kHz** as well.
- **Why:** A 44.1 kHz export would declare a profile level that does not describe the stream it contains. Today nothing reaches that path — the config defaults to 48 kHz and WASAPI capture hard-rejects any endpoint that is not 48 kHz float32 stereo — so this is latent, not live. It becomes real the moment 44.1 kHz is selectable or WASAPI accepts a wider range.
- **Context:** Found by the completeness sweep during the 2026-07-26 macOS export `-11861 "Cannot Encode Media"` investigation. The macOS side of that bug class was the same shape: an encoder parameter fixed independently of the source. macOS is now fixed via `AACEncoderSettings`; Windows has no equivalent single source of truth.
- **Do NOT "fix" this speculatively.** Changing a profile-level indicator without a stream that actually exercises it is how a working encoder gets broken. Wait until 44.1 kHz is genuinely reachable, then derive the indicator from the configured rate and channels.
- **Start at:** `windows/runner/Encoding/mf_sink_writer_encoder.cpp:220-232`, the sibling MF writer, and `windows/runner/Encoding/mf_encoder_config.h:45-57`.
- **Effort:** human ~1h / CC ~15min once reachable.

