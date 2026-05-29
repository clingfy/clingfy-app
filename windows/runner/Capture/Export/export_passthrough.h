// Phase 6 (export) entry point. Slice 1 shipped a straight passthrough
// copy of the project's `capture/screen.mov`; Slice 2 adds the real
// resolution / layout / fit composition pass. Future slices layer the
// rest on top:
//   Slice 1: passthrough copy (auto/auto stays here as the fast-path)
//   Slice 2: resolution / layout / fit (Media Foundation decode →
//            Direct2D composite → re-encode), audio carried through
//   Slice 3: background + padding + corner radius (extends the Slice 2
//            Direct2D composite)
//   Slice 4: audio gain + volume + normalize
//   Slice 5: format / codec / bitrate + cleanup
//
// The handler in `Bridge/Routers/export_router.cpp` parses the 22-arg
// `exportVideo` map and fills a `PassthroughInput`. Errors are mapped
// onto the existing `native_error_codes.h` strings so the Dart side
// surfaces them through the same path macOS uses.
//
// Two output paths, chosen by `export_geometry::IsIdentityTransform`:
//   * layout=auto & resolution=auto → no reframing is needed, so the
//     source is copied byte-for-byte (lossless, instant, preserves the
//     original audio + container). This is the Slice 1 behavior.
//   * any other layout/resolution → the recording is decoded, composited
//     at the chosen output resolution with the chosen fit mode, and
//     re-encoded (see `export_pipeline.h`). The source audio is carried
//     through so the resized export is not silent (gain/normalize is
//     Slice 4).
//
// Why .mov extension forced: the recorder writes a QuickTime MOV
// container (mp4-family) and the re-encode pass writes the same
// container. Honoring the user's mp4/gif choice needs the format matrix
// Slice 5 adds; until then the output extension is forced to `.mov` so
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

  // The format the Dart side asked for ("mp4" / "mov" / "gif"). Output
  // is always written as .mov until Slice 5 wires the format matrix; the
  // value is kept so the Result can report a mismatch back for logging.
  std::string format;

  // Slice 2 composition args, straight from the `exportVideo` map. Empty
  // / "auto" leaves the export on the copy fast-path; any concrete value
  // routes through the decode → composite → re-encode pipeline.
  //   layout     — auto | classic43 | square11 | youtube169 | reel916
  //   resolution — auto | p1080 | p1440 | p2160 | p4320
  //   fit        — fit | fill   (defaults to "fit" when empty)
  std::string layout;
  std::string resolution;
  std::string fit;
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
  // The decode → composite → re-encode pipeline failed (bad source,
  // unsupported media type, encoder/Direct2D error). Maps to
  // EXPORT_ERROR. Carries the underlying detail in `message`.
  kRenderFailed,
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

// Export entry point. Reads the project, resolves the source video path
// via `RecordingProjectReader`, and computes the destination via
// `ResolveExportDestination`. Then dispatches:
//   * identity transform (layout=auto & resolution=auto) → copies the
//     source byte-for-byte (Slice 1 behavior).
//   * otherwise → decodes, composites at the requested resolution/layout/
//     fit, and re-encodes via `export_pipeline.h`.
// Synchronous — the work completes before this returns. The copy path is
// sub-second; the re-encode path scales with clip length but Slice 2
// does not yet emit `updateExportProgress` (that lands with cancel in
// Slice 5).
PassthroughResult ExportPassthroughCopy(const PassthroughInput& input);

}  // namespace clingfy::capture::export_

#endif  // RUNNER_CAPTURE_EXPORT_EXPORT_PASSTHROUGH_H_
