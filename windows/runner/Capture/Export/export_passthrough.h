// Slice 1 of Phase 6 (export) — straight passthrough copy of the project's
// `capture/screen.mov` to a user-chosen destination path. No transcoding,
// no composition, no audio post-processing. Future slices layer those on
// top:
//   Slice 2: resolution / layout / fit
//   Slice 3: background + padding + corner radius (Direct2D composition)
//   Slice 4: audio gain + volume + normalize
//   Slice 5: format / codec / bitrate + cleanup
//
// The handler in `Bridge/Routers/export_router.cpp` parses the 22-arg
// `exportVideo` map, picks out the four args this slice actually uses
// (projectPath, directoryOverride, filename, format), and calls into here.
// Errors are mapped onto the existing `native_error_codes.h` strings so
// the Dart side surfaces them through the same path macOS uses.
//
// Why .mov extension forced: the recorder writes a QuickTime MOV
// container (mp4-family); transcoding to a real MP4 or GIF needs a
// Media Foundation Source Reader + Sink Writer pass, which Slice 5
// adds. Until then, this slice forces the output extension to `.mov` so
// what the user sees on disk matches what's actually in the file. The
// `format` arg is still logged on a mismatch so we don't lose the
// signal that the user picked something else.

#ifndef RUNNER_CAPTURE_EXPORT_EXPORT_PASSTHROUGH_H_
#define RUNNER_CAPTURE_EXPORT_EXPORT_PASSTHROUGH_H_

#include <optional>
#include <string>

namespace clingfy::capture::export_ {

// Inputs the router pulls out of the `exportVideo` arg map.
struct PassthroughInput {
  // Absolute path to the .clingfyproj root (Dart side already resolves
  // this via the project bundle URL).
  std::string project_path;

  // User-chosen output directory (from Dart's file-save UX). Empty when
  // the user did not override the default; in that case the handler
  // returns kBadArgs since Slice 1 has no default-folder fallback yet.
  std::string directory_override;

  // User-chosen file stem (no extension). Empty → "Untitled".
  std::string filename;

  // The format the Dart side asked for ("mp4" / "mov" / "gif"). Slice 1
  // always writes .mov regardless; the value is kept so the Result can
  // report a mismatch back to the caller for logging.
  std::string format;
};

enum class PassthroughError {
  kNone = 0,
  // Missing or unreadable `.clingfyproj`. Maps to EXPORT_INPUT_MISSING.
  kInputMissing,
  // `directoryOverride` missing/empty AND no default fallback yet
  // (Slice 1 has none). Maps to BAD_ARGS.
  kNoDestination,
  // std::filesystem::copy_file threw or returned an error code. Maps to
  // EXPORT_ERROR.
  kCopyFailed,
};

struct PassthroughResult {
  PassthroughError error = PassthroughError::kNone;
  // Human-readable detail; empty on success. Used in the FlutterError
  // `details` field for triage but never load-bearing on Dart logic.
  std::string message;
  // Absolute path of the produced output file. Empty on error.
  std::string output_path;
  // True when `format` was something other than "mov" — the handler
  // logs a soft warning so a future Slice 5 user report ("I asked for
  // MP4 but got MOV") is diagnosable from the existing log.
  bool format_was_downgraded = false;
};

// Pure path resolver: combines directory + filename + a forced .mov
// extension into an absolute output path. Exposed for tests so the
// extension / sanitization rules can be pinned without touching the
// filesystem. `filename_stem` is normalized:
//   - empty / whitespace → "Untitled"
//   - any extension already present is stripped (so passing "foo.mp4"
//     produces "foo.mov", matching the docstring "force .mov")
std::string ResolveExportDestination(const std::string& directory,
                                     const std::string& filename_stem);

// Slice 1 entry point. Reads the project, resolves the source video
// path via `RecordingProjectReader`, and copies it to the destination
// computed via `ResolveExportDestination`. Synchronous — the copy
// completes before this returns. No progress event is emitted (a few-MB
// file copies in tens of milliseconds; later slices that re-encode get
// the real `updateExportProgress` plumbing).
PassthroughResult ExportPassthroughCopy(const PassthroughInput& input);

}  // namespace clingfy::capture::export_

#endif  // RUNNER_CAPTURE_EXPORT_EXPORT_PASSTHROUGH_H_
