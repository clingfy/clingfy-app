// Phase 6 Slice 5B — pure animated-GIF sampling / timing / sizing policy.
//
// macOS has a native GIF path (#319, #326) whose policy,
// `macos/Runner/Capture/Export/GifExportPolicy.swift`, was ported value for
// value from this file. It then added the size presets / long-edge cap and the
// drift-free delay accumulator; both are ported back here, so the two match.
// Kept pure (no Win32 / WIC) so it can be pinned by
// `gif_export_policy_test.cpp` without a GPU, mirroring how `export_geometry` /
// `export_audio` / `export_format` split their pure logic from the encoder.
//
// Why a frame cap: a GIF carries a full color table per frame and LZW-packs
// raw indices, so a 30/60 fps screen recording balloons in size. The pipeline
// decimates decoded frames down toward `kGifTargetFps` (a 30 fps source keeps
// every other frame -> 15 fps; 60 fps keeps every fourth), and each kept frame
// is stamped with the real time gap to the next kept frame (GIF delay units are
// centiseconds) so playback still tracks wall-clock time.

#ifndef RUNNER_CAPTURE_EXPORT_GIF_EXPORT_POLICY_H_
#define RUNNER_CAPTURE_EXPORT_GIF_EXPORT_POLICY_H_

#include <cstdint>
#include <string>
#include <vector>

#include "Capture/Export/clip_playback_planner.h"
#include "Capture/Export/export_geometry.h"

namespace clingfy::capture::export_ {

// Target output frame rate for GIF. 15 fps is the smoothness/size sweet spot
// for screen recordings and divides cleanly from common 30/60 fps sources.
inline constexpr std::uint32_t kGifTargetFps = 15;

// GIF delay is expressed in centiseconds (1/100 s). Most viewers silently clamp
// a sub-2cs delay up to 10cs, so never emit one below this floor.
inline constexpr std::uint16_t kGifMinDelayCentiseconds = 2;

// Delay stamped on the final frame, which has no "next frame" to measure a gap
// against. round(100 / 15) = 7cs. Every other frame's delay comes from
// `GifDelayAccumulator`, which averages 6.667cs at 15 fps.
inline constexpr std::uint16_t kGifDefaultDelayCentiseconds = 7;

// GIF size presets -> long-edge cap (px). The wire values ("small" / "medium" /
// "large") mirror the Flutter `GifSizePreset` enum and its `longEdgePx`; keep
// Dart, Swift and this file in sync. The frame rate stays `kGifTargetFps` for
// every preset: dimensions are the only file-size lever.
inline constexpr double kGifSmallMaxLongEdge = 480.0;
inline constexpr double kGifMediumMaxLongEdge = 720.0;
inline constexpr double kGifLargeMaxLongEdge = 1080.0;
// An unknown, empty or missing preset (older Flutter payloads) caps at
// `large`, as macOS does.
inline constexpr double kGifDefaultMaxLongEdge = kGifLargeMaxLongEdge;

// HNS (100 ns) between kept frames at the target rate. 10'000'000 / fps.
std::int64_t GifFrameIntervalHns();

// True when `path` names a .gif output (case-insensitive suffix). The pipeline
// keys the GIF encoder fork off the resolved destination extension.
bool IsGifDestination(const std::string& path);

// Decimation uses a running emit TARGET on an ideal grid rather than tracking
// the last kept frame's actual timestamp. The pipeline seeds the target with
// `kGifEmitTargetStart` (so the very first decoded frame is always kept), tests
// each frame with `ShouldKeepGifFrame`, and on a keep advances the target with
// `AdvanceGifEmitTarget`. Anchoring the grid (vs. following the actual
// timestamp) keeps the output at ~kGifTargetFps even when real decoder
// timestamps jitter around the slot boundary — a last-kept-timestamp gate
// degrades a jittery clean-divisor (30/60 fps) source below the target rate.
inline constexpr std::int64_t kGifEmitTargetStart = INT64_MIN;

// Keep `frame_ts_hns` once it has reached the running emit target.
bool ShouldKeepGifFrame(std::int64_t frame_ts_hns,
                        std::int64_t emit_target_hns);

// Advance the emit target one interval along the ideal grid after keeping a
// frame. Snaps forward (kept_frame_ts + interval) when the grid would otherwise
// lag behind the kept frame — i.e. on the first frame (target ==
// kGifEmitTargetStart) or after a long source gap.
std::int64_t AdvanceGifEmitTarget(std::int64_t emit_target_hns,
                                  std::int64_t kept_frame_ts_hns);

// Stateless per-frame GIF delay (centiseconds) for the gap between two kept
// frames' timestamps. Rounded to the nearest centisecond and clamped to
// [`kGifMinDelayCentiseconds`, 0xFFFF]. A non-positive gap clamps to the floor.
// Rounding each gap on its own stamps a uniform 15 fps stream ~5% slow (every
// ~6.667cs gap rounds to 7cs), so the encoder uses `GifDelayAccumulator`.
std::uint16_t GifDelayCentiseconds(std::int64_t prev_ts_hns,
                                   std::int64_t cur_ts_hns);

// Drift-free per-frame delay generator, line for line with Swift's
// `GifExportPolicy.DelayAccumulator`. Fed the real HNS gap between each pair of
// consecutive kept frames, it carries the fractional-centisecond residual so
// the stamped cumulative time tracks wall-clock. For a uniform 15 fps stream
// the delays alternate (7, 6, 7, 7, 6, ...) and average 6.667cs.
//
// The floor / ceiling clamps still apply per frame; when the floor lifts a
// tiny gap it advances the stamped clock (acting as a rate limiter), exactly as
// the stateless version would.
class GifDelayAccumulator {
 public:
  // Delay (centiseconds) to stamp on the frame that opens `gap_hns`.
  std::uint16_t Next(std::int64_t gap_hns);

