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
| 3     | MVP recording (full display + mic + system audio → MP4)       | in progress (3A+3B done, 3C next) |
| 4     | Lifecycle parity (state machine, pause/resume, recovery)      |
| 5     | Preview player + project reopen                               |
| 6     | Basic export + post-processing (resolution, background, etc.) |
| 7     | Window + area recording                                       |
| 8     | Cursor sidecar + smart zoom                                   |
| 9     | Camera overlay (basic, then advanced compositing/chroma)      |
| 10    | Permissions UX + installer + updater + Windows beta polish    |

Detailed scope per phase is tracked in the session task list and in
[../CLAUDE.md](../CLAUDE.md).

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
| 3C | MP4 / H.264 video writer (Media Foundation Sink Writer) | next |
| 3D | WASAPI microphone + system-audio capture, mixed into the MP4 | |
| 3E | Project manifest + workflow events so Flutter sees a real recording | |

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
| `router_stub_shapes_test.cpp` | Per-method stub shapes: setters return success+null, getters return the documented list/map/bool/null, `startRecording` / `stopRecording` / `exportVideo` / `processVideo` return `WINDOWS_NOT_IMPLEMENTED`, `getStorageSnapshot` carries all ten required keys, etc. The Phase 2 `DeviceListGettersReturnList` case checks `getDisplays` / `getAppWindows` / `getAudioSources` / `getVideoSources` shape (list-of-maps with the documented keys) without assuming any particular count. |
| `device_record_test.cpp` | Pure formatters that translate the Phase 2 `DisplayRecord` / `AppWindowRecord` / `AudioSourceRecord` / `VideoSourceRecord` structs into the EncodableMap shape Dart parses. Bounds-omission for incomplete `AppWindowRecord`, int64 widths for ids, double widths for coordinates. |

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
