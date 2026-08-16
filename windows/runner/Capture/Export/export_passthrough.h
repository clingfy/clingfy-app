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
#include <vector>

#include "Capture/Export/clip_playback_planner.h"
#include "Capture/Background/canvas_preset_renderer.h"
#include "Capture/Export/color_grade.h"

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
  // Bundled background image path (empty = colour background). Like
  // background_color this does NOT force composition on its own: with an
  // identity transform the video covers the canvas and the background is not
  // visible, so a byte-copy is still correct.
  std::wstring background_image_path;
  // Procedural preset (data, not pixels). Rendered by the same Direct2D
  // renderer the preview uses, so the exported background is identical to the
  // one the editor showed. Empty preset_id = no preset.
  background::CanvasPresetSpec background_preset;
  bool has_background_preset = false;

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

  // Phase 4 voice cleanup. The `voiceCleanup.{enabled,mode}` from the
  // `exportVideo` map. When enabled (and the recording has a decodable
  // separated mic sidecar), the export runs the mic through the RNNoise engine
  // (Capture/Export/mic_cleanup.h) before the audio pump; `mode` picks the
  // wet/dry strength ("light" = gentler, else full). Off leaves the mic
  // untouched -- identical to the pre-feature export.
  bool voice_cleanup_enabled = false;
  std::string voice_cleanup_mode;

  // Speaker-to-mic bleed removal. Only meaningful when BOTH separated sidecars
  // exist — with no system track there is no reference to cancel against.
  //
  // Routed through the per-call export args rather than a native preference,
  // for the same reason voiceCleanup is: Windows has no preferences store, and
  // the export must not depend on one existing.
  //
  // Off leaves the mic exactly as recorded. So does ON, when the recording has
  // no measurable bleed — the headphone case, which is most recordings.
  bool mic_echo_cancellation_enabled = false;

  // Slice 5A: requested output bitrate preset ("auto"/"low"/"medium"/"high").
  // The `format` field above selects the container (.mp4 vs .mov).
  std::string bitrate;

  // Requested video codec ("h264" / "hevc"). Dart has always sent this and
  // Windows always dropped it on the floor, so a user picking HEVC — which is
  // the Dart DEFAULT — silently received H.264. Empty/unknown → H.264.
  //
  // Requesting HEVC does not guarantee getting it: the encoder MFT is
  // hardware- and SKU-dependent, so `ResolveVideoCodec` probes and degrades.
  std::string codec;

  // Phase 8.2 cursor rendering. `show_cursor` (Dart default true) draws the
  // recorded cursor sidecar into the export; `cursor_size` (0.5..3.0, default
  // 1.5) scales it. When the recording has a `capture/cursor.jsonl` and
  // show_cursor is on, the export takes the composition path (a byte-copy cannot
  // draw the cursor) — the recording itself stays cursorless.
  bool show_cursor = true;
  double cursor_size = 1.5;

  // Phase 8.3 smart zoom. `zoom_effect_enabled` (Dart default true) auto-zooms
  // the export from the recorded clicks + cursor path; `zoom_factor` (1.0..3.0,
  // default 1.5) is the magnification. Like the cursor, an active zoom needs the
  // sidecar and forces the composition path. Manual zoom segments are not
  // consumed yet (deferred — Windows getZoomSegments is a stub).
  bool zoom_effect_enabled = true;
  double zoom_factor = 1.5;

  // Phase 9.4 camera bubble args from the `exportVideo` map (the Dart
  // `CameraCompositionState.toMap()` keys). These describe HOW to draw the
  // camera; WHETHER to draw it also depends on the project assets + the
  // camera.meta.json `previewBurnedIn` flag, resolved in ExportPassthroughCopy.
  //   camera_visible        — `cameraVisible`; user toggle. False → no camera.
  //   camera_has_center     — true when `cameraNormalizedCenter` is a {x,y} map.
  //   camera_center_x/y     — that manual normalized center (0..1).
  //   camera_layout_preset  — `cameraLayoutPreset` enum name (preset corner).
  //   camera_size_factor    — `cameraSizeFactor` (0.08..0.45 of the short side).
  //   camera_shape          — `cameraShape` enum name.
  //   camera_corner_radius  — `cameraCornerRadius` (0..0.5 fraction).
  //   camera_content_mode   — `cameraContentMode` ("fill" / "fit").
  bool camera_visible = false;
  bool camera_has_center = false;
  double camera_center_x = 0.0;
  double camera_center_y = 0.0;
  std::string camera_layout_preset;
  double camera_size_factor = 0.18;
  std::string camera_shape;
  double camera_corner_radius = 0.0;
  std::string camera_content_mode;
  // Phase 9.5 styling (Dart cameraMirror / cameraOpacity / cameraBorderWidth /
  // cameraBorderColorArgb [nullable] / cameraShadowPreset). Soft-failed at the
  // renderer; an absent/invalid value just means that style is off.
  bool camera_mirror = false;
  double camera_opacity = 1.0;
  double camera_border_width = 0.0;
  std::optional<std::int64_t> camera_border_color_argb;
  int camera_shadow_preset = 0;
  // Phase 9.7 chroma key + intro/outro animation (Dart cameraChromaKeyEnabled /
  // cameraChromaKeyStrength / cameraChromaKeyColorArgb [nullable] +
  // cameraIntro/OutroPreset / cameraIntro/OutroDurationMs). Soft-failed
  // downstream; an absent/invalid value just means that effect is off.
  bool camera_chroma_enabled = false;
  double camera_chroma_strength = 0.4;
  std::optional<std::int64_t> camera_chroma_color_argb;
  std::string camera_intro_preset;
  std::string camera_outro_preset;
  int camera_intro_duration_ms = 0;
  int camera_outro_duration_ms = 0;
  std::string camera_zoom_behavior;
  double camera_zoom_scale_multiplier = 0.0;
  std::string camera_zoom_emphasis_preset;
  double camera_zoom_emphasis_strength = 0.0;

  // Editing port (color): the `colorGrade` map from the `exportVideo` args,
  // parsed by Bridge/Routers/color_grade_args. A non-identity grade forces
  // the composition path (a byte-copy cannot bake color) and is threaded
  // through to the pipeline's per-frame color pass.
  color::ColorGrade color_grade;

  // Editing port (clips): the kept ranges parsed from the `clips` export arg
  // (enabled clips with a positive source window, in timeline order — the Dart
  // `Clip.toMap()` list filtered exactly like the macOS
  // `ClipKeptRange.fromFlutter`). A real edit — cut / trim / delete-middle /
  // reorder / overlap — forces the composition path and is baked by the
  // pipeline; silently byte-copying the uncut source would ship content the
  // user cut out. A list that coalesces back to one full-range window (a split
  // with nothing deleted, starting at source 0) is NOT an edit and stays
  // exportable. Known limitation: a pure tail-trim (one range starting at 0) is
  // indistinguishable from the full range without the asset duration and is
  // allowed through.
  std::vector<clip_planner::ClipKeptRange> clip_ranges;
};

