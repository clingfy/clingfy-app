# Clingfy Windows Port — Feature Inventory & Planning

Source: full code scan of `lib/`, `macos/Runner/`, `pubspec.yaml`, `docs/`.
Purpose: complete reference for the Windows port of the macOS-first Flutter desktop screen recorder.

Layers:
- Flutter shell (`lib/`) — 100% portable.
- Bridge contract (`lib/core/bridges/`) — platform-agnostic; Windows must satisfy same surface.
- Native engine (`macos/Runner/` → `windows/runner/`) — complete rewrite.

---

## 1. FEATURE INVENTORY

### Recording

| Feature | Location | macOS API | Windows note |
|---|---|---|---|
| Screen recording (full display) | `lib/core/recording/`, `macos/Runner/Capture/` | ScreenCaptureKit + AVFoundation fallback | DXGI Desktop Duplication or Windows.Graphics.Capture |
| Window recording | `macos/Runner/Capture/Backends/CaptureBackendScreenCaptureKit.swift` | SCK + CGWindowListCopyWindowInfo | Windows.Graphics.Capture (HWND target) |
| Area recording | `macos/Runner/Overlays/AreaSelection/` | CGDisplayBounds + NSWindow | DX region capture or GDI region |
| Quality presets (SD/HD720/FHD/2K/4K/8K/Vertical4K/Native) | `lib/core/models/app_models.dart`, `macos/Runner/Core/Models.swift` | AVAssetWriter | Direct port |
| Pause/Resume recording | `lib/app/home/recording/recording_controller.dart`, `CaptureBackendScreenCaptureKit.swift`, `CaptureBackendAVFoundation.swift` | SCK 15+ RecordingOutput pause OR AVAssetWriterInput | Media Foundation sink writer pause |
| Auto-stop after duration | `lib/core/recording/settings/recording_settings_controller.dart` | Timer | Direct port |
| Countdown timer (3/5/10s) | `lib/app/home/recording/countdown_controller.dart` | Timer | Direct port |
| Frame rate control (24/30/60/custom) | `lib/core/recording/`, `macos/Runner/Capture/` | SCK output schedule | DX capture frame rate |
| Recording indicator window | `macos/Runner/Views/RecordingIndicatorView.swift` | NSWindow + AppKit | HWND topmost overlay |
| Project bundle format | `macos/Runner/Services/RecordingProjectManifest.swift` | FileManager + JSON | Direct port |
| Exclude recorder app from capture | `lib/core/recording/settings/recording_settings_controller.dart` | SCK window filter | DX window exclusion |
| System audio capture | `lib/core/recording/`, `macos/Runner/Services/` | AVAudioEngine + AudioUnit + Aggregate Device | WASAPI loopback |
| Microphone capture + gain | `lib/core/recording/`, `macos/Runner/Capture/` | AVCaptureSession audio | WASAPI mic input |
| Mic level monitoring (dBFS) | `lib/core/devices/device_controller.dart`, `Services/AudioDevicesEventHandler` | AVAudioEngine metering | WASAPI metering |
| Exclude mic from system audio | `lib/core/recording/settings/recording_settings_controller.dart` | Aggregate Device config | Wasapi stream separation |
| Recording state machine (Idle → Starting → Recording → Paused → Stopping → Finalizing → PreviewReady → Exporting) | `lib/app/home/recording/recording_controller.dart`, `MainFlutterWindow.swift` | Event channel driven | Direct port |

### Preview

| Feature | Location | macOS API | Windows note |
|---|---|---|---|
| Inline native video preview | `macos/Runner/Preview/InlinePreviewView.swift`, `InlinePreviewViewFactory.swift` | AVPlayer + AVPlayerLayer in NSView | Media Foundation MediaEngine in HWND, or texture-bridge via Flutter PlatformView |
| Play/Pause/Seek/Scrub | `lib/core/preview/player_controller.dart`, `MainFlutterWindow.swift` | AVPlayer | Direct port (MF) |
| Timeline events (position/duration/state) | `macos/Runner/Preview/PlayerEventHandler.swift` | FlutterEventChannel | Direct port |
| Real-time audio mix preview | `lib/app/home/post_processing/`, `macos/Runner/Capture/Export/` | AVAudioMixingDestination | Audio Graph API |

