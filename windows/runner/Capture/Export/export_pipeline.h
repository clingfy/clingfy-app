// Slice 2 of Phase 6 (export) — the decode → composite → re-encode
// pipeline that backs every non-identity export (any layout/resolution
// the user picks other than auto/auto).
//
// Flow, all on a single shared D3D11 device so textures never cross
// devices:
//   1. IMFSourceReader decodes the recording's `screen.mov`:
//        - the video stream to BGRA (ARGB32) system memory, and
//        - the audio stream (if present) to 48 kHz stereo int16 PCM.
//   2. For each decoded video frame, Direct2D fills a target-resolution
//      BGRA render texture with the background color and draws the frame
//      into the fit/fill content rect (inset by any padding) computed by
//      `export_geometry.h`, clipping the draw to a rounded rect when a
//      corner radius is set (Slice 3).
//   3. The composited texture is handed to an encoder configured at the output
//      resolution: `MfSinkWriterEncoder` (H.264 in .mp4 / .mov) for video, or
//      the WIC `GifEncoder` (Slice 5B) when the destination ends in .gif. Audio
//      packets are scaled by the resolved gain / volume / normalize multiplier
//      (Slice 4, see `export_audio.h`) and written through for video; GIF has no
//      audio and decimates frames to ~`kGifTargetFps` (see `gif_export_policy.h`).
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

#include <windows.h>  // HRESULT (Phase 10.4 disk-full classification)

#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <vector>

#include "Capture/Export/clip_playback_planner.h"
#include "Capture/Export/color_grade.h"

namespace clingfy::capture::export_ {

// Everything the pipeline needs to render one export. The caller
// (`ExportPassthroughCopy`) resolves the source/destination paths and
// pulls the layout/resolution/fit straight from the Dart args; the true
// source dimensions are read from the decoder, not trusted from metadata.
struct RenderRequest {
  // Absolute path to the recorded source video (`capture/screen.mov`).
  std::wstring source_video_path;

  // Editing port (color): the grade baked into the export. Identity (the
  // default) keeps the composite byte-identical to before. Applied to the
  // screen video + cursor + click ripples — NOT the background or the camera
  // bubble — matching the macOS precomposited-canvas order (cursor/clicks
  // bake into the intermediate BEFORE the grade; the camera drafts on top
  // after).
  color::ColorGrade color_grade;

  // Editing port (clips): kept source ranges in TIMELINE order (empty = no clips
  // = identity, byte-identical to the pre-clip path). Any real edit reaches
  // here: MONOTONIC + disjoint ranges (cut / trim / delete-middle) forward-read
  // the source once, while REORDER / OVERLAP (non-monotonic) read each range's
  // source window in timeline order via per-range backward seeks (3b-2). The
  // frame loop drops source frames that fall in a cut gap
  // (`clip_planner::EditedMsForKeptSourceMs` → nullopt) and re-stamps the
  // survivors onto the compacted edited timeline; audio is stitched
  // sample-accurately (the monotonic in-loop copy, or the decoupled reorder
  // pump). Zoom smoothing + the camera intro/outro clock run in edited time,
  // while the drawn frame's overlays (cursor/zoom-segment/camera-video) stay
  // keyed to its SOURCE time.
  std::vector<clip_planner::ClipKeptRange> clip_ranges;

  // Absolute UTF-8 destination path (extension already resolved — .mov / .mp4 /
  // .gif — and collision-avoided by `ResolveExportDestination`). The pipeline
  // selects the container/encoder from this extension (.gif => WIC GifEncoder).
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

  // Slice 3 canvas styling, verbatim from the export args (see
  // `export_geometry.h` for the resolution rules):
  //   padding        — symmetric inset in output pixels (0 = none).
  //   corner_radius  — rounded-corner radius in output pixels applied to
  //                    the video rect (0 = square); clamped to half the
  //                    shorter content side.
  //   background_color — packed 0xAARRGGBB fill behind/around the video;
  //                    nullopt (the Dart default) => opaque black.
  double padding = 0.0;
  double corner_radius = 0.0;
  std::optional<std::int64_t> background_color;
  // Absolute path to a bundled background image (inside the .clingfyproj), or
  // empty for a colour background. Drawn scaled-to-COVER over the fill, so a
  // missing or undecodable file degrades to the colour rather than to nothing.
  std::wstring background_image_path;

