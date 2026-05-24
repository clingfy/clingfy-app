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
| 2     | Real device / target discovery                                | next   |
| 3     | MVP recording (full display + mic + system audio → MP4)       |
| 4     | Lifecycle parity (state machine, pause/resume, recovery)      |
| 5     | Preview player + project reopen                               |
| 6     | Basic export + post-processing (resolution, background, etc.) |
| 7     | Window + area recording                                       |
| 8     | Cursor sidecar + smart zoom                                   |
| 9     | Camera overlay (basic, then advanced compositing/chroma)      |
| 10    | Permissions UX + installer + updater + Windows beta polish    |

Detailed scope per phase is tracked in the session task list and in
[../CLAUDE.md](../CLAUDE.md).

## Current status — Phase 1

Phase 0 stood up the bridge scaffolding (a catch-all method handler plus
no-op event-channel stubs) so the app could boot without throwing
`MissingPluginException` at startup.

Phase 1 — **full bridge contract parity** — replaces that catch-all with a
per-method router. Every method on the Dart bridge contract has an explicit
handler that returns a shape-correct stub. The Flutter UI can now walk
through its full startup sequence (settings hydration, permissions probe,
device enumeration, post-processing prefs) without the bridge surfacing a
wall of errors.

### Layout

```
windows/runner/Bridge/
  method_dispatcher.{h,cpp}      table-based dispatch; unknown method →
                                 WINDOWS_NOT_IMPLEMENTED
  result_helpers.h               small reply helpers
  native_channel_names.h         channel name constants
  native_error_codes.h           error code constants
  event_channel_stubs.{h,cpp}    no-op event channels

  Routers/
    recording_router.{h,cpp}     startRecording, lifecycle, capabilities,
                                 recording settings
    devices_router.{h,cpp}       getDisplays / getAppWindows / get*Sources,
                                 selection setters, area selection
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

### What works after Phase 1

- `flutter run -d windows --dart-define-from-file=.env.dev` launches the
  app.
- Home shell, settings, post-processing, permissions onboarding, and
  licensing UI all render under fluent_ui without surfacing a wall of
  bridge errors.
- Pre-recording flows (selecting a quality preset, toggling the recorder
  exclusion, opening the camera overlay settings) round-trip cleanly.
- Hitting **Record** or **Export** surfaces a clean
  `WINDOWS_NOT_IMPLEMENTED` error rather than crashing.

### What does not work yet

- No actual recording, preview, export, device enumeration, or permission
  resolution. Those land in Phases 2–10.
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

### What the tests cover (Phase 1)

| File | What it asserts |
|---|---|
| `method_router_test.cpp` | Unknown methods fall back to `WINDOWS_NOT_IMPLEMENTED`; `HasHandler` reflects registration state. |
| `bridge_contract_coverage_test.cpp` | Every method on the Dart bridge contract has an explicit registered handler — the drift-detection net. Update the list here when you add a method to either side. |
| `router_stub_shapes_test.cpp` | Per-method stub shapes: setters return success+null, getters return the documented list/map/bool/null, `startRecording` / `stopRecording` / `exportVideo` / `processVideo` return `WINDOWS_NOT_IMPLEMENTED`, `getStorageSnapshot` carries all ten required keys, etc. |

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