### Export & Post-Processing

| Feature | Location | macOS API | Windows note |
|---|---|---|---|
| Layout presets (Auto/4:3/1:1/16:9/9:16/Custom) | `lib/core/models/app_models.dart`, `lib/app/home/post_processing/widgets/post_layout_section.dart` | Composition builder | Direct port |
| Resolution presets (Auto/1080p/1440p/4K/8K/Custom) | `macos/Runner/Capture/Export/CompositionBuilder.swift` | AVAssetExportSession | Direct port |
| Format: MOV / MP4 / GIF | `lib/core/export/models/export_settings_types.dart`, `macos/Runner/Capture/Export/` | AVAssetWriter | Media Foundation or FFmpeg |
| Codec: HEVC / H.264 | `lib/core/export/models/export_settings_types.dart`, `macos/Runner/Capture/Export/` | AVVideoCodecType | MF codec selection |
| Bitrate control (Auto/Low/Med/High) | `lib/core/export/models/export_settings_types.dart` | AVAssetWriter | Direct port |
| Fit mode (letterbox/crop) | `macos/Runner/Capture/Export/CompositionBuilder.swift` | AVVideoComposition | Direct port |
| Padding/margins | `macos/Runner/Capture/Export/CompositionBuilder.swift` | Composition geometry | Direct port |
| Corner radius | `macos/Runner/Capture/Export/CompositionBuilder.swift` | CIFilter or custom | HLSL shader |
| Background color | `lib/app/home/post_processing/widgets/post_background_section.dart` | AVVideoComposition bg | Direct port |
| Background image | `macos/Runner/Capture/Export/LetterboxExporter.swift` | AVAssetReader | Direct port |
| Audio gain (dB) + Volume (%) | `lib/core/post_processing/settings/post_processing_settings_controller.dart` | AVAudioMix | Direct port |
| Audio normalization (LUFS) | `lib/app/home/post_processing/widgets/post_audio_section.dart` | AVAudioMix analysis | MF audio analysis + gain |
| Export progress callback | `lib/core/bridges/native_bridge.dart`, `MainFlutterWindow.swift` | `updateExportProgress` | Direct port |
| Cancel export | `lib/app/home/post_processing/` | AVAssetExportSession cancel | Direct port |
| Custom output path | `lib/app/home/export/`, `MainFlutterWindow.swift` | NSSavePanel | Common Item Dialog |

### Camera Overlay

