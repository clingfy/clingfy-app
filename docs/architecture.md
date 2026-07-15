# Architecture

Clingfy is a **thin Flutter desktop shell driving a substantial native engine**.
The Flutter layer (`lib/`) is the UI, the workflow state machine, the domain model
(zoom segments, export settings, licensing), and the bridge contract. The native
layer (`macos/Runner/`, Swift) does the heavy lifting: real screen/audio/camera
capture, live preview rendering, and final video composition/export.

This document describes the macOS + Flutter system. Windows mirrors the same
Flutter↔native contract with a C++ engine under `windows/runner/`; see
[`windows-port.md`](windows-port.md) for that side.

> Boundary intent (`CONTRIBUTING.md`): reusable recorder/domain logic →
> `lib/core`; product workflow → `lib/app`; monetization → `lib/commercial`;
> primitives → `lib/ui`. Do not pull `lib/app` imports into `lib/core`.

## Big picture

The architectural seam — the single most important thing to understand — is the
**Flutter↔native bridge**. Almost every non-trivial feature crosses it. Flutter
owns *intent and data* (portable Dart objects); native owns *pixels and time*
(AVFoundation / ScreenCaptureKit / Core Animation).

```
┌──────────────────────────────────────────────────────────────────┐
│ FLUTTER SHELL (lib/) — portable Dart                               │
│  lib/app/        product shell: home workflow, settings, bootstrap │
│  lib/core/       domain: recording, preview, zoom, export, models  │
│  lib/commercial/ licensing / paywall / entitlement gates           │
│  lib/ui/         theme tokens, shared widgets                       │
│  lib/l10n/       localized strings (.arb)                           │
│  State: ChangeNotifier + Provider. Controllers own workflow phase. │
└───────────────────────────────┬──────────────────────────────────┘
                                 │
              ┌──────────────────┴───────────────────┐
              │  THE BRIDGE  (lib/core/bridges/)      │
              │  NativeBridge.instance (singleton)    │
              │  1 method channel  com.clingfy/screen_recorder
              │  4 event channels  workflow / player / device / updater
              └──────────────────┬───────────────────┘
                                 │
┌────────────────────────────────┴─────────────────────────────────┐
│ NATIVE ENGINE  (macos/Runner/, Swift)                             │
│  Capture/ → Preview/ → Overlays/ → Export(composition) → Services │
│  ScreenRecorderFacade = orchestration entry point                 │
│  AVFoundation / ScreenCaptureKit / Core Animation / Core Image    │
└────────────────────────────────────────────────────────────────────┘
```

## End-to-end flow: one recording, capture → export

1. **Start (Flutter → native).** `HomeActions.toggleRecording()`
   (`lib/app/home/home_actions.dart`) validates the target and optional countdown
   → `RecordingController.startRecording()`
   (`lib/app/home/recording/recording_controller.dart`) →
   `NativeBridge.invokeMethod('startRecording', …)`. macOS:
   `ScreenRecorderFacade.startRecording()` → `RecordingSessionCoordinator`
   (preflight: permission + target) → `CaptureBackendFactory.make()` picks
   ScreenCaptureKit (macOS 15+) or AVFoundation → a `.clingfyproj` bundle is
   created.
2. **Capture loop (native).** The backend writes `capture/screen.mov`;
   `CursorRecorder` samples the cursor → `capture/cursor.json`; optional
   `CameraRecorder` → `camera/raw.mov`; audio is captured as separate per-source
   tracks by `SourceAudioRecorder` — mic → `capture/mic.m4a`, system audio →
   `capture/system.m4a` (`MicEchoCanceller` cleans the mic downstream, cached via
   `CleanedMicCache`). The
   **workflow** event channel emits `recordingStarted` … `recordingFinalized`;
   `RecordingController` advances `WorkflowPhase`
   (`idle → recording → finalizingRecording → previewReady`).