 private:
  std::int64_t true_elapsed_hns_ = 0;
  std::int64_t stamped_centiseconds_ = 0;
};

// Resolve a GIF size-preset wire value to its long-edge cap. Unknown or empty
// falls back to `kGifDefaultMaxLongEdge`. Case-insensitive and whitespace-
// trimmed, mirroring Dart's `gifSizePresetFromWire` and Swift's
// `maxLongEdge(forSizePreset:)`.
double GifMaxLongEdgeForSizePreset(const std::string& raw);

// The canvas downscaled so its long edge is at most `max_long_edge`, aspect
// kept, rounded to whole pixels (min 1). Returns the canvas unchanged when it
// already fits, or when the cap is not positive. Swift's `renderSize`.
SizeF GifRenderSize(SizeF canvas, double max_long_edge = kGifDefaultMaxLongEdge);

// The size a GIF export's frames are ACTUALLY encoded at: `GifRenderSize`
// rounded to even dimensions (min 2). Swift's `intermediateRenderSize`.
//
// Two callers must get the same answer, which is why it lives here once: the
// pipeline encodes at it, and `ResolveExportPixelSize` reports it to Flutter,
// which lays caption bitmaps out against it. If they disagree, burned-in
// captions are composited at the wrong scale.
PixelSize GifIntermediateRenderSize(
    SizeF canvas, double max_long_edge = kGifDefaultMaxLongEdge);

// ---- Length cap (value for value with GifExportPolicy.swift) ----------------

// The longest GIF an export may produce, in ms of EXPORTED duration (after
// cuts, trims and reordering). A GIF stores every frame as a full indexed
// image, so length is what makes one huge and slow to encode. Over it the
// export is refused, never silently cut short. Mirrored by Dart's
// `kGifMaxExportDurationMs` and Swift's `maxExportedDurationMs`; keep all
// three equal.
inline constexpr std::int64_t kGifMaxExportedDurationMs = 60'000;

// How far past the cap the native backstop lets an export through. The dialog
// measures the player's duration and native the file's, which can disagree by
// a few ms; the backstop must never refuse what the dialog allowed. One frame
// at 15 fps, rounded up.
inline constexpr std::int64_t kGifDurationCapSlackMs = 100;

// The exported duration of a GIF built from `clips` over a source of
// `asset_duration_ms`. No clips means the whole recording, as the exporter
// treats it. Each range is clamped to [0, asset] first: nothing upstream
// limits `source_out_ms` to the file, and a stale range past the end must not
// count time the GIF will not contain.
std::int64_t GifExportedDurationMs(
    const std::vector<clip_planner::ClipKeptRange>& clips,
    std::int64_t asset_duration_ms);

// Whether the native backstop refuses an export of `exported_ms`: strictly
// more than the cap plus the slack.
bool GifExceedsDurationCap(std::int64_t exported_ms);

}  // namespace clingfy::capture::export_

#endif  // RUNNER_CAPTURE_EXPORT_GIF_EXPORT_POLICY_H_
