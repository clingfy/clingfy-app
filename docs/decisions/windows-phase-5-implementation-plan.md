# Windows Phase 5 implementation plan ("design v2")

## Status

**Proposed** — 2026-05-26.

This plan turns the architecture locked in
[windows-phase-5-preview-architecture.md](windows-phase-5-preview-architecture.md)
into a concrete production implementation order for the six Phase 5
method surfaces:

```
previewOpen
previewPlay / previewPause
previewSeekTo
player/events  (event channel, not a method)
getRecordingSceneInfo
.clingfy project reopen  (workflow/events emit + file association)
```

This document is the source of truth for **what Phase 5 production
code looks like**. The ADR is the source of truth for **why those
choices**; binding technical choices from the ADR are referenced here
but not re-litigated.

This is a docs-only plan. No code is written by this PR. The next PRs
in the sequence implement the plan one method at a time.

## Goal

After Phase 5 ships, the Windows runner supports the same
post-recording editing flow the macOS engine ships today:

1. User finishes a recording → Flutter receives `recordingFinalized`
   with the `.clingfyproj` path (already true after Phase 3E).
2. Dart calls `getRecordingSceneInfo(projectPath)` → Windows returns
   screen / camera / metadata / camera-export-capabilities map.
3. Dart calls `previewOpen({sessionId, projectPath, cameraPath?})` →
   Windows opens the MP4 in MediaPlayer frame-server mode, mounts the
   Stage 2A-2 texture bridge, returns void.
4. Dart subscribes to `com.clingfy/player/events` → receives
   `playerTick` / `playerState` / `playerError` / `playerWarning`
   messages matching the macOS contract verbatim.
5. Dart drives transport with
   `previewPlay` / `previewPause` / `previewSeekTo`.
6. User double-clicks an existing `.clingfyproj` in Explorer → the
   Windows runner emits an `openProjectRequest` workflow event with
   the bundle path, Dart picks it up via the existing
   `workflowEventStream` listener, and the same open + play flow
   runs.

No Windows-only branches in Flutter. The Dart `PlayerController` and
`HomeController` paths that exist for macOS must work on Windows
without modification, except where this plan explicitly calls out a
Dart-side change.

## Architecture recap (binding from the ADR)

These choices are settled and **not** discussed below:

- WinRT MediaPlayer with `IsVideoFrameServerEnabled = true`.
- `clingfy::preview::PreviewCompositor` (the same instance the HWND
  demo and the Stage 2A-2 bridge consume).
- `D3D11_RESOURCE_MISC_SHARED` + `IDXGIResource::GetSharedHandle`
  (legacy shared handle only; NO NT handle, NO keyed mutex).
- `kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle` for the bridge.
- Multi-thread-protected D3D11 context + `MULTI_THREADED` D2D factory.
- Explicit `ID3D11DeviceContext::Flush()` before
  `MarkExternalTextureFrameAvailable`.
- `Texture(textureId:)` widget as the sole preview UI surface;
  Windows runner never opens its own preview HWND.
- Constants from `preview/zoom_easing_constants.h` (parity-tested).

If a section below contradicts the ADR, the ADR wins and the section
is a bug.

## Implementation order

Each step is a separate PR. PRs land in this order; later PRs assume
earlier PRs have merged.