3. **Preview.** `PreviewEngine.processVideo()` builds a `PreviewScene`;
   `InlinePreviewView.swift` is the live render surface (a `CALayer` tree:
   `canvasBackground → zoomedContentLayer → playerLayer + cursorLayer`, plus
   `cameraContainerLayer`), updated on a 60 Hz tick. The **player** event channel
   emits `playerStateChanged / positionChanged / durationChanged` →
   `PlayerController` (`lib/core/preview/player_controller.dart`).
4. **Post-processing edits (live).** `PostProcessingController`
   (`lib/app/home/post_processing/post_processing_controller.dart`) holds canvas
   state (background, camera placement, audio gain/normalize, cursor size, zoom,
   color grade, clips). Zoom, clips, and color are full editors:
   `ZoomEditorController` (`lib/core/zoom/`) keeps auto + manual + effective
   segments and an **undo stack of `ZoomEditCommand`s**, syncing live to native
   via `previewSetZoomSegments` (debounced); `ClipEditorController`
   (`lib/core/clips/` — split/cut/trim/reorder) syncs via `previewSetClips`; and
   the color-grade commands (`lib/core/color/` + `lib/core/timeline/`) sync via
   `previewSetColorGrade`. All share the `EditSession` undo/redo model. Each edit
   crosses the bridge immediately.
5. **Export.** `HomeActions.exportFromUi()` runs the **license gate**
   (`LicenseController.canExport`) → `exportVideo`. macOS: `ExportEngine.export()`
   → `LetterboxExporter.export()` in three stages — (a) screen prepass
   `ScreenZoomCursorIntermediatePipeline` bakes zoom + cursor, (b) camera prepass
   `CameraStyledIntermediatePipeline`, (c) final `CompositionBuilder.build()`
   assembles an `AVMutableVideoComposition` + `AVVideoCompositionCoreAnimationTool`
   layering background/screen/cursor/zoom/camera, applying the color grade
   (`ColorGradeRenderer`) and re-tiling video+audio tracks to the kept/reordered
   clip ranges, with audio gain/normalize in the same composition path. Progress
   streams back via `updateExportProgress(double)`.

**Key property for new features:** the export composition *already bakes effects*
(zoom, cursor, camera, background, color grade, clip cuts/reorder) into the
output. Any new editing effect follows the same pattern — model in Dart, sync to
preview live, add a pass in the export path. Color correction and clip editing
(shipped in 1.0.5) followed exactly this pattern; the remaining roadmap in
[`editing-platform-plan.md`](editing-platform-plan.md) (subtitles, richer audio)
builds on the same seam.

## Capture pipeline

`macos/Runner/Capture/`:

- `ScreenRecorderFacade.swift` — orchestration entry point invoked by the bridge.
- `Engine/RecordingEngine.swift`, `RecordingSessionCoordinator.swift` — session
  lifecycle and preflight.
- `Backends/CaptureBackendScreenCaptureKit.swift`,
  `Backends/CaptureBackendAVFoundation.swift`, `CaptureBackendFactory.swift` —
  dual capture backends; ScreenCaptureKit on macOS 15+, AVFoundation fallback.
- `Cursor/CursorRecorder.swift` — cursor position/shape sampling → `cursor.json`.
- `CameraRecorder.swift` — optional camera capture → `camera/raw.mov`.

The recording is written into a `.clingfyproj` bundle (see below), fragmentized
for crash resilience.

## Overlay rendering

`macos/Runner/Overlays/` and `macos/Runner/Views/`:

- `Overlays/Camera/CameraOverlay.swift` — the floating picture-in-picture camera
  bubble (`NSPanel`), with shape/border/shadow/chroma options; user-movable
  (`cameraOverlayMoved` callback to Flutter).
- `Views/RecordingIndicatorView.swift` — the floating recording indicator
  (pause/stop/resume).
- `Views/CursorView.swift` — cursor visualization.

Live preview compositing happens in `Preview/InlinePreviewView.swift` (the 60 Hz
`CALayer` tree above); `Preview/CursorFrameResolver.swift` and
`Preview/PreviewProfile.swift` resolve cursor frames and preview profiles.

## Export engine

`macos/Runner/Capture/Export/`:

