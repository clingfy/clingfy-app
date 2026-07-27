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

## Windows — bridge routers

### Camera-composition arg-parsing dedupe (shared Bridge/Routers helper)
- **What:** Extract the duplicated camera-composition parsing (`preview_router.cpp` `ReadCameraComposition` + `export_router.cpp` `HandleProcessVideo`) into one shared `Bridge/Routers` helper, following the `color_grade_args` pattern.
- **Why:** The duplication already hid a missing-chroma bug once (caught in the 9.7 review). Two parsers for one wire shape will drift again.
- **Context:** Deferred in the 2026-07-03 eng review of the color-grade port (editing step 2). PR-2a introduces `Bridge/Routers/color_grade_args.{h,cpp}` — one parser used by both routers — which is exactly the shape the camera parsing should adopt. Deferred because touching two hot routers for zero user-visible change would widen an already-full color slice.
- **Pros:** Kills the parser-drift bug class for camera args; makes the routers smaller.
- **Cons:** Pure refactor — no user-visible change; needs careful diffing of the two existing parsers (they may have drifted already, which is the point).
- **Start at:** `windows/runner/Bridge/Routers/preview_router.cpp` (`ReadCameraComposition`), `windows/runner/Bridge/Routers/export_router.cpp` (`HandleProcessVideo` camera block); model on `Bridge/Routers/color_grade_args.{h,cpp}` once PR-2a lands.
- **Depends on:** PR-2a (color_grade_args establishes the pattern).
- **Effort:** human ~2h / CC ~15min.

### Today's log file was destroyed mid-session, and nothing explains it

- **What:** `logs_2026-07-27.jsonl` was 313,453 bytes / 917 rows at 22:31 local. Four minutes later it was 3,439 bytes / 7 rows, and its earliest surviving entry was 19:35 UTC — every line before that, including a recording failure under investigation, was gone.
- **Why it matters:** This is the second time diagnosis has been blocked by missing evidence rather than by difficulty. The whole point of the shortcut-diagnostics work was "next time, grep the log" — that promise is void if the log does not survive the session it describes. A failure that makes the user restart is exactly the case where the previous run's log matters most.
- **Ruled out, with evidence:** the Dart sink appends (`FileMode.append`, `file_log_sink.dart:125`) and never truncates; `_pruneOldLogs` (:163) deletes only files whose *filename date* is before `today - 30 days`, so it cannot touch today's; macOS native only computes the path (`AppPaths.logFileURL`, referenced once at `MainFlutterWindow.swift:1460`) and never writes the file. No log-clearing UI exists — `logsBytes` is display-only in the storage section.
- **Not yet explained.** Candidates worth testing: two app instances running against one file, an external tool or editor rewriting it, or a crash mid-write leaving a truncated file that later appends extend. Do NOT "fix" this speculatively — reproduce first by watching the file across an app restart and a forced crash.
- **How to start:** `stat -f '%z %m' logs_$(date +%F).jsonl` in a loop across a start/stop/crash cycle, and check whether the size ever drops.
- **Start at:** `lib/core/logging/file_log_sink.dart`, `lib/core/logging/logger_service.dart:159` (`Log.init`).
- **Effort:** human ~2h / CC ~30min once reproduced.

## Recording — audio capture

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

