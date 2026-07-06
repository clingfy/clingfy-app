// recording_project_reader — parser for `.clingfyproj` bundles.
//
// Step 5.1 of the Phase 5 implementation plan
// (docs/decisions/windows-phase-5-implementation-plan.md). Reads the
// `project.json` manifest the Windows recording engine writes via
// `recording_project_writer` (PR #93), validates its `schemaVersion`,
// resolves the per-asset paths to absolute filesystem paths, and
// optionally parses `capture/screen.meta.json`.
//
// Pure C++ — no Win32 outside <filesystem>, no Flutter / WinRT / D3D
// dependencies. The reader is intentionally narrow so both
// `getRecordingSceneInfo` (Step 5.2) and `previewOpen` (Step 5.3) can
// share one parser + one validation pass.
//
// Schema fidelity: macOS and Windows are both bound to `schemaVersion:
// 2`. Reading any other version returns `kSchemaVersionMismatch` so a
// future migration is loud rather than silent — see the ADR's "Manifest
// schema fidelity" section.

#ifndef RUNNER_CAPTURE_RECORDING_PROJECT_READER_H_
#define RUNNER_CAPTURE_RECORDING_PROJECT_READER_H_

#include <cstdint>
#include <optional>
#include <string>

#include "Capture/camera_editor_seed.h"

namespace clingfy::capture {

// Parsed contents of `<project>/capture/screen.meta.json`. The Windows
// writer (`BuildScreenMetaJson`) emits this shape; macOS-produced
// bundles include the same numeric fields plus an `editorSeed` blob.
// Step 5.2 reads `editorSeed` back into `editor_seed` since
// `getRecordingSceneInfo` is the consumer (surfaced to Dart as the
// `camera` block). Empty optional when the bundle predates editorSeed
// (older Windows recordings) — the scene-info handler then omits the
// `camera` key, and Dart falls back to a hidden camera.
struct RecordingMetadata {
  std::uint32_t width = 0;
  std::uint32_t height = 0;
  std::uint32_t fps = 0;
  std::uint64_t frames_received = 0;
  std::uint64_t frames_dropped = 0;
  std::uint64_t audio_samples_written = 0;
  bool mic_active = false;
  bool loopback_active = false;
  std::string platform;  // "windows" today; "macos" when read from a Mac bundle.
  std::optional<CameraEditorSeed> editor_seed;
};

// Resolved view of a `.clingfyproj` bundle. All path fields are
// absolute. Optional fields are only set when the manifest references a
// file AND that file exists on disk — Step 5.1's contract is that the
// caller can assume any non-empty path here points at a real file.
struct RecordingProject {
  // Inputs.
  std::wstring project_path;  // absolute path to the .clingfyproj root.

  // Always-required assets. Paths are resolved from the manifest's
  // `capture.screenVideo` / `capture.screenMetadata` keys and verified
  // to exist on disk. If either is missing the reader fails with
  // `kRequiredFileMissing`.
  std::wstring screen_path;
  std::wstring screen_metadata_path;

  // Optional capture-side assets. Missing or absent-on-disk → empty
  // optional. The reader does NOT treat absence as an error: the
  // recording engine emits these in the manifest but the on-disk file
  // may not exist until the cursor-sidecar capture (Phase 8) and
  // manual-zoom segments (Phase 6/7) land.
  std::optional<std::wstring> cursor_path;
  std::optional<std::wstring> zoom_manual_path;

  // Camera assets are present-together-or-not-at-all. If the manifest
  // references them but only one is on disk, the reader fails with
  // `kRequiredFileMissing` (the bundle is broken). When neither exists,
  // both optionals are empty.
  std::optional<std::wstring> camera_video_path;
  std::optional<std::wstring> camera_metadata_path;

  // Parsed `capture/screen.meta.json`. Empty optional when the file
  // exists but does not parse — the read still succeeds and the
  // caller can decide what to do (Step 5.2 falls back to defaults).
  std::optional<RecordingMetadata> metadata;