- `ExportEngine.swift` — validates inputs, resolves output path.
- `LetterboxExporter.swift` — orchestrates the multi-stage export.
- `ScreenZoomCursorIntermediatePipeline.swift` — screen prepass (zoom + cursor →
  HEVC-with-alpha intermediate).
- `CameraStyledIntermediatePipeline.swift` — camera prepass (chroma key /
  styling).
- `CompositionBuilder.swift` — the core compositor
  (`AVMutableVideoComposition` + `AVVideoCompositionCoreAnimationTool`); also
  carries audio gain/normalize. Outputs MP4/MOV/GIF.

> There is **no** `AudioMixEngine.swift` — audio gain/normalize lives in the
> export composition path. `macos/Runner/Capture/Audio/` holds
> `SourceAudioRecorder.swift` (separated mic/system capture),
> `MicEchoCanceller.swift` + `CleanedMicCache.swift` (echo cancellation), and
> the level monitors `AudioLevelEstimator.swift` / `MicrophoneLevelMonitor.swift`.

**Render constraint to know:** `AVVideoCompositionCoreAnimationTool` forces a
slow manual render path and degrades past ~100 `CALayer`s. Effects that add
on-canvas elements (captions, overlays, filters) pile onto this ceiling.

## Flutter/native bridge

`NativeBridge` (`lib/core/bridges/native_bridge.dart`) is a singleton
(`NativeBridge.instance`) owning the method channel, the broadcast event streams,
and the callback registry native code invokes.

| Channel | Direction | Purpose |
|---|---|---|
| `com.clingfy/screen_recorder` | Flutter→native (method) | All commands |
| `screen_recorder/events` | native→Flutter | Device changes, mic levels |
| `player/events` | native→Flutter | Playback state |
| `workflow/events` | native→Flutter | Recording lifecycle, preview, project-open |
| `updater/events` | native→Flutter | Update checks (Sparkle) |

Representative commands (Flutter → native): `startRecording` / `stopRecording` /
`pauseRecording` / `resumeRecording`, device enumeration (`getDisplays`,
`getAppWindows`, `getAudioSources`), target selection
(`setDisplayTargetMode`, `pickAreaRecordingRegion`), camera overlay config
(`showCameraOverlay`, `setCameraOverlay*`), preview
(`previewOpen` / `previewPlay` / `previewSeekTo` / `previewSetZoomSegments` /
`previewSetCameraPlacement`), and `exportVideo` / `cancelExport`.

Representative events/callbacks (native → Flutter): lifecycle
(`recordingStarted/Finalized/Failed`), preview (`previewReady/previewFailed`),
`openProjectRequest`, playback (`playerStateChanged/positionChanged`), device
hot-plug + `microphoneLevel`, `updateExportProgress`, and native-UI callbacks
(`indicatorPause/Stop/ResumeTapped`, `cameraOverlayMoved`,
`nativeSelectionChanged`). Native also calls back into Flutter via
`getLocalizedStrings` to fetch the current locale's strings.

### Keeping the contract in sync

- **Channel names, event types, and error codes are named constants** kept in
  sync across the languages: Dart `lib/core/bridges/native_method_channel.dart`
  and `native_error_codes.dart`, Swift `macos/Runner/Core/NativeChannel.swift`
  (and friends), Windows `windows/runner/Bridge/native_channel_names.h`. Sync
  tests guard drift (`test/core/bridges/native_error_codes_sync_test.dart`,
  Windows `bridge_contract_coverage_test.cpp`).
- **Command method names are currently inline string literals** in
  `native_bridge.dart` (e.g. `'previewSetZoomSegments'`), *not* constants in
  `native_method_channel.dart` (which holds only event/callback names). Promoting
  them to constants is tracked as foundation work in
  [`editing-platform-plan.md`](editing-platform-plan.md).

When adding a method or event, update the constant in **all** language files,
add a `NativeBridge` wrapper (and a callback setter if inbound), implement the
macOS handler (dispatched from `MainFlutterWindow.swift` / routers like
`PermissionsMethodRouter` → `ScreenRecorderFacade`), add the Windows handler/stub,
add error codes if new failures exist, and test both sides.

## Flutter side map (`lib/`)

