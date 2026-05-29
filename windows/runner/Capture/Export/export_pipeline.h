// Slice 2 of Phase 6 (export) — the decode → composite → re-encode
// pipeline that backs every non-identity export (any layout/resolution
// the user picks other than auto/auto).
//
// Flow, all on a single shared D3D11 device so textures never cross
// devices:
//   1. IMFSourceReader decodes the recording's `screen.mov`:
//        - the video stream to BGRA (ARGB32) system memory, and
//        - the audio stream (if present) to 48 kHz stereo int16 PCM.
//   2. For each decoded video frame, Direct2D clears a target-resolution
//      BGRA render texture to black and draws the frame into the
//      fit/fill content rect computed by `export_geometry.h`. (Slice 3
//      extends this same draw with background / padding / corner radius.)
//   3. The composited texture is handed to the existing
//      `MfSinkWriterEncoder` (H.264 / .mov) configured at the output
//      resolution. Audio packets are written straight through so the
//      resized export keeps its sound — gain / normalize is Slice 4.
//   4. Streams are pulled interleaved by timestamp via
//      `ReadSample(MF_SOURCE_READER_ANY_STREAM)` so the sink writer never
//      sees one stream race far ahead of the other.
//
// Synchronous and headless (no window, no swap chain) so it can run from
// the bridge handler thread and be exercised by a round-trip GoogleTest.
// `export_passthrough.cpp` owns the identity fast-path and only calls
// here when real composition is required.

#ifndef RUNNER_CAPTURE_EXPORT_EXPORT_PIPELINE_H_
#define RUNNER_CAPTURE_EXPORT_EXPORT_PIPELINE_H_

#include <cstdint>
#include <string>

namespace clingfy::capture::export_ {

// Everything the pipeline needs to render one export. The caller
// (`ExportPassthroughCopy`) resolves the source/destination paths and
// pulls the layout/resolution/fit straight from the Dart args; the true
// source dimensions are read from the decoder, not trusted from metadata.
struct RenderRequest {
  // Absolute path to the recorded source video (`capture/screen.mov`).
  std::wstring source_video_path;

  // Absolute UTF-8 destination path (already .mov-forced + collision-
  // avoided by `ResolveExportDestination`).
  std::string destination_path;

  // Composition selectors, verbatim from the export args. Parsed through
  // the `export_geometry` helpers so framing matches macOS exactly.
  std::string layout;
  std::string resolution;
  std::string fit;

  // Output frame rate hint from the recording metadata; 0 falls back to
  // 30 fps. The actual sample timing comes from the decoded timestamps —
  // this only seeds the encoder's rate attribute.
  std::uint32_t fps_hint = 0;
};

struct RenderResult {
  bool ok = false;
  // Human-readable failure detail (empty on success). Surfaced in the
  // FlutterError `details` for triage.
  std::string message;

  // Populated on success for logging / tests.
  std::uint32_t output_width = 0;
  std::uint32_t output_height = 0;
  std::uint64_t video_frames_written = 0;
  std::uint64_t audio_packets_written = 0;
  // True when the source carried an audio track that was carried through.
  bool had_audio = false;
};

// Run the full decode → composite → re-encode pass. Synchronous; returns
// only after the output file is finalized (or a failure leaves no usable
// file). Never throws — all Media Foundation / Direct2D failures are
// reported through `RenderResult::ok` + `message`.
RenderResult RenderComposedExport(const RenderRequest& request);

}  // namespace clingfy::capture::export_

#endif  // RUNNER_CAPTURE_EXPORT_EXPORT_PIPELINE_H_
