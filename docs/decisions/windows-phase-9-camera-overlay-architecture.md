# Windows Phase 9 — camera overlay: architecture & inventory

Status: **Phase 9.0 design — locked. No production camera code yet.**
Audience: whoever implements slices 9.1–9.7.
Companion: [../windows-port.md](../windows-port.md) (roadmap); builds on the
Phase 7 (capture targeting) and Phase 8 (cursor/zoom export composition) work.

Camera overlay is the biggest remaining parity feature: it touches capture, a
second media timeline + sync, a live preview overlay, project persistence, export
composition, styling, chroma key, and permissions. This doc maps the macOS
reference, the current Windows state, locks the architecture, and splits the work
into PR-sized slices. It changes no code.

---

## 1. macOS reference behavior (the parity contract)

| Concern | macOS behavior | Anchor |
|---|---|---|
| Capture | `AVCaptureSession` + `AVCaptureMovieFileOutput`, preset `.high`; device by `uniqueID`. | `Capture/CameraRecorder.swift:66` |
| File layout | Recorded to **segment files** (`segment_000.mov`…), one per pause/resume run, **merged** at stop into a single raw `.mov` via `AVMutableComposition`. | `CameraRecorder.swift:125,277,374` |
| Sync | Each screen + camera segment carries ISO-8601 **wall-clock** start/end; export computes overlap intervals (`CameraSyncTimeline`) to map screen-time → camera-time. | `Capture/Export/CameraLayoutResolver.swift:5,50,97` |
| Live preview | Borderless non-activating `NSPanel`, `AVCaptureVideoPreviewLayer` (`.resizeAspectFill`), drag to move (normalized center persisted), resize handles. | `Overlays/Camera/CameraOverlay.swift:813,41,274` |
| Manifest | `RecordingMetadata.camera: CameraCaptureInfo{mode,enabled,rawRelativePath,metadataRelativePath,deviceId,mirroredRaw,nominalFrameRate,dimensions,segments}` + a camera-side `CameraRecordingMetadata` sidecar. | `Core/RecordingMetadata.swift:110,290`, `CameraRecorder.swift:5` |
| Editor seed | `EditorSeed` persists all composition fields (visible, layoutPreset, normalizedCenter, sizeFactor, shape, cornerRadius, border w/color, shadow, opacity, mirror, contentMode, zoomBehavior, zoomScaleMultiplier, intro/outro/zoom-emphasis presets + durations + strength, chromaKey enabled/strength/color). | `Core/RecordingMetadata.swift:123` |
| Export composition | Two-source composition; camera inserted time-synced; 10 **layout presets** (4 overlay corners, 2 side-by-side, 2 stacked, background-behind, hidden) with a **z-order** (above/behind screen); manual normalized center overrides preset; `sizeFactor` clamped [0.08,0.45], min 96px. | `Capture/Export/CompositionBuilder.swift:1848`, `CameraLayoutResolver.swift:418,510,727` |
| Shape / style | circle / square / roundedRect / squircle / (hexagon/star); border (width+color), shadow (0–3 presets), opacity [0.3,1.0], mirror; non-square/border/shadow force an inline pre-composite pass. | `CameraOverlay.swift:1100,1042,1061`, `CompositionBuilder.swift:2414` |
| Chroma key | CIColorKernel green-key: `greenAdvantage` smoothstep × color-distance, strength-scaled. | `Capture/Export/CameraChromaKeyRenderer.swift:1` |
| Animations | intro (fade/slide/scale) over `introDurationMs`, outro (fade/shrink/slide) over `outroDurationMs`, zoom-emphasis when screen zoom is active. | `Capture/Export/CameraAnimationTimelineBuilder.swift:20` |
| Permission | `AVCaptureDevice.authorizationStatus(.video)` + `requestAccess(.video)` (TCC); deep-link to Settings. | `Permissions/ScreenRecorderFacade+Permissions.swift:18,42,96` |

---

## 2. Windows current state (what exists, what's a stub)