| Feature | Location | macOS API | Windows note |
|---|---|---|---|
| Camera device selection | `lib/core/devices/device_controller.dart`, `macos/Runner/Capture/CameraCaptureCoordinator.swift` | AVCaptureDevice | MediaCapture / DirectShow enum |
| Live camera overlay in recording | `macos/Runner/Overlays/Camera/CameraOverlay.swift` | AVCaptureSession + NSView | DX11/12 overlay + HWND |
| Separate camera source workflow | `macos/Runner/Capture/CameraRecorder.swift` | AVAssetWriter separate file | MF sink writer |
| Layout presets (Hidden/4 corners/Side-by-side/Stacked/Background) | `macos/Runner/Capture/Export/CameraLayoutResolver.swift` | Composition layout | Direct port |
| Manual normalized position (drag) | `macos/Runner/Overlays/Camera/CameraOverlay.swift` | Mouse + NSView frame | Direct port |
| Size factor (~5% – ~80%) | `macos/Runner/Capture/Export/CameraLayoutResolver.swift` | Composition sizing | Direct port |
| Shape (Circle/RoundedRect/Square/Squircle) | `macos/Runner/Capture/Export/CameraLayoutResolver.swift` | CALayer masks | Direct port (shaders) |
| Border (width + color) | `macos/Runner/Core/Models.swift` | CATiledLayer | Direct port |
| Shadow (3 levels) | `macos/Runner/Capture/Export/CompositionBuilder.swift` | NSShadow/CALayer | Direct port |
| Chroma key (green/blue removal) | `macos/Runner/Capture/Export/CameraChromaKeyRenderer.swift` | CIFilter + Metal shader | HLSL shader |
| Intro animation (None/Fade/Pop/Slide) | `macos/Runner/Capture/Export/CameraAnimationTimelineBuilder.swift` | AVVideoComposition keyframes | Direct port |
| Outro animation (None/Fade/Shrink/Slide) | `macos/Runner/Capture/Export/CameraAnimationTimelineBuilder.swift` | AVVideoComposition keyframes | Direct port |
| Zoom emphasis (None/Pulse) | `macos/Runner/Capture/Export/CameraAnimationTimelineBuilder.swift` | Composition animation | Direct port |
| Mirror (horizontal flip) | `macos/Runner/Capture/` | AVVideoComposition transform | Direct port |
| Content mode (Fit/Fill) | `macos/Runner/Capture/Export/CameraLayoutResolver.swift` | Composition sizing | Direct port |
| Opacity (0-1) | `macos/Runner/Capture/Export/CompositionBuilder.swift` | Composition opacity | Direct port |
| Zoom behavior (Fixed/Scale-with-zoom) | `macos/Runner/Capture/Export/CameraTransformTimelineBuilder.swift` | Conditional scale | Direct port |
| Real-time placement preview | `macos/Runner/Preview/` | Event channel | Direct port |

### Cursor

| Feature | Location | macOS API | Windows note |
|---|---|---|---|
| Cursor sample recording | `macos/Runner/Capture/Cursor/CursorRecorder.swift` | CGEventTap + accessibility | SetWinEventHook + GetCursorPos |
| Cursor rendering in export | `macos/Runner/Capture/Export/` | Custom drawing | Direct port |
| Cursor size (0.5x – 3.0x) | `lib/app/home/post_processing/widgets/post_cursor_section.dart` | Composition scale | Direct port |
| Cursor highlight overlay (live) | `macos/Runner/Overlays/CursorHighlighter/CursorHighlighter.swift` | NSBezierPath + AppKit | Direct port (Win32 overlay) |
| Highlight strength control | `macos/Runner/Overlays/CursorHighlighter/CursorHighlighter.swift` | Line width + shadow | Direct port |
| Linked-to-recording toggle | `lib/core/bridges/native_bridge.dart` | State | Direct port |
| Cursor samples query (for zoom) | `lib/core/preview/`, `macos/Runner/Capture/Export/` | Sample stream | Direct port |

### Zoom

| Feature | Location | macOS API | Windows note |
|---|---|---|---|
| Follow-cursor zoom (legacy) | `macos/Runner/Capture/Zoom/ZoomFollowSmoother.swift` | Sample analysis | Direct port (pure Dart math) |
| Fixed-target zoom (Phase 1) | `lib/app/home/post_processing/widgets/post_zoom_section.dart`, `macos/Runner/Capture/Zoom/` | Segment store | Direct port |
| Zoom timeline editor UI | `lib/app/home/post_processing/widgets/post_zoom_section.dart`, `zoom_track.dart` | Flutter painting | Direct port |
| Smart zoom heuristic | `lib/core/zoom/zoom_focus_heuristic.dart` | Algorithm | Direct port |
| Hysteresis smoothing | `macos/Runner/Capture/Zoom/ZoomHysteresis.swift` | Filter | Direct port |
| Manual zoom segment store | `macos/Runner/Capture/Zoom/ZoomManualStore.swift` | JSON file | Direct port |
| Zoom factor (1.5x – 4.0x) | `lib/app/home/post_processing/widgets/post_zoom_section.dart` | Composition scale | Direct port |
| Zoom capabilities probe | `MainFlutterWindow.swift` (`previewGetZoomCapabilities`) | Version gate | Direct port |
| Zoom preview rendering | `macos/Runner/Preview/InlinePreviewView.swift` | AVVideoComposition | Direct port |