// Editing port (clips) — how the export should treat a clip edit.
enum class ClipEditKind {
  // Empty, or a single window covering the asset from source 0: no real edit.
  // Stays eligible for the byte-copy fast-path (a pure tail-trim also lands
  // here — indistinguishable from the full range without the asset duration).
  kPassthrough,
  // A real edit (cut / trim / delete-middle / reorder / overlap): bake it via
  // the composition path. Cuts drop frames + re-stamp; reorder/overlap read
  // each source window in timeline order (per-range backward seeks, 3b-2) with
  // a sample-accurate audio stitch.
  kBake,
};

// Pure classifier for the `clips` export arg: coalesces source-adjacent ranges,
// then decides passthrough vs. bake. Any real edit — cut, trim, delete-middle,
// reorder, or overlap — bakes via the composition path (3b-2 handles reorder
// and overlap with per-range source-window reads and a decoupled audio stitch).
// Exposed for unit tests.
ClipEditKind ClassifyClipEdit(
    const std::vector<clip_planner::ClipKeptRange>& ranges);

// Phase 9.4 — pure decision: should the export composite the camera bubble?
// True only when the user wants it (`camera_visible`), the project actually has
// the camera assets (raw.mov + camera.meta.json present-together), the metadata
// parsed, the live preview was NOT burned into screen.mov (`preview_burned_in`
// false — else drawing again would double the camera), and at least one camera
// frame was recorded (`frames_written` > 0). Exposed for unit tests.
bool ShouldCompositeCamera(bool camera_visible, bool has_camera_assets,
                           bool meta_parsed, bool preview_burned_in,
                           std::uint64_t frames_written);

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
  // Phase 10.4: the destination volume cannot hold the export — either the
  // preflight estimate did not fit (required/available byte counts populated
  // on the result) or a mid-write failure carried a disk-full HRESULT /
  // errno. Maps to EXPORT_DISK_FULL with the macOS-shaped details payload.
  kDiskFull,
  // Slice 5A: the export was cancelled by the user mid-flight. Maps to
  // EXPORT_CANCELLED (Phase 10.4 — previously EXPORT_ERROR with a
  // "cancelled" message) so the Dart side classifies a clean user cancel by
  // stable code rather than by message sniffing.
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
  // Phase 10.4: populated when error == kDiskFull. `disk_required_bytes` is
  // the preflight estimate (source size + headroom); -1 when the failure was
  // classified mid-write (no estimate exists, the router then falls back to
  // the self-contained message). `disk_available_bytes` is the destination
  // volume's free space at check time (-1 unknown). `disk_checked_path` is
  // the UTF-8 destination directory whose volume was checked.
  std::int64_t disk_required_bytes = -1;
  std::int64_t disk_available_bytes = -1;
  std::string disk_checked_path;
  // Standby-resume recovery: true when error == kRenderFailed and the
  // pipeline classified the failure as a lost D3D device (Modern Standby
  // resume, driver reset, TDR — see RenderResult::device_removed). The
  // router retries the whole export once when this is set; a fresh
  // ExportPassthroughCopy call builds a fresh device.
  bool device_removed = false;
  // The destination the FAILED render attempt wrote to (UTF-8; empty on
  // success and on pre-destination failures). The retry path uses it to
  // verify the partial output is actually gone before re-resolving the
  // destination — if a leftover survived both best-effort removals (a
  // transient AV/indexer lock), a blind retry would collision-avoid to
  // "name (1).ext" and report success while a corrupt file keeps the name
  // the user chose.
  std::string resolved_destination_path;
};