**Already real — reuse directly:**
- **Video enumeration.** `getVideoSources` is a real Phase-2 enumerator
  (`MFEnumDeviceSources`) returning `{id (symbolic link), name}`
  (`Bridge/Devices/video_source_enumerator.cpp:120`, `device_record.h:47`).
- **Camera permission.** `ProbePermissionStatus().camera` uses WinRT
  `AppCapabilityAccess`("webcam"); `requestCameraPermission` +
  `getPermissionStatus.camera` + `ms-settings:privacy-webcam` deep-link all work
  (`Permissions/permission_probe.cpp:45`, `Bridge/Routers/permissions_router.cpp:86`).
  Windows privacy is a **global** "let desktop apps access your camera" toggle
  (no per-app TCC prompt) — the probe already reads it.
- **MF stack.** `MfSinkWriterEncoder` (H.264 MP4, HW via `MfDxgiManager`) and the
  export `IMFSourceReader` decode path exist; `mf/mfplat/mfuuid/mfreadwrite` are
  linked. **No camera *capture* exists** (no `IMFCaptureEngine` / device
  `IMFSourceReader`).

**Plumbed / placeholder — fill in:**
- **Manifest `camera` block** is emitted unconditionally with **hardcoded
  placeholders** (`camera/raw.mov`, `camera/meta.json`, `camera/segments`) and
  never populated (`recording_project_writer.cpp:156`). The **reader** already
  parses it and enforces "raw + meta present-together-or-not"
  (`recording_project_reader.cpp:550`).
- **PreviewEngine** has a `camera_path` `OpenArgs` field, "plumbed-but-not-
  composited" (`preview/preview_engine.h:70`).
- **Export** `RenderRequest` has **no camera fields**; the D2D composite loop
  (now drawing screen + cursor + zoom) is the obvious hook
  (`Capture/Export/export_pipeline.cpp`).

**Stubs (no-op success):**
- `setVideoSource` (`devices_router.cpp:242`).
- **23 `setCameraOverlay*` / chroma methods** in `camera_overlay_router.cpp:19`
  (all `HandleNoopSetter` — the Dart UI fires a stream of these at startup from
  persisted prefs; accepting them silently avoids an error wall).
- `previewSetCameraPlacement` (`preview_router.cpp`).

**Takeaway:** enumeration + permission are done; the manifest/preview/export hooks
exist; the genuinely new build is **camera capture** + **export composition** +
the **live preview overlay**. The Dart contract is fully wired and uses
`CameraExportCapabilities` to let Windows declare a feature subset (see D4).

---

## 3. The Dart↔native contract (what Windows must satisfy)

Already built; Windows must EMIT/ACCEPT exactly this (no Windows-only branching):
- **`CameraCompositionState.toMap()`** — 24 `camera*` keys (visible, layoutPreset,
  normalizedCanvasCenter `{x,y}`, sizeFactor 0.08–0.45, shape
  circle|roundedRect|square|squircle, cornerRadius 0–0.5, opacity 0–1, mirror,
  contentMode fit|fill, zoomBehavior fixed|scaleWithScreenZoom, zoomScaleMultiplier,
  intro/outro/zoomEmphasis presets + durations 80–600ms + strength, borderWidth,
  borderColorArgb, shadowPreset int, chromaKeyEnabled, chromaKeyStrength,
  chromaKeyColorArgb) — `lib/core/models/app_models.dart:208`.
- **Device:** `getVideoSources` → `[{id,name}]`; `setVideoSource {id}`
  (`device_controller.dart:213`). **No device id in `startRecording`** — the
  selected camera is used implicitly; `startRecording` carries only
  `disableCameraOverlay: bool` (`recording_controller.dart:330`).
- **Open:** `getRecordingSceneInfo` → `{projectPath, screenPath, cameraPath?,
  camera: <state map>?, cameraExportCapabilities: {shapeMask,cornerRadius,border,
  shadow,chromaKey}}` (`app_models.dart:471,435`).
