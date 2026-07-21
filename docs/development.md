# Development

This document covers the public development workflow for the Clingfy desktop app. macOS is the primary target; the Windows port (beta) has its own build/test notes in `windows-port.md` and tester docs in `windows-beta-tester-guide.md`.

## Tooling

- Flutter stable
- Xcode
- CocoaPods
- macOS developer toolchain for building the native runner

## Getting started

```bash
flutter pub get
flutter analyze
flutter test
```

## Running and building the macOS app

Use explicit flavors when working with the macOS app:

```bash
flutter run -d macos --flavor dev
flutter build macos --flavor dev
flutter build macos --flavor prod
```

The repository intentionally does not include private environment files or signing material. Maintainer-only flows that depend on private configuration expect those values to be provided separately.

## Native macOS notes

- Native implementation lives under `macos/Runner`.
- Flutter drives the product shell and UI, while capture, preview, export, overlays, permissions, and updater integration are handled in native macOS code.
- If you change native capture or release behavior, verify both a Flutter test/analyze pass and a macOS build.

## Interactive UI testing (flutter_driver + Dart MCP)

The app can be driven live — screenshot the running UI, tap/navigate, set fields, read runtime errors — via the [Dart & Flutter MCP server](https://dart.dev/tools/mcp-server) (`dart mcp-server`) plus `flutter_driver`. It is useful for layout regressions and editor/preview/export behavior.

The driver extension is gated behind a compile-time define so it never ships (`lib/main.dart` calls `enableFlutterDriverExtension()` only when `ENABLE_FLUTTER_DRIVER=true`, ahead of `ensureInitialized()`). `flutter_driver` is a regular dependency on purpose — `lib/main.dart` imports it — and tree-shakes out when the define is false.

Agent config is per-developer (`.mcp.json`, `.claude/`, and `CLAUDE.md` are gitignored), so each contributor sets up their own MCP once. With Claude Code:

```bash
claude mcp add --transport stdio dart -- dart mcp-server
```

Launch the app with your flavor + dotenv, plus the define:

```bash
flutter run -d macos   --flavor dev --dart-define-from-file=.env.dev --dart-define=ENABLE_FLUTTER_DRIVER=true
flutter run -d windows              --dart-define-from-file=.env.dev --dart-define=ENABLE_FLUTTER_DRIVER=true
```

What it can and cannot reach — this is a screen recorder, so the boundary matters:

- **Drivable** (the main Flutter window's widget tree): target/display selection, camera config, settings, the paywall, and the whole post-processing surface — zoom, clips, color, audio (incl. Voice Cleanup), export settings.
- **Not drivable** (separate native windows): the floating recording indicator (its **Stop** lives here), the camera-overlay bubble, the area-selection overlay, save dialogs, and permission prompts. A "start → stop a real recording" loop breaks at Stop. Those overlays call back into Flutter (`indicatorStopTapped`, `cameraOverlayMoved`, `areaSelectionCleared`, … in `NativeBridge`), so exercise the handlers at the bridge level in `test/` instead.

Practical loop: drive the editor/preview/export against an existing `.clingfyproj` via the preview-open path rather than a real capture each iteration. Visual/pixel correctness (orientation, color, dither, chroma-key edges, "does the zoom look right") stays a human smoke-test.

Caveats:

- Enabling the driver **disables real keyboard input** (typing is dropped). Use `enableFlutterDriverExtension(enableTextEntryEmulation: false)` to type by hand, but then the MCP's `enterText` stops working.
- Grant screen-recording permission by hand once (TCC / Windows privacy), or a fresh run blocks on a dialog the driver can't dismiss.

## Permission reset tips

For a clean permission test cycle on macOS, quit the app and reset the relevant bundle identifier in TCC:

```bash
tccutil reset All com.clingfy.clingfy
tccutil reset All com.clingfy.clingfy.dev
```

You can also clear app preferences when needed:

```bash
defaults delete com.clingfy.clingfy
defaults delete com.clingfy.clingfy.dev
```

## Release tooling

Release automation lives in `ops/release`. Those scripts are public, but they depend on private credentials and secure files that are intentionally not stored in the repository.

See [../ops/release/README.md](../ops/release/README.md) for the release tooling overview.