### Permissions

| Feature | Location | macOS API | Windows note |
|---|---|---|---|
| Screen recording permission | `lib/core/permissions/`, `macos/Runner/Permissions/` | TCC | CapabilityAccessManager (Win11) |
| Microphone permission | `macos/Runner/Permissions/ScreenRecorderFacade+Permissions.swift` | TCC mic | Win capability |
| Camera permission | `macos/Runner/Permissions/` | TCC camera | Win capability |
| Accessibility permission | `MainFlutterWindow.swift` (`isAccessibilityTrusted`) | AXIsProcessTrusted | Admin/UAC check |
| Permission onboarding UI | `lib/app/permissions/screens/`, `widgets/` | Flutter UI | Direct port |
| Permission status snapshot | `lib/core/permissions/models/permission_status_snapshot.dart` | Batch TCC | Direct port |
| Pre-flight rules | `lib/core/permissions/recording_start_preflight_rules.dart` | Composite | Direct port |
| Open settings shortcuts | `MainFlutterWindow.swift` (`openSystemSettings`, `openScreenRecordingSettings`, `openAccessibilitySettings`) | NSWorkspace URLs | `ms-settings:` URI via Launcher |

### Licensing

| Feature | Location | Notes |
|---|---|---|
| Client-side license validation | `lib/commercial/licensing/license_service.dart`, `license_controller.dart` | Direct port |
| Paywall dialog | `lib/commercial/licensing/widgets/paywall_dialog.dart` | Direct port |
| License plan model | `lib/commercial/licensing/models/license_plan.dart` | Direct port |
| License settings UI | `lib/commercial/licensing/settings/license_settings_section.dart` | Direct port |

### Settings & Preferences

| Feature | Location | macOS API | Windows note |
|---|---|---|---|
| Save folder picker + persistence | `macos/Runner/Services/SaveFolderStore.swift`, `MainFlutterWindow.swift` (`chooseSaveFolder`) | NSOpenPanel + bookmarks | Common Item Dialog + path storage |
| Filename template | `lib/core/recording/settings/recording_settings_controller.dart` | Template expand | Direct port |
| Keyboard shortcuts | `lib/app/home/keyboard_shortcuts_controller.dart`, `lib/app/settings/shortcuts/` | Flutter keys | Direct port |
| Theme light/dark | `lib/ui/theme/app_shell_tokens.dart` | Flutter | Direct port |
| Localization (EN/AR/RO+) | `lib/l10n/` | Flutter l10n | Direct port |
| Storage usage dashboard | `macos/Runner/Services/StorageInfoProvider.swift` | FileManager | Win FileSystem API |
| Clear cached recordings | `MainFlutterWindow.swift` (`clearCachedRecordings`) | File delete | Direct port |
| Reveal temp folder | `MainFlutterWindow.swift` (`revealTempFolder`) | NSWorkspace | ShellExecute |
| Auto-save UI prefs | `lib/app/home/home_prefs_store.dart` | SharedPreferences | Direct port |

### Updates

| Feature | Location | macOS API | Windows note |
|---|---|---|---|
| Sparkle updater | `macos/Runner/Platform/Updates/UpdaterController.swift` | Sparkle | WinSparkle or Squirrel.Windows |
| Manual update check | `lib/core/bridges/native_bridge.dart`, `UpdaterController.swift` | Sparkle | Direct port |
| Update available event | `updaterEvents` channel | Sparkle | Direct port |

### UI