  // Slice 4 audio processing, verbatim from the export args (see
  // `export_audio.h`). Gain amplifies (0..24 dB), volume attenuates
  // (0..100%); when auto_normalize is set the export peak-normalizes toward
  // target_loudness_dbfs. Defaults are the identity (no-op) values, so an
  // export that requests none of them re-encodes the audio unchanged.
  double audio_gain_db = 0.0;
  double audio_volume_percent = 100.0;
  bool auto_normalize = false;
  double target_loudness_dbfs = -16.0;

  // Audio separation (D8): the PROBED-decodable sidecar tracks. Set only
  // when export_passthrough's ProbeDecodableAudio passed for that file —
  // the pipeline trusts a non-empty path to open. When either is set the
  // separated tracks REPLACE the embedded premix (deselected entirely) and
  // audio runs through per-track ReorderAudioPumps mixed down to the single
  // output AAC track; gain/normalize apply to the mic pump only, volume to
  // both (macOS separated semantics). Both empty = today's embedded path.
  std::wstring mic_audio_path;
  std::wstring system_audio_path;

  // Slice 5A. `bitrate` is the requested preset ("auto"/"low"/"medium"/
  // "high"), resolved to an H.264 average bitrate against the output size.
  // The output container is chosen from `destination_path`'s extension
  // (.mp4 vs .mov). `on_progress` receives a 0..1 fraction; `is_cancelled`
  // is polled each frame so a cancel aborts the loop cleanly. Both default to
  // no-ops — a synchronous export (or a test) needs neither.
  std::string bitrate;
  std::function<void(double)> on_progress;
  std::function<bool()> is_cancelled;

  // Phase 8.2 cursor rendering. When `show_cursor` is true and
  // `cursor_sidecar_path` names a readable `cursor.jsonl`, the composite draws
  // the cursor (a standard arrow) at the sidecar position interpolated to each
  // frame's timestamp, scaled by `cursor_size` (0.5..3.0). Empty path / false =
  // no cursor. A missing or malformed sidecar is non-fatal (renders no cursor).
  bool show_cursor = false;
  double cursor_size = 1.5;
  // The shared cursor sidecar (`capture/cursor.jsonl`); used by BOTH the cursor
  // renderer (8.2) and the smart-zoom controller (8.3). Set whenever either
  // feature is active.
  std::wstring cursor_sidecar_path;

  // Phase 8.3 smart zoom. When `zoom_enabled` and a sidecar is present, the
  // export auto-generates zoom segments from the recorded clicks + cursor path
  // and applies a smoothed zoom transform (magnified by `zoom_factor`, 1.0..3.0;
  // <= 1 → no zoom). Soft-fail: missing/malformed sidecar or no segments → no
  // zoom. Manual zoom segments are NOT consumed yet (Windows getZoomSegments is a
  // stub — deferred).
  bool zoom_enabled = false;
  double zoom_factor = 1.5;

