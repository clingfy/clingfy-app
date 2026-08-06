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

