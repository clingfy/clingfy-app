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