| Feature | Location | Notes |
|---|---|---|
| Recording sidebar | `lib/app/home/widgets/home_left_sidebar.dart`, `recording_options_sidebar.dart` | Direct port |
| Post-processing sidebar | `lib/app/home/widgets/`, `post_processing_sidebar.dart` | Direct port |
| Timeline scrubber | `lib/app/home/preview/widgets/timeline/` | Direct port |
| Floating export progress dock | `lib/app/home/widgets/export_progress_dock.dart` | Direct port |
| Hero panel | `lib/app/home/widgets/hero_panel.dart` | Direct port |
| Desktop toolbar | `lib/app/home/widgets/desktop_toolbar.dart` | Direct port |
| Countdown overlay | `lib/app/home/widgets/countdown_overlay.dart` | Direct port |
| Grid painter | `lib/app/home/widgets/grid_painter.dart` | Direct port |
| Loading states | `lib/app/home/widgets/home_loading_view.dart` | Direct port |
| Onboarding guide | `lib/app/home/guide/home_guide_*.dart` | Direct port |
| Settings sections | `lib/app/settings/sections/` | Direct port |
| Confetti completion | pubspec `confetti` | Direct port |
| Storage charts | pubspec `syncfusion_flutter_charts` | Direct port |

### Logging / Observability

| Feature | Location | Notes |
|---|---|---|
| Structured logging | `lib/app/infrastructure/logging/logger_service.dart`, `macos/Runner/Utilities/NativeLogger.swift` | Direct port |
| Native log bridge | Method channel `log` callback | Direct port |
| Log file export | `MainFlutterWindow.swift` (`revealTodayLogFile`, `revealLogsFolder`) | ShellExecute |
| Sentry | `lib/app/infrastructure/observability/telemetry_service.dart` | Direct port |
| Error mapping | `lib/app/home/home_error_mapper.dart`, `lib/core/bridges/native_error_codes.dart` | Direct port |

### File / Project Ops

| Feature | Location | macOS API | Windows note |
|---|---|---|---|
| Project manifest | `macos/Runner/Services/RecordingProjectManifest.swift`, `RecordingProjectPaths.swift` | JSON + dirs | Direct port |
| File picker | `MainFlutterWindow.swift` (`pickImage`, `chooseSaveFolder`) | NSOpenPanel/NSSavePanel | Common Item Dialog |
| File reveal | `MainFlutterWindow.swift` (`revealFile`, `revealRecordingsFolder`) | NSWorkspace | ShellExecute /select |
| App paths | `macos/Runner/Services/AppPaths.swift` | NSSearchPath | KnownFolderManager / ApplicationData |

---

## 2. BRIDGE CONTRACT

Channel: `com.clingfy/screen_recorder` (method).
Event channels: `screen_recorder/events`, `player/events`, `workflow/events`, `updater/events`.

### Flutter → Native methods

```
Recording:
  startRecording, stopRecording, pauseRecording, resumeRecording,
  togglePauseRecording, getRecordingCapabilities

Display/Window:
  getDisplays, setDisplay, getAppWindows, setAppWindowTarget,
  setDisplayTargetMode (0=explicit, 1=appWindow, 2=singleAppWindow,
    3=area, 4=mouseAtStart, 5=followMouse)

Area:
  pickAreaRecordingRegion, revealAreaRecordingRegion, clearAreaRecordingSelection

Devices / Audio:
  getAudioSources, setAudioSource, getVideoSources, setVideoSource,
  updateAudioPreview, setAudioMix, setAudioGainDb

Recording settings:
  setRecordingQuality, setFileNameTemplate,
  setExcludeRecorderApp, getExcludeRecorderApp,
  setExcludeMicFromSystemAudio, getExcludeMicFromSystemAudio,
  setCaptureFrameRate

Cursor & overlay:
  setCursorHighlightEnabled, setCursorHighlightLinkedToRecording,
  setOverlayEnabled, setOverlayLinkedToRecording,
  showCameraOverlay, hideCameraOverlay,
  setCameraOverlaySize, setCameraOverlayFrame,
  setCameraOverlayPosition, setCameraOverlayCustomPosition,
  setCameraOverlayShape, setCameraOverlayRoundness,
  setCameraOverlayOpacity, setCameraOverlayShadow,
  setCameraOverlayBorder, setCameraOverlayBorderWidth,
  setCameraOverlayBorderColor, setCameraOverlayHighlight,
  setCameraOverlayHighlightStrength,
  setOverlayMirror,
  setChromaKeyEnabled, setChromaKeyColor, setChromaKeyStrength

Indicator + pre-recording bar:
  setRecordingIndicatorPinned,
  setPreRecordingBarEnabled/Visible, showPreRecordingBar,
  togglePreRecordingBar, setPreRecordingBarState

Preview / Player:
  previewOpen, previewClose, previewPlay, previewPause,
  previewSeekTo, previewPeekTo,
  playerPlay, playerPause, playerSeekTo, inlinePreviewStop,
  previewSetCameraPlacement, previewSetZoomSegments,
  previewSetAudioMix, previewGetZoomCapabilities,
  previewGetCursorSamples, previewGetSourceDimensions

Export:
  exportVideo, processVideo, cancelExport,
  getRecordingSceneInfo, getZoomSegments,
  getManualZoomSegments, saveManualZoomSegments

Permissions:
  getPermissionStatus,
  requestScreenRecordingPermission, requestMicrophonePermission,
  requestCameraPermission,
  openAccessibilitySettings, openScreenRecordingSettings,
  openSystemSettings, isAccessibilityTrusted, relaunchApp

Storage / Files:
  getSaveFolder, chooseSaveFolder, resetSaveFolder,
  openSaveFolder, revealRecordingsFolder, revealTempFolder,
  revealLogsFolder, revealFile, revealTodayLogFile,
  getTodayLogFilePath, clearCachedRecordings,
  getStorageSnapshot, getCaptureDiagnostics

Misc:
  pickImage, cacheLocalizedStrings, checkForUpdates
```

