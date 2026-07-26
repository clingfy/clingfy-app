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

## Recording — audio capture

### Push output-route changes instead of polling at two moments
- **What:** Replace the two-point probe of the audio output route with a CoreAudio property listener on `kAudioHardwarePropertyDefaultOutputDevice` that pushes changes to Flutter over an event channel.
- **Why:** The speaker-bleed warning is only re-probed at app start and when system audio is toggled on. Plug in headphones mid-session without touching the toggle and the warning stays up; unplug them and no warning appears. A stale warning erodes trust in the real one.
- **Context:** Shipped deliberately in the 2026-07-26 audio-honesty branch. A possibly-stale warning was chosen over a possibly-missing one, and the limitation is commented at `RecordingSettingsController.loadPreferences`. The listener is the correct fix but is a real slice: native listener + event-channel plumbing + Dart subscription + tests both sides.
- **Start at:** `macos/Runner/Capture/Audio/AudioOutputRoute.swift` (add the listener), `macos/Runner/Core/NativeChannel.swift` (event name), `lib/core/recording/settings/recording_settings_controller.dart` (`refreshAudioOutputRoute` becomes a subscription).
- **Effort:** human ~3h / CC ~25min.

### Confirm a Bluetooth SPEAKER is warned about
- **What:** Verify that a Bluetooth loudspeaker (not a headset) triggers the speaker-bleed warning.
- **Why:** This is the last unresolved half of the old "disambiguate Bluetooth and USB routes" item. `AudioOutputRouteProbe` now prefers `kAudioStreamPropertyTerminalType`, which resolved the headset case on real hardware — a JBL WAVE100TWS earbud reports `'hdph'` and correctly produces no warning, verified live. A Bluetooth *speaker* has never been measured: if it reports `'spkr'` or a USB-AC speaker code it is already handled, but if it reports `'hdph'` or `0` the warning will be missed, and a missed warning ruins an unrepeatable take.
- **Also unmeasured:** USB headsets and USB desk speakers. Both fall back to the transport type, which returns `unknown` for USB, i.e. no warning either way.
- **How (10 seconds per device):** connect the device, run `tools/audio/probe_audio_output_route.swift`, and add the row to that file's header table. Only extend `routeFromTerminalType` for codes actually observed — mapping from the USB spec alone is how a confident wrong answer gets shipped.
- **Start at:** `macos/Runner/Capture/Audio/AudioOutputRoute.swift` (`routeFromTerminalType`), `macos/RunnerTests/RunnerTests.swift` (`testTerminalTypeResolvesRoutesTransportTypeCannot`).
- **Effort:** human ~15min / CC ~10min once a row exists.
### Surface the bleed warning on the native pre-recording bar
- **What:** Show the speaker-bleed warning on the native pre-recording bar, not only in the Flutter recording sidebar.
- **Why:** The pre-recording bar is the surface a user actually looks at immediately before hitting record. A warning that lives only in the sidebar is missed by anyone who set up once and now starts takes from the bar.
- **Context:** Raised by the pre-landing review of the 2026-07-26 audio-honesty branch, severity low because the sidebar warning does exist and is correct. The bar is a separate native window (`macos/Runner/Overlays/PreRecordingBar/`), so this needs a state push over the existing pre-recording-bar feed rather than a Flutter widget.
- **Start at:** `macos/Runner/Overlays/PreRecordingBar/PreRecordingBarController.swift`, and the bar state feed in `lib/app/home/home_actions.dart`.
- **Effort:** human ~2h / CC ~20min.

### Surface source-audio writer failures to the user
- **What:** Emit a `recordingWarning` when a source-audio segment writer fails to start or is discarded with zero samples, instead of only logging it.
- **Why:** A Bluetooth-headset recording on 2026-07-26 completed "successfully" with **no voice at all**. The only trace was two WARNING lines in `logs_2026-07-26.jsonl`; the UI said nothing, and an unrepeatable take was lost. The encoding cause is fixed (AAC bitrate now scales with the source rate), but the *silent* failure mode is untouched: any future unencodable format loses a take just as quietly.
- **The path already exists.** `ScreenRecorderFacade.backendDidWarn(message:)` emits `recordingWarning` on macOS, `home_bindings.dart:78` already surfaces pending warnings, and `RecordingWarningCode` already defines `micOpenFailed` and `encoderAudioError`. What is missing is a route from `SourceAudioRecorder` (which owns the failure) out to the backend's `handler`.
- **Shape:** give `SourceAudioRecorder` a warning callback, have `CaptureBackendScreenCaptureKit` (its owner, which already holds the handler) forward it to `backendDidWarn`, and localize natively as macOS warnings already do. Assert it end to end by forcing a writer failure with a deliberately unencodable format.
- **Do not weaken it into a log line.** The whole point is that a lost take must be visible while the user can still re-record.
- **Start at:** `macos/Runner/Capture/Audio/SourceAudioRecorder.swift` (the `Failed to start source audio writer` / `Discarding source audio segment` sites), `macos/Runner/Capture/Backends/CaptureBackendScreenCaptureKit.swift` (owner + handler), `macos/Runner/Capture/ScreenRecorderFacade.swift:2848` (`backendDidWarn`).
- **Effort:** human ~3h / CC ~30min.