- **Export:** `exportVideo` spreads all `camera*` keys + `cameraPath`
  (`post_processing_controller.dart:990`).
- **Permission:** `getPermissionStatus.camera`, `requestCameraPermission`,
  `openSystemSettings{pane:"camera"}`.

**The key lever — `CameraExportCapabilities`.** Windows returns this map from
`getRecordingSceneInfo`; the Dart editor disables/hides controls Windows can't do
yet. So Windows can ship a **subset** per slice (e.g. shape+cornerRadius first;
border/shadow/chroma later) and the UI adapts. This is what makes incremental
camera slicing safe.

---

## 4. Locked architecture decisions

**D1 — Capture via `IMFSourceReader` on the device, on a dedicated thread.**
Open the selected camera (symbolic link from the enumerator) with
`MFCreateDeviceSource` → `MFCreateSourceReaderFromMediaSource`; a dedicated camera
thread pulls frames (`ReadSample`) and feeds a **second `MfSinkWriterEncoder`**.
This reuses the existing encoder + MF knowledge and avoids the heavier
`IMFCaptureEngine`. Negotiate a reasonable capture format (prefer NV12/MJPG →
H.264). Mirrors the WGC backend's structure (a capture producer + a frame queue +
an encoder drain).

**D2 — One `camera/raw.mov`, NOT macOS-style segments + merge.** Windows already
has a pause-aware `RecordingClock`; the camera encoder stamps frames in
recording-time (paused time excluded), so pause/resume needs no segment files or a
merge pass. Simpler than macOS and produces the same single raw file. The
manifest's `segmentsDirectory` stays an unused placeholder.

**D3 — Sync via the shared recording clock, NOT wall-clock overlap.** Screen and
camera frames both timestamp against the same recording-time origin (t=0 at
start), so at export the camera frame for a screen frame at `tMs` is just the
camera sample at `tMs` — no `CameraSyncTimeline` overlap math. Write the camera's
nominal fps + dimensions into `camera/meta.json` for the reader. (Divergence from
macOS; document it.)

**D4 — Ship styling incrementally via `CameraExportCapabilities`.** Each slice
returns an honest capabilities map from `getRecordingSceneInfo` so the Dart UI
only exposes what Windows renders: 9.4 → `{shapeMask:true (circle/rounded),
cornerRadius:true, border:false, shadow:false, chromaKey:false}`; 9.5 flips
border/shadow true; 9.6 flips chromaKey true. Unsupported `camera*` export args
are accepted but ignored until their slice.

**D5 — Export: a second source reader + a masked D2D draw in the existing loop.**
Decode `camera/raw.mov` with a second `IMFSourceReader`, advance it to the screen
frame's `tMs`, and draw the camera frame into a shape-masked rounded/circle rect
at `normalizedCanvasCenter` (or the layout preset) sized by `sizeFactor` (clamped
[0.08,0.45], min 96px), respecting z-order (background-behind draws before the
screen, else after — and the camera is NOT under the smart-zoom transform unless
`zoomBehavior == scaleWithScreenZoom`). Reuse the cursor/zoom soft-fail discipline
(no camera file / decode fail → no bubble, never a failed export). Styling
(border/shadow/opacity/mirror/chroma/animations) layers on per D4.

**D6 — Live preview bubble (9.3) is a native Win32 overlay, like the area
picker.** A topmost layered window per the picker pattern
(`area_picker_overlay`), showing live camera frames (a lightweight preview source
reader), draggable to set `normalizedCanvasCenter`, resizable for `sizeFactor`,
persisted via the existing `setCameraOverlay*` methods (made real). It is a
RECORDING-time overlay; compositing the recorded camera into the **post-record
preview player** (the `PreviewEngine.camera_path` hook) is a separate, later
concern (deferred — preview parity can trail export).

**D7 — Capture raw + unstyled; ALL styling is export-time.** Record the camera at
native resolution with no mirror/shape/chroma baked in (matching the editable
cursor/zoom model). `mirror`, shape, border, etc. are applied at export from the
`camera*` args, so they stay editable. (macOS also keeps raw + `mirroredRaw`
metadata; Windows records unmirrored and mirrors at export.)

