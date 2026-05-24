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

| Phase | Goal                                                          |
| ----- | ------------------------------------------------------------- |
| 0     | App launches; native bridge stubs; no MissingPluginException  |
| 1     | Full bridge contract parity (every method routed, stubbed)    |
| 2     | Real device / target discovery                                |
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

## Current status — Phase 0

Phase 0 establishes the Windows native bridge so the app boots without
crashing and every native call from Flutter is intercepted.

Shipped in this phase:

- `windows/runner/Bridge/native_channel_names.h` — channel name constants
  shared with Dart.
- `windows/runner/Bridge/native_error_codes.h` — error code constants
  shared with Dart.
- `windows/runner/Bridge/method_dispatcher.{h,cpp}` — registers the
  `com.clingfy/screen_recorder` method channel with a catch-all handler that
  returns `WINDOWS_NOT_IMPLEMENTED` for every method.
- `windows/runner/Bridge/event_channel_stubs.{h,cpp}` — registers all four
  event channels with no-op stream handlers so `receiveBroadcastStream()`
  never throws at startup.
- `WINDOWS_NOT_IMPLEMENTED` added to `NativeErrorCode` on the Dart side.

What works after Phase 0:

- `flutter run -d windows --flavor dev --dart-define-from-file=.env.dev`
  launches the app.
- The home shell, settings, and licensing UI render under fluent_ui.
- Recorder actions return a clean structured error instead of crashing.

What does not work yet: any actual recording, preview, export, or device
enumeration. Those are Phases 2–9.

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

flutter run -d windows --flavor dev --dart-define-from-file=.env.dev
```

Build a release exe:

```powershell
flutter build windows --flavor dev  --dart-define-from-file=.env.dev
flutter build windows --flavor prod --dart-define-from-file=.env.prod
```

> Flavor support on Windows is wired the same way as macOS; both flavors
> share the same exe name today and differ only in the bundled dotenv.
> Separate per-flavor installers land in Phase 10.

## Validation before committing Windows changes

For changes that touch Dart code:

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze test
flutter analyze lib
flutter test
```

For changes to `windows/runner/`, build the Windows target on a Windows host
(macOS CI cannot build the Windows runner). At minimum:

```powershell
flutter build windows --flavor dev --dart-define-from-file=.env.dev
```

Windows-side native tests will land alongside the engine in Phase 3+. Until
then, manual verification on a real Windows box is the bar.

## Risks to watch

- Trying to port camera overlay before basic recording is stable.
- Scattering raw Media Foundation calls instead of wrapping them.
- Audio/video sync — log timestamps from day one.
- Assuming macOS TCC semantics; Windows uses per-device privacy settings.
- Overengineering toward full parity instead of shipping an MVP first.