  // Phase 9.4 camera bubble. When `draw_camera` is true and `camera_video_path`
  // names a readable `camera/raw.mov`, the composite draws the camera as a
  // masked bubble in CANVAS space (on top of everything, NOT under the smart-
  // zoom transform). All gating — camera visible, previewBurnedIn == false,
  // frames > 0, assets present-together — happens upstream in
  // `export_passthrough`; the pipeline just renders what it is handed and
  // soft-fails (no camera) on any reader / D2D resource failure.
  bool draw_camera = false;
  std::wstring camera_video_path;
  // Recording-relative ms of the camera's first frame (camera.meta.json sync
  // key): the camera frame for screen-time `tMs` is at `tMs - startOffsetMs`.
  std::int64_t camera_start_offset_ms = 0;
  // Bubble placement, from the Dart `camera*` export args. `has_center` true
  // uses the manual normalized center; otherwise the layout preset's default
  // corner is used. size_factor is the fraction of the shorter canvas side.
  bool camera_has_center = false;
  double camera_center_x = 0.0;
  double camera_center_y = 0.0;
  std::string camera_layout_preset;
  double camera_size_factor = 0.18;
  // Shape ("circle" / "roundedRect" / "square" / "squircle"), corner radius
  // (Dart 0..0.5 fraction), and content mode ("fill" cover / "fit" contain).
  std::string camera_shape;
  double camera_corner_radius = 0.0;
  std::string camera_content_mode;
  // Phase 9.5 styling. mirror flips the camera content horizontally; opacity
  // (0..1) fades it; border_width (px) + border_color_argb (0xAARRGGBB, nullopt
  // = no border) stroke the bubble; shadow_preset (0 none, 1/2/3) drops a
  // blurred shadow. Unsupported/malformed values soft-fail (no styling), never a
  // failed export.
  bool camera_mirror = false;
  double camera_opacity = 1.0;
  double camera_border_width = 0.0;
  std::optional<std::int64_t> camera_border_color_argb;
  int camera_shadow_preset = 0;
  // Phase 9.7 chroma key. enabled → the camera content's key color (argb, nullopt
  // = default green) within `strength` tolerance (0..1) is keyed transparent.
  // Applies to the camera layer only; border/shadow are unaffected. Soft-fails to
  // an unkeyed camera on any effect failure, never a failed export.
  bool camera_chroma_enabled = false;
  double camera_chroma_strength = 0.4;
  std::optional<std::int64_t> camera_chroma_color_argb;
  // Phase 9.7 intro/outro animation preset names ("none"/"fade"/"pop"/"slide",
  // "shrink") + durations (ms). Unknown names soft-fail to a static bubble.
  std::string camera_intro_preset;
  std::string camera_outro_preset;
  int camera_intro_duration_ms = 0;
  int camera_outro_duration_ms = 0;
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
  // Slice 5A: true when the export was aborted by a cancel request (ok stays
  // false). Lets the caller map it to a clean cancellation reply rather than a
  // generic failure.
  bool cancelled = false;
  // Phase 10.4: true when the failure was classified as the destination
  // volume running out of space mid-write (the encoder error carried a
  // disk-full HRESULT). Lets the caller map it to EXPORT_DISK_FULL instead
  // of a generic render failure.
  bool disk_full = false;
  // Standby-resume recovery: true when the failure was (or was caused by) a
  // lost D3D device — the failing HRESULT is a device-loss code, or the
  // pipeline's device reports GetDeviceRemovedReason() != S_OK. A device
  // loss is transient (Modern Standby resume, driver reset, TDR): the
  // router retries the whole export ONCE on a fresh device when this is
  // set. The 55-minute-recording incident is this exact class.
  bool device_removed = false;
};

// Phase 10.4 — pure classifier: does this encoder HRESULT mean the
// destination volume ran out of space mid-write? (ERROR_DISK_FULL /
// ERROR_HANDLE_DISK_FULL via HRESULT_FROM_WIN32.) Exposed for unit tests.
bool IsDiskFullHresult(HRESULT hr);

// Standby-resume recovery — pure classifier: does this HRESULT mean the D3D
// device backing the export was lost? (DXGI device removed/reset/hung,
// driver internal error, or Direct2D's recreate-target.) Exposed for unit
// tests.
bool IsDeviceRemovedHresult(HRESULT hr);

// Run the full decode → composite → re-encode pass. Synchronous; returns
// only after the output file is finalized (or a failure removes the partial
// output and leaves NO file at the destination — Phase 10.4). Never throws —
// all Media Foundation / Direct2D failures are reported through
// `RenderResult::ok` + `message`.
RenderResult RenderComposedExport(const RenderRequest& request);

}  // namespace clingfy::capture::export_

#endif  // RUNNER_CAPTURE_EXPORT_EXPORT_PIPELINE_H_