### Native → Flutter callbacks

```
log, indicatorPauseTapped, indicatorStopTapped, indicatorResumeTapped,
menuBarToggleRequest, updateExportProgress,
preRecordingBarAction (closeTapped/displayTapped/windowTapped/areaTapped/
  cameraTapped/micTapped/systemAudioTapped/updateTapped/
  recordTapped/pauseTapped/resumeTapped),
nativeSelectionChanged (display/window/mic/camera/mode),
cameraOverlayMoved, areaSelectionCleared,
getLocalizedStrings
```

### Event channels

```
screen_recorder/events:
  audioSourcesChanged, videoSourcesChanged,
  microphoneLevel{linear, dbfs}

workflow/events:
  openProjectRequest{projectPath}

player/events:
  player state / position updates

updater/events:
  updateAvailable{version, build}
```

**Sync rule:** any change here = update both `lib/core/bridges/native_method_channel.dart` AND `macos/Runner/Core/NativeChannel.swift` AND new `windows/runner/` equivalent.

---

## 3. macOS APIs needing Windows replacements

| macOS | Purpose | Windows |
|---|---|---|
| ScreenCaptureKit (macOS 15+) | Display/window/audio capture | Windows.Graphics.Capture (preferred) or DXGI Desktop Duplication |
| AVFoundation | Legacy capture + composition + export | Media Foundation |
| CoreGraphics (Quartz) | Display enum, event tap | EnumDisplayMonitors, SetWinEventHook |
| AppKit | UI windows, dialogs, menus | Win32 / WinUI |
| CoreImage | Filters, chroma key | HLSL shaders via D3D11/12, or WIC |
| AudioToolbox / AVAudioEngine | Audio mix, gain, metering | WASAPI + XAudio2 |
| AVVideoComposition | Video composition pipeline | Media Foundation media engine or custom DX pipeline |
| Sparkle | Updater | WinSparkle or Squirrel.Windows |
| AXIsProcessTrusted | Accessibility trust | Admin/UAC check |
| TCC | Privacy DB | CapabilityAccessManager (Win11) |
| NSWorkspace | File reveal/open | ShellExecute |
| Metal | GPU rendering | Direct3D 11/12 |
| CALayer / QuartzCore | HW-accelerated draw | D3D composition |
| CGEventTap | Cursor tracking | SetWinEventHook(WH_MOUSE_LL) + GetCursorPos |
| NSFileManager | File ops | Win FileSystem API |

---

## 4. pubspec.yaml plugins — Windows support