**D8 — Device selection + recording integration.** Make `setVideoSource {id}`
real → store in `WindowsSelectionState` (9.1). At `startRecording`, if
`!disableCameraOverlay` AND a camera is selected AND permission is granted, start
the camera capture thread → `camera/raw.mov` + `camera/meta.json`; emit the
manifest `camera` block **conditionally** (only when a camera was actually
recorded — today it's emitted unconditionally, which the reader's
present-together rule tolerates only because the files are absent... so make it
conditional). `getRecordingSceneInfo` returns `cameraPath` + the persisted camera
state + the capabilities map.

**D9 — Camera device loss mid-recording = clean stop of the camera only.** If the
camera unplugs mid-record (source reader error / device loss), stop the camera
thread, finalize `camera/raw.mov` with what was captured, and continue the screen
recording (camera becomes a shorter track; export shows it for its duration). Do
NOT fail the whole recording. (Mirrors the Phase 7.4 target-loss discipline,
scoped to the camera.)

---

## 5. Deliberate divergences from macOS (call out in PRs)

1. **Single `camera/raw.mov` with pause-aware timestamps** vs macOS segment files
   + merge (D2). Same result, less machinery.
2. **Shared-clock sync** vs macOS wall-clock segment overlap (D3).
3. **Incremental styling via `CameraExportCapabilities`** (D4) — Windows ships a
   feature subset per slice; macOS ships all at once.
4. **Camera not under the smart-zoom transform** unless `scaleWithScreenZoom`
   (D5) — the bubble stays put while the screen zooms, which is the common
   expectation.
5. **No hexagon/star shapes** in MVP (circle/rounded/square/squircle only).

---

## 6. Slice plan (PR-sized) + acceptance tests

Same gated rhythm as Phases 6–8: explore → implement → adversarial review → ship →
user smoke → next. GPU/device-touching tests follow the `D3DDevice::Create()`
`GTEST_SKIP` / real-pipeline patterns; pure logic (layout/placement math,
capabilities, sync mapping) is unit-tested without a camera.

### 9.1 — Camera device selection + permission readiness  (`feature/windows-phase-9-1-camera-device`)
Make `setVideoSource {id}` real → `WindowsSelectionState`; wire the recording
preflight (camera permission gate → `disableCameraOverlay`); confirm
`getVideoSources` + `requestCameraPermission` + `getPermissionStatus.camera` round
-trip. No capture yet.
Acceptance: selected device id persists + is readable at Start; permission
gate flips `disableCameraOverlay`; enumeration/permission tests.

### 9.2 — Camera recording to a separate file  (`feature/windows-phase-9-2-camera-capture`)
`IMFSourceReader` device capture on a dedicated thread → second
`MfSinkWriterEncoder` → `camera/raw.mov` + `camera/meta.json` (fps, dims, deviceId,
mirroredRaw=false); pause-aware timestamps (D2/D3); conditional manifest `camera`
block; device-loss = clean camera stop (D9); `getRecordingSceneInfo` returns
`cameraPath`.
Acceptance: a recording with a camera yields a playable `camera/raw.mov` + meta;
no-camera recordings omit the block; pause/resume keeps it aligned; device unplug
mid-record doesn't fail the recording; manifest round-trip tests.

### 9.3 — Live camera preview bubble during recording  (`feature/windows-phase-9-3-camera-preview`)
Native Win32 layered topmost overlay (area-picker pattern) showing live camera
frames; drag → `normalizedCanvasCenter`, resize → `sizeFactor`; the
`setCameraOverlay*` setters become real (position/size/visibility). Recording-time
only.
Acceptance: overlay shows the camera, moves/resizes, persists position; torn down
at stop; pure placement-geometry unit tests.

