#ifndef RUNNER_CAPTURE_RECORDING_PROJECT_WRITER_H_
#define RUNNER_CAPTURE_RECORDING_PROJECT_WRITER_H_

#include <cstdint>
#include <optional>
#include <string>

#include "Capture/camera_editor_seed.h"

// Phase 3E project-folder writer.
//
// Reshapes the encoder's `%TEMP%\clingfy_<sessionId>.mp4` into the
// `.clingfyproj` bundle the macOS engine produces, so the Dart side
// (`RecordingProjectRef.open(projectPath:)`) can open a Windows
// recording with no platform-specific branching.
//
// Folder layout (from `macos/Runner/Services/RecordingProjectPaths.swift`):
//
//   <sessionId>.clingfyproj/
//     project.json               manifest, status: "ready"
//     capture/
//       screen.mov               MP4 from the encoder (renamed; Dart
//                                does not parse the extension)
//       screen.meta.json         capture metadata (size, fps, frames)
//     post/
//       state.json               post-processing scaffold (empty
//                                Phase 3E; populated by 6+)
//
// The writer is intentionally narrow: file I/O only, no Win32 / no MF,
// so the happy path is unit-testable by pointing `recordings_root` at a
// temp directory.
namespace clingfy::capture {

// Phase 7.2: the captured source region, in physical pixels. For area recording
// this is the crop rect on the monitor; written into screen.meta.json so
// downstream tooling knows the recording's origin/size within its display.
struct SourceBounds {
  std::int32_t x = 0;
  std::int32_t y = 0;
  std::int32_t width = 0;
  std::int32_t height = 0;
};

struct ProjectWriterInput {
  // Caller-supplied sessionId from `StartRecordingRequest`. Used as the
  // project id AND as the manifest's `projectId` field; the Dart side
  // re-emits this in `_handleRecordingFinalizedEvent` so the values
  // must round-trip.
  std::string session_id;

  // Absolute path to the encoder's MP4 output. The writer renames /
  // moves this into `capture\screen.mov`; if the source file is
  // missing the writer fails with `kSourceMissing`.
  std::string source_mp4_path;

  // Encoder diagnostics — populated into capture/screen.meta.json. All
  // fields are optional; absent values are omitted from the JSON.
  std::uint32_t width = 0;
  std::uint32_t height = 0;
  std::uint32_t fps = 0;
  std::uint64_t frames_received = 0;
  std::uint64_t frames_dropped = 0;
  std::uint64_t audio_samples_written = 0;
  bool mic_active = false;
  bool loopback_active = false;

  // Phase 7.1/7.2 capture target metadata, written into capture/screen.meta.json.
  // `target_type` is "display" | "window" | "area" (defaults to display).
  // `window_id` is the HWND-as-int64 for window captures (absent otherwise) —
  // session-only, recorded for diagnostics, not for re-resolution.
  // `source_bounds` is the captured region within the display (area captures).
  std::string target_type = "display";
  std::optional<std::int64_t> window_id;
  std::optional<SourceBounds> source_bounds;

  // Phase 8.1 cursor sidecar. `cursor_sidecar_path` is the temp `cursor.jsonl`
  // the sampler streamed during recording; the writer moves it into
  // `capture/cursor.jsonl` (best-effort) and, on success, sets the manifest
  // `cursorData` pointer + `cursorEnabled` flag. `cursor_enabled` reflects the
  // ENGINE's intent (the sampler ran + cursor was stripped from the video); the
  // writer downgrades it to false if the file is missing / cannot be bundled.
  std::string cursor_sidecar_path;
  bool cursor_enabled = false;

  // Phase 9.2 camera capture. `camera_raw_path` is the temp `.mp4` the camera
  // recorder streamed; the writer moves it into `camera/raw.mov` (best-effort)
  // and writes `camera/camera.meta.json` from `camera_meta_json`. `camera_enabled`
  // reflects the engine's outcome (the recorder ran AND produced >0 frames); the
  // writer downgrades it to false (and omits the manifest `camera` block) if the
  // raw file is missing / cannot be bundled. When false, NO camera block is
  // emitted — the reader treats an absent block as "no camera", same as a
  // recording made without one.
  std::string camera_raw_path;
  std::string camera_meta_json;
  bool camera_enabled = false;

  // Audio separation (docs/decisions/windows-audio-separation.md D1): the
  // finalized mic / system sidecar temps the engine's AudioSidecarWriters
  // produced. The writer moves them into `capture/mic.m4a` /
  // `capture/system.m4a` (best-effort, independently — never
  // present-together) and, per bundled file, emits the macOS Phase 1.5
  // manifest key `capture.micAudio` / `capture.systemAudio`. A missing /
  // unmovable file downgrades its flag (key omitted); the premixed track
  // in screen.mov is unaffected either way.
  std::string mic_audio_path;
  bool mic_audio_enabled = false;
  std::string system_audio_path;
  bool system_audio_enabled = false;