| Area | Contents |
|---|---|
| `lib/app/bootstrap/` | `AppBootstrap → AppRunner → AppProviders → PlatformApp`; error handlers, window config, Sentry |
| `lib/app/home/` | The workflow: `HomeShell`, `HomeActions`, `HomeBindings`, `WorkflowPhase` + `recording/ preview/ post_processing/ overlay/` |
| `lib/app/settings/` | `SettingsController` (composite) + section UIs (SharedPreferences) |
| `lib/core/` | Domain: `recording/ preview/ zoom/ clips/ color/ timeline/ export/ post_processing/ overlay/ devices/ models/ bridges/` — **no `lib/app` imports here** |
| `lib/commercial/licensing/` | `LicenseController`, `LicenseService`, `PaywallDialog` (backend/signing not in repo) |
| `lib/ui/` | `app_theme.dart` (token classes + Material/macOS builders), shared widgets |
| `lib/l10n/` | `app_*.arb` source — **never hand-edit generated `app_localizations*.dart`** |

State management is uniformly `ChangeNotifier` + `provider`; controllers subscribe
to `NativeBridge` event streams, expose derived getters, and debounce live edits.

## Native side map (`macos/Runner/`)

| Area | Key files |
|---|---|
| **Capture/** | `ScreenRecorderFacade`, `Engine/RecordingEngine`, `Backends/CaptureBackend*`, `Cursor/CursorRecorder`, `CameraRecorder` |
| **Preview/** | `InlinePreviewView`, `CursorFrameResolver`, `PreviewProfile`, `PreviewEngine` |
| **Overlays/ + Views/** | `Camera/CameraOverlay`, `RecordingIndicatorView`, `CursorView` |
| **Capture/Export/** | `ExportEngine`, `LetterboxExporter`, `CompositionBuilder`, prepass pipelines |
| **Capture/Audio/** | `SourceAudioRecorder` (separated mic/system tracks), `MicEchoCanceller`, `CleanedMicCache`, `AudioLevelEstimator`, `MicrophoneLevelMonitor` |
| **Services/** | `RecordingStore`, `RecordingProjectManifest/Paths`, `PreferencesStore` |
| **Platform/** | `DisplayService`, `MenuBarController` |
| **Permissions/** | `PermissionsMethodRouter`, `ScreenRecorderFacade+Permissions` (TCC) |
| **Core/** | `NativeChannel`, `NativeErrorCode`, `PrefKeys` |
| **Bridges/** | `MainFlutterWindow` (dispatch), event bridges, `Runner-Bridging-Header.h` |

## The `.clingfyproj` bundle

The durable artifact and the natural home for editor state:

- `project.json` — manifest.
- `capture/` — `screen.mov`, `screen.meta.json`, `cursor.json`,
  `zoom.manual.json`, `mic.m4a`, `system.m4a` (separated mic/system audio).
- `camera/` — `raw.mov`.
- `editor_state.json` — durable canvas/color state (via `CanvasAppearanceStore`).
- `clips_state.json` — persisted clip edits (`ClipStateStore`,
  `lib/core/clips/clip_state_store.dart`).
- `post/state.json` — the timeline document read/written by `TimelineCodec`
  (`lib/core/timeline/codec/`).
- `derived/` — generated artifacts.

## Concurrency

Public native APIs run `@MainActor`; capture/export use internal
`DispatchQueue` / `async-await`. Export is single-session (no concurrent exports).

## Flavors & configuration

Builds are flavor-aware (`dev` / `prod`) with matching dotenv files
(`--dart-define-from-file=.env.dev|.env.prod`). The macOS Runner uses two bundle
ids: `com.clingfy.clingfy` (prod) and `com.clingfy.clingfy.dev` (dev); TCC
permission state is per-bundle-id. See `docs/development.md` for setup.

## Related docs

- [`editing-platform-plan.md`](editing-platform-plan.md) — turning this engine
  into a light editor (foundation + roadmap).
- [`windows-port.md`](windows-port.md) — the Windows C++ engine mirroring this
  contract.
- [`branching-strategy.md`](branching-strategy.md) — branch/release workflow.