// ---- Phase 10.4 disk-full preflight (pure, unit-testable) -------------------

// Headroom added on top of the source size when estimating the bytes an
// export needs at the destination. The passthrough copy writes exactly the
// source bytes (64 MiB covers filesystem slack); the composition path
// re-encodes at an output size unknown up front, so it reserves more.
inline constexpr std::int64_t kPassthroughDiskHeadroomBytes =
    64ll * 1024 * 1024;
inline constexpr std::int64_t kCompositionDiskHeadroomBytes =
    256ll * 1024 * 1024;

// Required-bytes estimate for an export: source file size plus the headroom
// for the chosen path. A negative `source_size_bytes` (size probe failed)
// returns -1, which disables the preflight (soft-fail — never block an
// export on a failed probe).
std::int64_t EstimateRequiredExportBytes(std::int64_t source_size_bytes,
                                         bool composition);

// Pure decision: does the destination volume have room for the export?
// True (fits / don't block) when `required_bytes` <= 0 (unknown estimate) or
// `available_bytes` < 0 (free-space query failed) — the soft-fail idiom —
// otherwise a plain `available >= required` comparison.
bool ExportDiskPreflightFits(std::int64_t required_bytes,
                             std::int64_t available_bytes);

// Standby-resume recovery — pure decision: retry a failed export attempt?
// True only for the FIRST attempt (`attempts_so_far == 1`) whose outcome is
// kRenderFailed carrying the device-removed classification, and never after
// a cancel request (a cancel can land in the gap between attempts). Strictly
// gating on kRenderFailed means kCancelled / kDiskFull / kInputMissing /
// kNoDestination / kCopyFailed never retry. Each ExportPassthroughCopy call
// builds a fresh D3D device / D2D stack / readers / encoder, so the retry
// IS the pipeline recreation — no extra teardown API exists or is needed.
// Exposed for unit tests.
bool ShouldRetryExportAfterDeviceRemoved(const PassthroughResult& outcome,
                                         int attempts_so_far,
                                         bool cancel_requested);

// Human-readable decimal byte count ("67.1 MB" / "1.5 GB") — the Windows
// analogue of the macOS ByteCountFormatter strings embedded in the
// EXPORT_DISK_FULL details payload (GB/MB units, decimal, unit included).
// Negative values render as "0.0 MB".
std::string FormatBytesForUser(std::int64_t bytes);

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