| Plugin | Windows | Note |
|---|---|---|
| cupertino_icons | N/A | iOS-only icons |
| flutter_colorpicker | ✅ | Pure Dart |
| flutter_localizations / intl | ✅ | Built-in |
| package_info_plus | ✅ | Native |
| path_provider | ✅ | ApplicationData |
| provider | ✅ | Pure Dart |
| shared_preferences | ✅ | Registry-backed on Win |
| url_launcher | ✅ | ShellExecute |
| uuid | ✅ | Pure Dart |
| **fluent_ui** | ✅ | **Primary Windows design system** |
| **macos_ui** | ⚠️ macOS only | Conditional import needed |
| http | ✅ | dart:io |
| device_info_plus | ✅ | Native |
| flutter_secure_storage | ✅ | DPAPI on Win |
| sentry_flutter | ✅ | Native |
| confetti | ✅ | Pure Flutter |
| syncfusion_flutter_charts | ✅ | Cross-platform |
| window_manager | ✅ | Native |
| flutter_launcher_icons / flutter_lints / sentry_dart_plugin | ✅ | Dev only |

---

## 5. ARCHITECTURE FOR WINDOWS PORT

Three layers:

1. **Flutter UI + domain (`lib/`)** — 100% portable. Conditional `fluent_ui` vs `macos_ui` based on `Platform.isWindows`. Zero rewrite.
2. **Bridge contract (`lib/core/bridges/`)** — platform-agnostic. Dart side unchanged. New Windows native side must satisfy same 100+ method/event surface.
3. **Native engine (`macos/Runner/` → `windows/runner/`)** — complete rewrite in C++/WinRT or C#. Capture pipeline, export, preview, overlays, updater, permissions all macOS-specific.

### Recommended phases

| Phase | Scope | Estimate |
|---|---|---|
| **1. UI shell** | Platform detection: `fluent_ui` on Win, `macos_ui` on Mac. All Flutter widgets reused. | 1–2 weeks |
| **2. MVP capture** | DXGI / Windows.Graphics.Capture screen recording + WASAPI mic + MF H.264 export | 4–6 weeks |
| **3. Advanced features** | Camera overlay (DX11/12), composition pipeline, chroma key HLSL shader, zoom rendering, cursor sample capture (SetWinEventHook) | 4–8 weeks |
| **4. Polish** | Permissions UX, WinSparkle update, storage dashboard, perf tuning | 2–4 weeks |

**Total: 3–4 months full port, 1–2 months MVP (capture + basic export only).**

---

## 6. KEY TAKEAWAYS

**Easy (direct Dart port — no native work):**
All UI widgets, state mgmt, post-processing math (zoom segments, camera placement, audio gain), localization, licensing, settings, keyboard shortcuts, project bundle format.

**Medium (Flutter plugins already cross-platform):**
File ops, storage, secure storage, device info, Sentry, charts, window mgmt.

**Hard (native rewrite required):**
Capture pipeline (screen/window/area), audio capture+mix (WASAPI), export engine (MF or FFmpeg), preview player (MF MediaEngine or custom), camera overlay rendering + composition, chroma key shader (HLSL), cursor tracking (SetWinEventHook), permissions model, updater (WinSparkle).

**Most complex single feature:** camera overlay export — baked composition + chroma key + intro/outro/zoom animations. Needs D3D11/12 pipeline or careful MF graph.

**Bridge contract is fully defined and complete.** No new method/event design work required — just implement same interface in `windows/runner/`.

---

## 7. ScreenRecorderFacade decomposition — Engine vs Platform seam map

`macos/Runner/Capture/ScreenRecorderFacade.swift` (4,311 lines) is being decomposed in place via a
behavior-preserving strangler refactor (plan: `~/.claude/plans/i-have-a-very-eventual-tome.md`). The
folder layout is feature-based (`Capture/Audio`, `Capture/Overlay`, …), so the
engine-domain-vs-macOS-platform classification — which determines what a future `windows/runner/` must
rewrite vs port — is recorded here, not in folder names.