| #   | PR scope                                                        | Depends on |
| --- | --------------------------------------------------------------- | ---------- |
| 5.0 | **Lift bridge out of `poc_stage_2a/`** — rename to `PreviewEngine`, move under `windows/runner/preview/`, retire the POC dart-define screen, register the `pocStage2a*` methods as deprecated aliases (delete in a follow-up). | this ADR + impl plan |
| 5.1 | **`recording_project_reader`** — read `project.json` manifests written by Phase 3E's writer. Pure C++ + unit tests; no bridge yet. | 5.0 |
| 5.2 | **`getRecordingSceneInfo`** handler — uses 5.1, returns the macOS-shaped map. Bridge contract + Dart deserialization test. | 5.1 |
| 5.3 | **`previewOpen` / `previewClose`** — `PreviewEngine::Open(StartArgs)` derived from `Stage2aTextureBridge::Start`. Production texture lifecycle (not the POC's "never unregister" leak). | 5.0, 5.2 |
| 5.4 | **`player/events` channel** — new `PlayerEventPublisher` (parallel to `WorkflowEventPublisher`), wired into the preview engine's `VideoFrameAvailable` callback. Emits `playerTick` / `playerState` / `playerError` / `playerWarning` matching the macOS payloads verbatim. | 5.3 |
| 5.5 | **`previewPlay` / `previewPause` / `previewSeekTo`** — methods route to `PreviewEngine` transport. SessionId-mismatch behavior matches macOS (silent no-op, not error). | 5.3, 5.4 |
| 5.6 | **`.clingfyproj` file association** — `WM_COPYDATA` single-instance + Win32 file-association registration. `WorkflowEventPublisher::EmitOpenProjectRequest`. Queue requests until Dart subscribes (same shape as macOS `ProjectOpenCoordinator`). | 5.4 |
| 5.7 | **Multi-GPU validation + unregister fix** — re-run the Stage 2A-2 verdict on one NVIDIA + one AMD GPU; fix the `UnregisterExternalTexture` instability that the POC leaks around. **Gate for Phase 5 ship.** | 5.5, 5.6 |

Each PR keeps to the existing repo cadence: branch from `develop`,
squash-merge to `develop`, native + Flutter validation green before
merge (CI billing willing), pause-before-commit report.

## Per-surface spec

### Step 5.0 — Lift the bridge out of `poc_stage_2a/`

**Why first.** The Stage 2A-2 code already does what production
preview needs. Renaming + relocating before adding behavior makes
later PRs' diffs land as additions, not refactors-with-additions.

**File moves.**

```
windows/runner/preview/poc_stage_2a/stage2a_texture_bridge.{h,cpp}
  → windows/runner/preview/preview_engine.{h,cpp}

windows/runner/Bridge/Routers/poc_stage_2a_router.{h,cpp}
  → (deleted; methods land in preview_router.cpp — see below)
```

**Class rename.**

```
clingfy::poc::stage2a::Stage2aTextureBridge  → clingfy::preview::PreviewEngine
clingfy::poc::stage2a::StartArgs              → clingfy::preview::OpenArgs
clingfy::poc::stage2a::StartResult            → clingfy::preview::OpenResult
clingfy::poc::stage2a::StopArgs               → clingfy::preview::CloseArgs
```

**Bridge contract migration.** `pocStage2aStart` / `pocStage2aStop`
methods are kept registered for one release cycle as **deprecated
aliases** that forward to the new `previewOpen` / `previewClose`
handlers, so the dart-define POC screen continues to work for
benchmarking while production callers move over. Aliases are deleted
in a follow-up PR after Phase 5 design v2 ships.

**Dart side.** `bool.fromEnvironment('POC_STAGE_2A')` gate is removed
from `main.dart`; `lib/app/debug/poc_stage_2a_screen.dart` is also
removed. Anyone who needs the POC numbers re-runs them against the
production `previewOpen` path with the same artifact writer (see
"Native producer timings (debug)" under 5.4).

**Bridge contract coverage.** `windows/runner_tests/bridge_contract_coverage_test.cpp`
adds the six new method names (per macOS contract), drops the
`pocStage2a*` entries after the deprecation window.

### Step 5.1 — `recording_project_reader`

**Why before everything else.** Both `getRecordingSceneInfo` and
`previewOpen` parse the same `project.json` + `capture/screen.meta.json`
files. Extracting the reader first means one parser, one set of
tests, two callers.

**New files.**

```
windows/runner/Capture/recording_project_reader.{h,cpp}
windows/runner_tests/recording_project_reader_test.cpp
```

**Contract.** `RecordingProjectReader::Read(std::wstring projectPath)`
returns a `RecordingProject` POD with:

```c++
struct RecordingProject {
  std::wstring project_path;       // input (absolute)
  std::wstring screen_path;        // <project>/capture/screen.mp4
  std::wstring screen_metadata_path; // <project>/capture/screen.meta.json
  std::optional<std::wstring> cursor_path;       // capture/cursor.json
  std::optional<std::wstring> zoom_manual_path;  // capture/zoom.manual.json
  std::optional<std::wstring> camera_video_path; // camera/raw.mov (when present)
  std::optional<std::wstring> camera_metadata_path;
  // Parsed contents of capture/screen.meta.json — what
  // getRecordingSceneInfo needs to fill the `camera` block.
  std::optional<RecordingMetadata> metadata;
  int schema_version = 0;
};
```

**Schema.** Match the macOS `RecordingProjectManifest` schema version
**2** verbatim. The Windows recording engine already writes this
schema (PR #93). Reader rejects any other `schemaVersion` with
`PROJECT_SCHEMA_VERSION_MISMATCH`.

**Error model.** Reader returns
`std::expected<RecordingProject, ReadError>`. Error kinds:

| kind                            | when |
| ------------------------------- | ---- |
| `PROJECT_BUNDLE_NOT_FOUND`      | folder doesn't exist or has no `project.json` |
| `PROJECT_MANIFEST_INVALID_JSON` | `project.json` doesn't parse |
| `PROJECT_SCHEMA_VERSION_MISMATCH` | `schemaVersion` is not 2 |
| `PROJECT_REQUIRED_FILE_MISSING` | manifest references a path that isn't on disk |

Callers map these to bridge-level error codes (see 5.2 / 5.3).

**Test surface.** Unit tests run against fixtures under
`windows/runner_tests/fixtures/clingfyproj/`. Cover:

- Happy path (recording_engine output, generated in a setup fixture).
- Missing optional camera/cursor/zoom.
- Malformed `project.json`.
- Schema version drift.
- Manifest references a missing `capture/screen.mp4`.

### Step 5.2 — `getRecordingSceneInfo`

**Channel:** `com.clingfy/screen_recorder`.
**Method name:** `getRecordingSceneInfo`.
**Args:** `{ "projectPath": "<absolute>" }`.

**Handler.** New `Bridge/Routers/preview_router.cpp` (or extend the
existing `preview_router.cpp` if one is added to runner_bridge first).
Calls `RecordingProjectReader::Read(projectPath)`.

**Return shape.** Match macOS verbatim:

```json
{
  "projectPath": "<input>",
  "screenPath": "<absolute>",
  "cameraPath": "<absolute>",         // optional, only when camera exists
  "metadataPath": "<absolute>",       // optional, only when on disk
  "camera": {                         // optional, only when metadata.editorSeed exists
    "visible": <bool>,
    "layoutPreset": "<string>",
    ...
  },
  "cameraExportCapabilities": {
    "shapeMask": true,
    "cornerRadius": true,
    "border": true,
    "shadow": true,
    "chromaKey": true
  }
}
```

Windows reports `cameraExportCapabilities` with all-true because the
production `PreviewCompositor` will support them (Phase 9 builds the
camera overlay on top of this same compositor); shipping `false`
early would force a Dart-side capability branch we'd just have to
remove later.

**`camera` block.** When `metadata.editorSeed` is null (no camera
overlay was active during recording), the `camera` key is omitted —
**not** sent as null. The Dart-side `RecordingSceneInfo.fromMap`
treats the missing key and `null` differently in some places; the
macOS engine omits the key, and Windows must match.

**Error codes.** Mapped from the reader's `ReadError`:

| reader kind                       | bridge code                |
| --------------------------------- | -------------------------- |
| `PROJECT_BUNDLE_NOT_FOUND`        | `SCENE_INPUT_MISSING`      |
| `PROJECT_MANIFEST_INVALID_JSON`   | `SCENE_INPUT_MISSING`      |
| `PROJECT_SCHEMA_VERSION_MISMATCH` | `SCENE_INPUT_MISSING`      |
| `PROJECT_REQUIRED_FILE_MISSING`   | `SCENE_INPUT_MISSING`      |

(All collapse to `SCENE_INPUT_MISSING` to match macOS, which
similarly hides the variant from Dart. The native log records the
specific variant for debugging.)

**Tests.** Bridge contract coverage adds `getRecordingSceneInfo`. A
new `getRecordingSceneInfo_router_test.cpp` covers the happy path +
each error mapping using the reader's fixtures.

### Step 5.3 — `previewOpen` / `previewClose`

**Channel:** `com.clingfy/screen_recorder`.
**Methods:** `previewOpen`, `previewClose`.

**`previewOpen` args:**

```json
{
  "sessionId": "<string, required>",
  "projectPath": "<absolute, required>",
  "cameraPath": "<absolute, optional>"
}
```

`cameraPath` is the Dart-side override the macOS contract supports;
when absent, Windows falls back to the reader's resolved camera path
(if any). Camera compositing itself is Phase 9 work — Phase 5 wires
the path through but the compositor ignores it until Phase 9.

**`previewClose` args:** `{ "sessionId": "<string>" }`.

**`PreviewEngine`** (renamed Stage 2A-2 bridge) gains:

```c++
struct OpenArgs {
  std::string session_id;
  std::wstring video_path;   // resolved from RecordingProjectReader
  std::wstring cursor_path;  // optional
  std::wstring camera_path;  // optional, deferred
};

OpenResult Open(const OpenArgs& args);
void Close(const std::string& session_id);
```

**Differences from Stage 2A-2 `Start`:**

1. Takes a `session_id`. The engine tracks `active_session_id_`; calls
   targeting a different session no-op silently (see macOS gotcha #2).
2. **Real texture lifecycle.** The POC's
   `dying_impl.release()` workaround is replaced with a
   correctness-grade unregister. Strategy:
   - Pause the MediaPlayer.
   - Unsubscribe `VideoFrameAvailable` (drain in-flight callbacks
     under `render_mutex`).
   - Tell the producer to stop marking frames available.
   - **New:** Coordinate with Flutter to know the `Texture` widget is
     no longer mounted. Two options under evaluation:
     - **(a)** Add a Dart-side "preview disposed" callback that fires
       from the preview widget's `dispose()` and triggers the
       native unregister on the next frame.
     - **(b)** Defer `UnregisterExternalTexture` behind a small grace
       window (e.g. 250 ms after the last MarkFrameAvailable) and
       hope Flutter's pipeline has flushed before unregister.
   - Option (a) is preferred; the open question is whether the Dart
     dispose callback is reliable enough. If not, fall back to (b)
     and document the timeout choice.
3. **Resizable shared texture.** Stage 2A-2 hard-codes
   1280 × 720. Production sizes the shared texture to the natural
   video size capped at 1920 × 1080 (or to the Flutter widget's
   logical-pixel size × DPI scale, whichever is smaller). Recreating
   the surface on Flutter widget resize is a Phase 5.7 item; Step
   5.3 only needs to pick a sensible fixed size at open time.
4. **Cursor pipeline opt-in.** When `cursor_path` is set,
   `PreviewEngine` loads the JSONL (real production cursor data
   shape — already JSON-array-compatible per the macOS reader, but
   confirm cursor format with macOS's `loadRecordingMetadata` →
   `cursorData`). When unset, video-only.

**Return shape.** Match macOS (which returns `null` on success):

- Success → returns `null`.
- Error → FlutterError with code `PREVIEW_INPUT_MISSING` (project
  bundle not findable / required files absent).

The Stage 2A-2 result-map shape (`textureId`, `sharedHandleOk`,
`videoWidth`, etc.) is preserved as a **debug-only** map under
`POC_TIMING_VERBOSE` `--dart-define` — production Dart callers ignore
it. The texture id Flutter needs is provided through a **separate**
channel mechanism described in 5.4 (event-channel snapshot, **not**
the method return), to match macOS's pattern where the inline
preview view discovers the AVPlayer item via its own internal call.

**Pending-request queue.** macOS queues `previewOpen` when the inline
preview view hasn't mounted yet. Windows handles this differently
because Flutter's `Texture` widget is mounted from Dart and there is
no equivalent "preview view exists" gate — the texture is the only
surface. Windows therefore does **not** implement a queue; if Dart
calls `previewOpen` before its widget tree is ready, the widget's
`build` simply uses the texture id once it arrives. The macOS quirk
is structural to AVKit + AppKit and doesn't apply.

**Bridge contract coverage.** Adds `previewOpen` and `previewClose`.

### Step 5.4 — `player/events` event channel

**Channel:** `com.clingfy/player/events` — currently a Phase-0
no-op stub.

**New file.** `windows/runner/Bridge/player_event_publisher.{h,cpp}`,
modelled on `workflow_event_publisher.{h,cpp}`.

```c++
namespace clingfy::bridge {
class PlayerEventPublisher {
 public:
  static PlayerEventPublisher& Instance();
  void SetSink(std::unique_ptr<EventSink> sink);
  void ClearSink();
  bool has_sink() const;

  // Payloads MUST match the macOS shapes from
  // InlinePreviewView.swift's sendTick/sendState/sendError/sendWarning.
  void EmitPlayerTick(const std::string& session_id,
                      std::int64_t position_ms,
                      std::int64_t duration_ms);
  void EmitPlayerState(const std::string& session_id,
                       PlayerState state);   // playing / paused / completed
  void EmitPlayerError(const std::string& session_id,
                       const std::string& code,    // e.g. "VIDEO_FILE_MISSING"
                       const std::string& message);
  void EmitPlayerWarning(const std::string& session_id,
                         const std::string& code,
                         const std::string& message);
  // Camera placement edits ride this same channel on macOS but Phase 5
  // does not implement camera dragging — declared here only so the
  // shape is documented. Phase 9 wires it.
  // void EmitCameraManualPositionChanged(...);
};
}
```

**Cadence.** macOS emits `playerTick` at display-link rate
(~60 Hz). Windows emits from inside the existing
`VideoFrameAvailable` callback after `MarkExternalTextureFrameAvailable` —
naturally aligned with the produced-frame cadence. When the player
is **paused** (no `VideoFrameAvailable` callbacks), Windows runs a
low-rate (10 Hz) timer that emits the most recent `position_ms` so
Dart's `_playerReady` flag doesn't go stale during scrubbing.

**State transitions.** `PlayerState` is `playing`, `paused`, or
`completed`. The engine watches `MediaPlayer.PlaybackSession.PlaybackState`
(`Playing` / `Paused` / `None`) and the `MediaEnded` event. Emits a
single `playerState` event per transition; debounce duplicates.

**First-tick rule.** Same as macOS. The engine does not call
`MediaPlayer.Play()` until the first `VideoFrameAvailable` has been
delivered (i.e. the source is ready), then emits the first
`playerTick` from inside that handler. Dart's `_playerReady` gates
on this first tick.

**Stale-session filter.** Every event carries the current
`session_id`. Dart's `PlayerController` already filters by active
session id; Windows just has to populate the field correctly. The
preview engine **does not** emit events after `Close(session_id)`
returns — pending callbacks under `render_mutex` are drained first.

**Native producer timings (debug).** Phase 2A-2's per-frame
copy/render/handoff stats are kept under
`--dart-define=POC_TIMING_VERBOSE=true`. When enabled, the engine
writes the same `stage2a_2_result.md` artifact on `Close`, replacing
the POC-only shape with production session id + project path. Off
by default.

### Step 5.5 — `previewPlay` / `previewPause` / `previewSeekTo`

**Channel:** `com.clingfy/screen_recorder`.

**Args:**

```json
previewPlay     { "sessionId": "<string>" }
previewPause    { "sessionId": "<string>" }
previewSeekTo   { "sessionId": "<string>", "ms": <int> }
```

**Behavior.** Each handler resolves `PreviewEngine::Instance()`. If
the current `active_session_id_` does **not** match the call's
`sessionId`, the handler returns `null` immediately (matches macOS
gotcha #2 — silent no-op). On match:

- `previewPlay` → `player.Play()`.
- `previewPause` → `player.Pause()`.
- `previewSeekTo` → `player.PlaybackSession().Position(TimeSpan)`.
  Then queues a `SeekSample` so the next `VideoFrameAvailable`
  resolves it (already implemented in Stage 1D / 2A-2).

**Return shape.** `null` on success (no error reporting on mismatch
— same as macOS).

**Error codes.** Only `BAD_ARGS` (missing sessionId, missing ms,
wrong types). Match macOS exactly.

**Bridge contract coverage.** Adds the three method names.

### Step 5.6 — `.clingfyproj` file association

**Goal.** When the user double-clicks a `.clingfyproj` folder in
Windows Explorer, the runner (running or about to run) discovers the
path, hands it to Dart over `workflow/events`, and the existing
Dart-side `onProjectOpenRequested` callback runs the `previewOpen`
flow.

**Three pieces, all in `windows/runner/`:**

1. **CLI / argv pickup.** `flutter_window.cpp` already parses
   `argv` at startup; extend it to recognise a `.clingfyproj` path
   and pass it to the new `ProjectOpenCoordinator`. The path is
   queued until Dart subscribes to `workflow/events` (the
   `WorkflowEventPublisher::has_sink()` gate).

2. **Single-instance via `WM_COPYDATA`.** A new `single_instance.cpp`
   creates a named mutex; if a second instance starts, it forwards
   its argv to the first via `WM_COPYDATA` and exits. The first
   instance treats the received path the same as one from its own
   argv. This avoids spawning a second runner per double-click.

3. **File-association registration.** A new
   `installer/register_clingfyproj_association.reg.tmpl` (consumed
   by the WiX / MSIX installer that lands as part of Phase 10) maps
   the `.clingfyproj` extension to the runner exe with the project
   path as the first argument. Production registration happens at
   install time, **not** at runtime — runtime registration would
   require admin and silently fail for unprivileged installs.

   For local dev (no installer), a small `dev_register_assoc.ps1`
   script under `tools/` handles per-user `HKCU` registration so
   double-click works for developers. The script is opt-in and
   documented in `docs/development.md` (not run automatically).

**New `WorkflowEventPublisher::EmitOpenProjectRequest`:**

```c++
void EmitOpenProjectRequest(const std::string& project_path);
```

Payload exactly matches macOS:

```json
{
  "type": "openProjectRequest",
  "projectPath": "<absolute>"
}
```

**Queueing.** `ProjectOpenCoordinator` (new file, mirrors macOS
behavior) holds a queue of project paths; on `SetSink` /
`has_sink() = true` it drains the queue and emits each path via
`EmitOpenProjectRequest`. New paths are emitted immediately when the
sink is already attached.

**Dart side.** No change needed — `NativeBridge.onProjectOpenRequested`
already exists and is the only consumer. The existing macOS-side
flow proves the Dart shape works.

**Bridge contract coverage.** No new method names — this rides the
existing `workflow/events` event channel.

### Step 5.7 — Multi-GPU validation + unregister fix

**Gating PR for Phase 5 ship.** Two open risks from the ADR:

1. **Texture unregister.** The POC leaks. Step 5.3 picks an option
   ((a) Dart dispose callback, or (b) timed defer). Whichever option
   ships, this PR re-runs the Stage 2A-2 verdict under repeated
   open/close cycles (target: 200 open → close → open cycles per
   session with no GPU memory growth and no shutdown crash). Numbers
   land in `build/windows-poc/stage5_lifecycle_result.md`.

2. **GPU coverage.** Re-run the Stage 2A-2 verdict on one NVIDIA
   discrete GPU and one AMD APU. If the legacy shared-handle path
   fails on either, this PR either documents a per-GPU fallback or
   triggers a re-decision of the ADR (in a new ADR — Phase 5 design
   v2 itself doesn't get to override the architecture).

Phase 5 is not declared shipped until both items pass.

## Supporting infrastructure

### `recording_project_reader` schema fidelity

The Windows recording engine has been writing `schemaVersion: 2`
since PR #93. Phase 5's reader and macOS's writer/reader are bound
by that schema. The reader does **not** support older schemas, and
the engine should not be downgrading the schema field — both sides
fail-fast on mismatch so a future migration is loud.

If macOS or Windows ever needs to evolve the schema, the bump
process is:

1. New PR adds `schemaVersion: 3` writer behavior, hidden behind a
   feature flag.
2. Reader on both platforms gains a v2-or-v3 acceptor and a
   migrator if the format shift requires one.
3. Writer flips to v3 in a follow-up after both readers ship.

This isn't binding on Phase 5 work, but the reader's error code
naming (`PROJECT_SCHEMA_VERSION_MISMATCH`) deliberately keeps a
future migration's failure mode obvious.

### File / namespace layout after Phase 5

```
windows/runner/preview/
  preview_engine.{h,cpp}              # from poc_stage_2a/stage2a_texture_bridge
  preview_compositor.{h,cpp}          # unchanged (#103)
  frame_timing.{h,cpp}                # unchanged
  zoom_easing_constants.h             # unchanged (#96)
  player_state.h                      # new enum + payload helpers

windows/runner/Capture/
  recording_project_reader.{h,cpp}    # new (5.1)
  recording_project_writer.{h,cpp}    # unchanged
  recording_metadata.{h,cpp}          # new — parsed editorSeed + camera meta

windows/runner/Bridge/
  player_event_publisher.{h,cpp}      # new (5.4)
  workflow_event_publisher.{h,cpp}    # extended with EmitOpenProjectRequest
  project_open_coordinator.{h,cpp}    # new (5.6)
  single_instance.{h,cpp}             # new (5.6)
  Routers/preview_router.cpp          # extended: previewOpen/Close/Play/Pause/SeekTo + getRecordingSceneInfo

windows/runner_tests/
  recording_project_reader_test.cpp   # new (5.1)
  preview_router_test.cpp             # new (5.2 / 5.3 / 5.5)
  player_event_publisher_test.cpp     # new (5.4)
  project_open_coordinator_test.cpp   # new (5.6)
  bridge_contract_coverage_test.cpp   # add the six method names; drop pocStage2a*
```

### Audio path

The ADR called audio out as an open follow-up. Phase 5 ships
**audio enabled** via MediaPlayer's default audio renderer. This
means:

- The user hears the recording's audio track during preview, in
  sync with the video MediaPlayer is decoding.
- No WASAPI routing. No volume control beyond what MediaPlayer
  surfaces directly. No mute-on-pause hooks beyond MediaPlayer's
  own pause behavior.
- `previewSeekTo` interrupts audio; MediaPlayer handles this with
  a brief silence around the seek. Acceptable.

Phase 5 does not implement `previewSetAudioMix` /
`previewSetAudioGainDb` — those remain Phase 1 no-ops on Windows.
The volume / mute UI is hidden on Windows until that follow-up
ships.

### Camera path

Phase 5 wires `cameraPath` through `previewOpen` and surfaces it
in `getRecordingSceneInfo.cameraPath`, but does **not** composite
the camera. Dart's preview UI for Windows hides the camera overlay
controls until Phase 9. The plumbing is built now so Phase 9 is
purely additive on the compositor side, not a contract change.

## Test plan

### Native (C++)

| Test                                          | What it asserts |
| --------------------------------------------- | --------------- |
| `recording_project_reader_test`               | happy + each error variant against fixtures; schema-version drift fails fast |
| `preview_router_test`                         | each method's arg parsing + error-code mapping; sessionId mismatch is no-op not error |
| `player_event_publisher_test`                 | each Emit* method produces the exact macOS-shaped payload; no-listener drops silently |
| `project_open_coordinator_test`               | path queued when no sink → drained on SetSink; new path after SetSink emits immediately; queue cleared on ClearSink |
| `bridge_contract_coverage_test`               | the six new method names have handlers; `pocStage2a*` aliases still routed during deprecation window |

Existing tests (`workflow_event_publisher_test`,
`OverlayUpdateDeduperTests`, etc.) must stay green.

### Dart

| Test                                          | What it asserts |
| --------------------------------------------- | --------------- |
| `test/core/preview/player_controller_test`    | end-to-end shape with channel-mocked native: open → first tick → play → pause → seek → close. Stale-session filtering. |
| `test/core/bridges/native_bridge_test`        | `previewOpen` / `previewClose` / `previewPlay` / `previewPause` / `previewSeekTo` / `getRecordingSceneInfo` round-trip with mocked channel. |
| `test/core/models/app_models_test`            | `RecordingSceneInfo.fromMap` covers Windows's payload exactly, including the `camera` key omitted vs null distinction. |

### Manual / end-to-end

Documented in a new
`docs/decisions/windows-phase-5-implementation-plan-validation.md`
(written alongside Step 5.7):

1. Record a 60 s session with the camera off → preview opens, plays,
   pauses, seeks to several points, closes; no GPU memory growth.
2. Repeat with camera on (camera not composited; just plumbed) →
   `cameraPath` populated; no Dart warnings.
3. Record with the cursor-highlight pipeline active → cursor zoom +
   halo visible during preview.
4. Open the same `.clingfyproj` from the recents list →
   `openProjectRequest` fires, preview opens identically.
5. Double-click a `.clingfyproj` in Explorer (with the dev assoc
   script registered) → runner launches (or focuses existing
   instance) and opens the project.
6. 200-cycle open/close stress (Step 5.7) → no leak, no crash.
7. NVIDIA + AMD verdict runs (Step 5.7) → pass against the same bar
   as Stage 2A-2.

## Out of scope (deliberately deferred)

- **Camera compositing.** Wired in `cameraPath`, not rendered. Phase 9.
- **Real cursor sidecar capture.** The preview reads cursor data the
  recording engine emits; the engine emits a placeholder file today.
  Phase 8 implements real cursor capture during recording.
- **Manual zoom segments.** `capture/zoom.manual.json` is plumbed
  through the reader but the production preview ignores manual zoom
  for now — the heuristic in `PreviewCompositor` is the only zoom
  source. Manual-zoom integration is Phase 6 / 7.
- **Export.** `exportVideo` / `processVideo` stay Phase-1 no-ops.
  Phase 6.
- **Background / theme / effects.** The post-processing surface
  (background colour, ratio, padding) stays untouched.
- **Updater.** WinSparkle is Phase 10.
- **Camera placement drag in preview.** `cameraManualPositionChanged`
  event payload is documented but never emitted in Phase 5. Phase 9.

## Open questions

These need answers **before** their dependent step starts. They are
intentionally not answered in this plan because doing so requires
either a benchmark, a Flutter-internals dive, or a UX call.

1. **Texture unregister option (a) vs (b)** — see Step 5.3. Decision
   gates Step 5.3 PR's design. Owner: whoever picks up 5.3. Approach:
   spike both for a day, pick the one that survives the 200-cycle
   stress test under 5.7.
2. **Shared-texture resize cadence** — should the shared texture
   resize when the Flutter widget resizes, or stay at the natural
   video size? Resizing on every layout change is expensive; locking
   it wastes pixels on 4K. Likely answer: track Flutter's logical
   size but coalesce resizes through a 250 ms debounce. Defer to
   Step 5.3 PR.
3. **`previewSeekTo` race** — macOS gotcha #6 has Dart optimistically
   updating `_posMs` before native confirms. With Windows's
   `playerTick` fired from inside `VideoFrameAvailable`, the
   confirmation lag will be ~16 ms — well under the 250 ms human
   threshold. Probably fine; verify under heavy seeks in the manual
   tests.
4. **`MediaPlayer.IsLoopingEnabled` in production** — the POC enabled
   looping for convenience. Production preview wants the macOS
   behavior of stopping at the end and emitting `playerState:completed`.
   Decided here: **disable looping in production**. Engine fires the
   `MediaEnded` event, the publisher emits
   `{"state":"completed"}`, Dart resets to position 0 and stays
   paused.

## References

- [windows-phase-5-preview-architecture.md](windows-phase-5-preview-architecture.md)
  — the ADR this plan implements.
- [../windows-port.md](../windows-port.md) — Phase 5 row in the
  roadmap table.
- macOS source of truth:
  - `macos/Runner/MainFlutterWindow.swift` (method dispatch)
  - `macos/Runner/Preview/InlinePreviewView.swift` (player + events)
  - `macos/Runner/Services/PreviewSceneResolver.swift`
  - `macos/Runner/Services/RecordingProjectPaths.swift`
  - `macos/Runner/Services/ProjectOpenCoordinator.swift`
- Windows source of truth (existing):
  - `windows/runner/Capture/recording_project_writer.{h,cpp}` (#93)
  - `windows/runner/Bridge/workflow_event_publisher.{h,cpp}` (#93)
  - `windows/runner/preview/poc_stage_2a/stage2a_texture_bridge.{h,cpp}`
    (#102, #104)
  - `windows/runner/preview/preview_compositor.{h,cpp}` (#103)
- Dart contract:
  - `lib/core/bridges/native_method_channel.dart`
  - `lib/core/bridges/native_bridge.dart`
  - `lib/core/preview/player_controller.dart`
  - `lib/core/models/app_models.dart` (RecordingSceneInfo)
