#ifndef RUNNER_CAPTURE_RECORDING_PROJECT_WRITER_H_
#define RUNNER_CAPTURE_RECORDING_PROJECT_WRITER_H_

#include <cstdint>
#include <optional>
#include <string>

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

  // ISO-8601 timestamp string for the manifest's createdAt / updatedAt.
  // Empty → writer fills in via `std::chrono::system_clock`. Mostly
  // exposed so unit tests can pin a deterministic value.
  std::string created_at_iso8601;

  // Override for the recordings root directory. Empty → resolved from
  // `%LOCALAPPDATA%\Clingfy\recordings`. Tests pass a temp directory.
  std::string recordings_root_override;
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
  // On success, absolute path to the `.clingfyproj` folder. Empty
  // otherwise.
  std::string project_path;
};

ProjectWriterResult WriteRecordingProject(const ProjectWriterInput& input);

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