**Classification key**
- **engine-domain** — platform-agnostic logic/policy/value types. Windows port can reuse the *design*
  (pure Swift today; on Windows, equivalent pure C++/C# logic). No macOS API dependency, or only
  cross-platform CoreMedia value types noted inline.
- **macOS-platform** — bound to AppKit / ScreenCaptureKit / AVFoundation / TCC. Windows must fully
  rewrite (see §3 mapping table).

| Unit (post-refactor) | Origin in facade | Classification | macOS APIs to replace on Windows |
|---|---|---|---|
| `RecordedDurationTracker` | helper 56–101 | engine-domain | none (pure value type) |
| `OverlayUpdateDeduper` | helper 30–48 | engine-domain | none (pure value type) |
| `OverlayRefreshPlan` / `OverlayRefreshAction` | helper 480–512 | engine-domain | none (pure decision) |
| `RecordingPauseResumeCapabilities` | helper 103–143 | engine-domain | macOS-15 branch only — note: Windows uses MF sink-writer pause capability probe |
| `CaptureDestinationPreflightPolicy` / `Decision` / `BuildEnvironment` | helper 243–310 | engine-domain | none (pure policy; disk-free query is FS-portable) |
| `CaptureDestinationDiagnostics` | helper 474–478 | engine-domain | none |
| `CachedRecordingsCleanupPolicy` | helper 50–54 | engine-domain | none |
| `ExportFormatInfo` | helper 469–472 | engine-domain | `AVFileType` field → MF container type on Windows |
| `AudioLevelEstimator` | helper 145–241 | engine-domain | pure DSP; input is `CMSampleBuffer` (CoreMedia) → WASAPI buffer on Windows |
| `MicrophoneLevelMonitor` / `MicrophoneLevelMonitoring` | helper 312–467 | **macOS-platform** | AVCaptureSession + audio output delegate → WASAPI metering |
| `CaptureControlling` / `OverlayManaging` / `CursorHighlighting` / `RecordingIndicatorManaging` protocols | helper 18–28, 514–532 | engine-domain | abstract contracts; conformers are platform |
| `StartRecordingRequest` / `ExportVideoRequest` / `PreviewSceneRequest` (new) | arg parsing | engine-domain | none (typed bridge DTOs; Windows parses same `[String:Any]` surface) |
| `ScreenRecorderMethodDispatcher` + routers (new) | MainFlutterWindow switch | engine-domain | dispatch shape portable; routed bodies call platform code |
| `RecordingStateMachine` (new, validator) | `state`/`pendingStop`/etc. logic | **engine-domain (core)** | none — direct port; the reusable recorder/editor-engine core |
| `RecordingSessionCoordinator` (deferred) | `startRecording` | engine-domain orchestration | calls platform leaves (capture/camera/permissions) |
| `MetadataSidecarWriter` / project services (deferred) | metadata + manifest logic | engine-domain | FileManager + JSON → Win FileSystem (project bundle is already port-direct, §1) |
| `PreviewSceneResolver` (deferred) | preview scene resolution | engine-domain | none (composition params are pure; future video-editing-engine core) |
| `OverlayVisibilityController` (deferred) | overlay/cursor/indicator window mgmt | **macOS-platform** | NSWindow/AppKit → HWND topmost overlay |
| `CameraCoordinationController` (deferred) | separate-camera session | **macOS-platform** | AVCaptureDevice/AVAssetWriter → MediaCapture/MF sink |
| `CaptureBackendBinder` + `RecordingFinalizer` (deferred) | `setCaptureBackend` | **macOS-platform** glue driving engine state | binds `CaptureBackend` (SCK/AVF) → DXGI/WGC + MF |
| `DeviceObservationController` (deferred) | `observeDevices` | **macOS-platform** | AVFoundation device notifications → Win device-change events |
| `NSColor+ARGB` | helper 7–16 | **macOS-platform** | AppKit color → Win color struct |

The `RecordingStateMachine` is the highest-value engine-core extraction: it is the recorder lifecycle
(Idle → Starting → Recording → Paused → Stopping → Finalizing …) that §1 already lists as a "Direct
port", and the seam a future video-editing engine builds on.