  // The recording-time camera composition, written into
  // capture/screen.meta.json as the `editorSeed` block (macOS parity) so
  // post-processing reopens camera-on with the user's settings. The engine
  // fills this from the live overlay style (CameraOverlayStyleStore) at stop;
  // `visible` reflects whether a camera actually produced frames. Always
  // emitted — a camera-less recording writes `cameraVisible: false` + defaults,
  // matching macOS which always persists an editorSeed.
  CameraEditorSeed editor_seed;

  // ISO-8601 timestamp string for the manifest's createdAt / updatedAt.
  // Empty → writer fills in via `std::chrono::system_clock`. Mostly
  // exposed so unit tests can pin a deterministic value.
  std::string created_at_iso8601;

  // Override for the recordings root directory. Empty → resolved from
  // `%LOCALAPPDATA%\Clingfy\recordings`. Tests pass a temp directory.
  std::string recordings_root_override;

  // Phase 10.4: manifest lifecycle status, mirroring macOS
  // `RecordingProjectStatus` ("capturing" | "finalizing" | "ready" |
  // "cancelled" | "failed" | "deleted"). The Stop path writes "ready";
  // the finalize-failure rescue path writes "failed". Only
  // "ready"/"cancelled"/"failed" are openable (see ProjectOpenValidator on
  // macOS and the Windows reader's status gate).
  std::string status = "ready";

  // Phase 10.4: PID of the recording process, emitted as `ownerPid` when
  // non-zero. The startup recovery sweep uses it to distinguish a bundle
  // owned by a LIVE process (dev + prod builds share the recordings root
  // until Phase 10.5 splits identities) from one stranded by a crash.
  std::uint32_t owner_pid = 0;
};

enum class ProjectWriterErrorKind {
  kNone,
  kBadInput,
  kSourceMissing,
  kFilesystem,
};

struct ProjectWriterResult {
  ProjectWriterErrorKind kind = ProjectWriterErrorKind::kNone;
  std::string message;
  // On success, absolute path to the `.clingfyproj` folder (UTF-8 — the
  // writer builds and reports paths as UTF-8 so the recovery/cleanup
  // consumers' fs::u8path round-trips are exact on non-ASCII roots).
  // Empty otherwise.
  std::string project_path;
  // Phase 10.4 (review fix): best-effort sidecar bundling DOWNGRADES — the
  // input requested the sidecar but the file could not be moved into the
  // bundle, so it is still sitting in %TEMP%. The engine must not treat
  // that leftover as a deletable straggler: for the camera it is the only
  // copy of finalized, playable footage.
  bool cursor_downgraded = false;
  bool camera_downgraded = false;
  // Audio separation: requested sidecar could not be bundled (its temp is
  // still in %TEMP%). Unlike the camera, a leftover audio sidecar is NOT
  // precious — the premixed track still carries the audio — so cleanup may
  // delete it; the flags exist for logging/diagnostics.
  bool mic_audio_downgraded = false;
  bool system_audio_downgraded = false;
};

ProjectWriterResult WriteRecordingProject(const ProjectWriterInput& input);

// Phase 10.4: writes the PROVISIONAL project bundle at recording start —
// the bundle directory plus a `project.json` with `status: "capturing"` and
// `ownerPid`, mirroring macOS `RecordingProjectService.writeProjectFiles`.
// If the process dies mid-recording, the next-launch recovery sweep finds
// this manifest and marks the project failed instead of leaving the user
// with nothing but a stranded `%TEMP%` file. Best-effort by design: the
// engine logs a failure but never refuses to record because of it.
// The Stop path's `WriteRecordingProject` later overwrites this manifest
// with the full `status: "ready"` one.
struct ProvisionalProjectInput {
  std::string session_id;
  std::string recordings_root_override;  // empty → default root
  std::string created_at_iso8601;        // empty → now
  std::uint32_t owner_pid = 0;           // 0 → GetCurrentProcessId()
};

ProjectWriterResult WriteProvisionalProject(
    const ProvisionalProjectInput& input);

// Exposed for unit tests: builds the JSON string for `project.json` so
// the manifest contract can be pinned without touching the filesystem.
std::string BuildManifestJson(const ProjectWriterInput& input);

// Build the capture/screen.meta.json contents. Same testability
// rationale as `BuildManifestJson`.
std::string BuildScreenMetaJson(const ProjectWriterInput& input);

// ISO-8601 timestamp (`YYYY-MM-DDTHH:MM:SS.sssZ`) for the current
// system clock. Public for tests that want to compare the format.
std::string CurrentIso8601Timestamp();

// Default recordings root (`%LOCALAPPDATA%\Clingfy\recordings`).
// Public so the engine can quote it back to Dart in `getCaptureDiagnostics`.
std::string ResolveDefaultRecordingsRoot();

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_RECORDING_PROJECT_WRITER_H_