  // From the manifest. Reader fails with `kSchemaVersionMismatch`
  // unless this equals 2, so callers reading the field only ever see
  // 2 — exposed here so future log lines / metrics can carry the
  // exact value the manifest claimed.
  int schema_version = 0;

  // Phase 10.4: manifest `status` (macOS `RecordingProjectStatus` parity).
  // Missing → "ready" (every pre-10.4 Windows bundle was written with
  // "ready"; tolerating absence keeps old bundles opening). The reader
  // only ever returns a project whose status passed the openable gate
  // (ready/cancelled/failed) — capturing/finalizing/deleted bundles fail
  // with `kProjectNotOpenable`.
  std::string status = "ready";
};

enum class ReadError {
  kNone = 0,
  // `project_path` doesn't exist, isn't a directory, or doesn't contain
  // a `project.json` file.
  kBundleNotFound,
  // `project.json` exists but does not parse — covers truncated files,
  // typos, trailing-comma JSON, malformed strings, etc.
  kManifestInvalidJson,
  // Manifest's `schemaVersion` is missing or != 2.
  kSchemaVersionMismatch,
  // Manifest references a path that isn't on disk. Always applies to
  // `capture.screenVideo` and `capture.screenMetadata`; applies to the
  // camera pair only when one exists without the other.
  kRequiredFileMissing,
  // Phase 10.4: manifest `status` is not openable. Mirrors macOS
  // `ProjectOpenValidator.isOpenableStatus` — "ready"/"cancelled"/"failed"
  // open; "capturing"/"finalizing"/"deleted" (and unknown future values)
  // do not. Keeps an in-flight or swept-away recording from silently
  // opening in preview/export.
  kProjectNotOpenable,
};

struct ReadResult {
  ReadError error = ReadError::kNone;
  // Human-readable detail. Empty on success. Includes the offending
  // path or JSON position when relevant — useful for log triage but
  // never load-bearing on the caller's logic.
  std::string message;
  // Present on success.
  std::optional<RecordingProject> project;
};

// Read `<project_path>/project.json`, validate it, resolve per-asset
// paths, and parse `capture/screen.meta.json`. Returns a `ReadResult`
// with `error == kNone` on success and `project` populated. Otherwise
// `project` is empty and `error` / `message` describe what failed.
//
// `project_path` should be absolute. Relative paths are tolerated but
// the resolved per-asset paths inherit the working directory at call
// time, which makes them brittle for the production preview path that
// expects to receive absolute paths from Dart. Callers should pass
// absolute.
ReadResult ReadRecordingProject(const std::wstring& project_path);

// Exposed for unit tests so the manifest contract can be pinned
// without scaffolding a full filesystem bundle. Parses a raw JSON
// string and produces the same shape `ReadRecordingProject` would, but
// with `project_path` / per-asset paths left empty (because there is
// no filesystem to resolve against). `schema_version` is filled, and
// errors map identically (kManifestInvalidJson / kSchemaVersionMismatch).
ReadResult ParseManifestJson(const std::string& manifest_json);

// Exposed for unit tests. Parses `capture/screen.meta.json` content
// directly into a `RecordingMetadata`. Returns empty optional on
// parse failure (matches the lenient behavior of the full reader).
std::optional<RecordingMetadata> ParseScreenMetaJson(
    const std::string& meta_json);

// Phase 10.4: tolerant, gate-free probe of the lifecycle fields the
// startup recovery sweep needs. Unlike `ReadRecordingProject` /
// `ParseManifestJson` this never rejects a non-openable status (the whole
// point is to find "capturing" bundles) and ignores schemaVersion.
// `parsed` is false only when the JSON itself doesn't parse.
struct ManifestStatusProbe {
  bool parsed = false;
  std::string status;      // empty when the manifest has no status key
  std::string project_id;  // empty when absent
  std::uint32_t owner_pid = 0;  // 0 when absent
};
ManifestStatusProbe ProbeManifestStatus(const std::string& manifest_json);

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_RECORDING_PROJECT_READER_H_
