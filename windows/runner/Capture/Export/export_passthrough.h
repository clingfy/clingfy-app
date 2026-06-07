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
//   Slice 5A: mp4 container + bitrate + progress + cancel
//   Slice 5B: gif (WIC animated GIF, frame-decimated to ~kGifTargetFps)
//
// The handler in `Bridge/Routers/export_router.cpp` parses the `exportVideo`
// map and fills a `PassthroughInput`. Errors are mapped onto the existing
// `native_error_codes.h` strings so the Dart side surfaces them through the
// same path macOS uses.
//
// Two output paths:
//   * No compositing needed — identity transform (layout=auto &
//     resolution=auto), no Slice 3 styling (zero padding/corner radius), no
//     Slice 4 audio change, AND a .mov output (mp4 needs a real re-encode) →
//     the source is copied byte-for-byte (lossless, instant, preserves the
//     original audio + container). This is the Slice 1 behavior. (A background
//     color alone is invisible without margins, so it does not by itself
//     defeat the copy.)
//   * Otherwise → the recording is decoded, composited at the chosen output
//     resolution / fit with the Slice 3 styling, the audio scaled by the
//     Slice 4 gain/volume/normalize, and re-encoded (see `export_pipeline.h`)
//     into the requested container (.mp4 / .mov) at the Slice 5A bitrate, or
//     written as an animated .gif (Slice 5B) when the format is "gif".
//
// Container: the output extension follows the `format` arg (.mp4 / .mov / .gif,
// `export_format.h`). For .mp4/.mov the Media Foundation Sink Writer picks the
// container from the extension; for .gif the pipeline drives the WIC GifEncoder
// (a real animated GIF, no longer a downgrade). Codec stays H.264 for video on
// Windows (a Dart `codec: hevc` request is currently rendered as H.264 — HEVC
// is a future slice).

#ifndef RUNNER_CAPTURE_EXPORT_EXPORT_PASSTHROUGH_H_
#define RUNNER_CAPTURE_EXPORT_EXPORT_PASSTHROUGH_H_

#include <cstdint>
#include <functional>
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

  // The format the Dart side asked for ("mp4" / "mov" / "gif"). Selects the
  // output extension/encoder via `export_format.h`: .mp4/.mov (H.264 Sink
  // Writer) or .gif (WIC GifEncoder, Slice 5B). For gif the Dart side still
  // sends a stale codec/bitrate (the dialog hides them) — both are ignored.
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

  // Slice 3 canvas styling args from the `exportVideo` map. `padding` and
  // `corner_radius` are raw output pixels (the Dart slider ranges 0-100 /
  // 0-50 are passed through unscaled, matching macOS). `background_color`
  // is a packed 0xAARRGGBB int; nullopt (Dart `null`) => opaque black.
  // Padding or a corner radius forces the composition path even under an
  // otherwise-identity transform. Background image / preset are not handled
  // yet (Slice 3 is solid color only).
  double padding = 0.0;
  double corner_radius = 0.0;
  std::optional<std::int64_t> background_color;

  // Slice 4 audio args from the `exportVideo` map. gain (dB, 0..24, amplify
  // only) and volume (%, 0..100, attenuate only) scale the decoded PCM;
  // auto_normalize peak-normalizes toward target_loudness_dbfs (dBFS,
  // -24..-6). Any non-default value forces the re-encode path. Defaults are
  // the identity values that keep the byte-for-byte copy fast-path alive —
  // volume MUST default to 100.0 (not 0.0) or every export re-encodes.
  double audio_gain_db = 0.0;
  double audio_volume_percent = 100.0;
  bool auto_normalize = false;
  double target_loudness_dbfs = -16.0;

  // Slice 5A: requested output bitrate preset ("auto"/"low"/"medium"/"high").
  // The `format` field above selects the container (.mp4 vs .mov).
  std::string bitrate;

  // Phase 8.2 cursor rendering. `show_cursor` (Dart default true) draws the
  // recorded cursor sidecar into the export; `cursor_size` (0.5..3.0, default
  // 1.5) scales it. When the recording has a `capture/cursor.jsonl` and
  // show_cursor is on, the export takes the composition path (a byte-copy cannot
  // draw the cursor) — the recording itself stays cursorless.
  bool show_cursor = true;
  double cursor_size = 1.5;
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
  // Slice 5A: the export was cancelled by the user mid-flight. Maps to
  // EXPORT_ERROR with a "cancelled" message so the Dart side classifies it as
  // a clean cancel (returns null, lastExportWasCancelled=true) rather than a
  // surfaced error.
  kCancelled,
};

struct PassthroughResult {
  PassthroughError error = PassthroughError::kNone;
  // Human-readable detail; empty on success. Used in the FlutterError
  // `details` field for triage but never load-bearing on Dart logic.
  std::string message;
  // Absolute path of the produced output file. Empty on error.
  std::string output_path;
  // Retained result-contract field. Windows now emits .mov/.mp4/.gif natively
  // (Slices 5A/5B), so nothing is downgraded and this is always false.
  bool format_was_downgraded = false;
};

// Pure path resolver: combines directory + filename + a forced .mov
// extension into an absolute output path. Exposed for tests so the
// extension / sanitization rules can be pinned without touching the
// filesystem. `filename_stem` is normalized:
//   - empty / whitespace → "Untitled"
//   - any extension already present is stripped (so passing "foo.mp4"
//     produces "foo.mov" when format is mov/empty)
// `format` ("mp4"/"mov"/"gif"/...) selects the extension (.mp4 / .mov / .gif)
// via `export_format.h`; defaults to .mov.
std::string ResolveExportDestination(const std::string& directory,
                                     const std::string& filename_stem,
                                     const std::string& format = "");

// Export entry point. Reads the project, resolves the source video path
// via `RecordingProjectReader`, and computes the destination via
// `ResolveExportDestination`. Then dispatches:
//   * identity transform + no styling/audio → copies the source byte-for-byte
//     (Slice 1 behavior).
//   * otherwise → decodes, composites at the requested resolution/layout/fit
//     with the Slice 3/4 styling + audio, and re-encodes via
//     `export_pipeline.h` into the requested container/bitrate.
// Synchronous — the work completes before this returns; the router runs it on
// a worker thread so it can be cancelled. `on_progress` (optional) receives a
// 0..1 fraction; `is_cancelled` (optional) is polled so a cancel aborts and
// returns PassthroughError::kCancelled. Both default to no-ops.
PassthroughResult ExportPassthroughCopy(
    const PassthroughInput& input,
    std::function<void(double)> on_progress = {},
    std::function<bool()> is_cancelled = {});

}  // namespace clingfy::capture::export_

#endif  // RUNNER_CAPTURE_EXPORT_EXPORT_PASSTHROUGH_H_