### 9.4 — Export: simple circular/rounded camera bubble  (`feature/windows-phase-9-4-camera-export`)
Second source reader + masked D2D draw at center/size/shape (circle/rounded only),
z-order, content-mode fit/fill; `CameraExportCapabilities = {shapeMask,
cornerRadius}` only; soft-fail. MP4/MOV/GIF; progress/cancel preserved.
Acceptance: exported video shows the camera bubble at the right place/size/shape;
no-camera/missing-file soft-fails; capabilities map honest; round-trip tests.

### 9.5 — Styling: mirror / opacity / border / shadow  (`feature/windows-phase-9-5-camera-style`)
Mirror, opacity, border (width+ARGB), shadow presets; capabilities flip
border/shadow true.
Acceptance: each style visibly applies; capabilities updated; tests.

### 9.6 — Chroma key + intro/outro/zoom-emphasis animations  (`feature/windows-phase-9-6-camera-chroma`)
Green-key (D2D pixel shader / effect) with strength+color; intro/outro/zoom-
emphasis; capabilities flip chromaKey true.
Acceptance: chroma removes the keyed color; animations play; tests.

### 9.7 — Closeout / stress / smoke  (`feature/windows-phase-9-7-camera-closeout`)
Docs closeout (Phase 9 status + smoke checklist), stress (device loss, long
record, multi-monitor overlay), final smoke.

**MVP path:** 9.1 → 9.2 → 9.4 gives the useful loop (screen+camera recorded →
camera file in the project → export with a simple bubble). 9.3 preview and
9.5/9.6 styling polish after the pipeline works.

---

## 7. Cross-cutting risks

- **Camera capture-thread lifecycle + device loss** — biggest new risk; mirror
  the Phase 7.4 target-loss discipline (clean stop, finalize, no whole-recording
  failure), scoped to the camera.
- **Two source readers in export** — the camera reader must advance to the screen
  frame's `tMs` without unbounded seeking; decode sequentially + hold the last
  frame between screen frames (camera fps ≤ screen fps usually).
- **Sync drift** — relies on the shared clock; verify camera timestamps are
  pause-aware and start-aligned.
- **Format negotiation** — cameras expose varied formats (MJPG/NV12/YUY2);
  negotiate a supported one or fail the camera cleanly (recording continues).
- **Preview overlay threading** — Win32 layered window + live camera frames must
  not block the platform message loop (area-picker pattern + a preview reader
  thread).
- **Capabilities honesty** — `getRecordingSceneInfo` must report only what the
  current slice renders, or the UI offers controls that do nothing.

## 8. Deferred (later, not Phase 9 unless a slice says so)

- Post-record **preview-player** camera compositing (the `PreviewEngine.camera_path`
  hook) — preview parity can trail export.
- Hexagon/star shapes; side-by-side / stacked / background-behind layout presets
  beyond the corner-overlay MVP (add as needed).
- Camera segment files / multi-segment merge (Windows uses one file, D2).

## 9. Key references

macOS: `Capture/CameraRecorder.swift`, `Capture/Export/CameraLayoutResolver.swift`,
`Capture/Export/CompositionBuilder.swift`, `Capture/Export/CameraChromaKeyRenderer.swift`,
`Capture/Export/CameraAnimationTimelineBuilder.swift`, `Overlays/Camera/CameraOverlay.swift`,
`Core/RecordingMetadata.swift`.
Windows: `Bridge/Devices/video_source_enumerator.cpp`, `Bridge/Routers/{camera_overlay_router,devices_router,permissions_router}.cpp`,
`Permissions/permission_probe.cpp`, `Capture/recording_project_{writer,reader}.cpp`,
`Capture/Export/export_pipeline.cpp`, `preview/preview_engine.h`, `Encoding/mf_sink_writer_encoder.cpp`,
`Overlay/area_picker_overlay.cpp` (overlay pattern).
Dart: `lib/core/models/app_models.dart` (`CameraCompositionState`, `RecordingSceneInfo`,
`CameraExportCapabilities`, `CamSource`), `lib/core/devices/device_controller.dart`,
`lib/app/home/post_processing/post_processing_controller.dart` (export args).
