// Phase 6 Slice 5B — pure animated-GIF sampling / timing policy.
//
// macOS has NO real GIF encoder (its "gif" format silently downgrades to a
// video container), so there is no parity behavior to mirror — these are
// fresh, deliberate Windows defaults, kept pure (no Win32 / WIC) so they can
// be pinned by `gif_export_policy_test.cpp` without a GPU, mirroring how
// `export_geometry` / `export_audio` / `export_format` split their pure logic
// from the encoder.
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

namespace clingfy::capture::export_ {

// Target output frame rate for GIF. 15 fps is the smoothness/size sweet spot
// for screen recordings and divides cleanly from common 30/60 fps sources.
inline constexpr std::uint32_t kGifTargetFps = 15;

// GIF delay is expressed in centiseconds (1/100 s). Most viewers silently clamp
// a sub-2cs delay up to 10cs, so never emit one below this floor.
inline constexpr std::uint16_t kGifMinDelayCentiseconds = 2;

// Delay stamped on the final frame, which has no "next frame" to measure a gap
// against. round(100 / 15) = 7cs (~14.3 fps), matching the steady-state cadence.
inline constexpr std::uint16_t kGifDefaultDelayCentiseconds = 7;

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

// Per-frame GIF delay (centiseconds) for the gap between two kept frames'
// timestamps. Rounded to the nearest centisecond and clamped up to
// `kGifMinDelayCentiseconds`. A non-positive gap clamps to the floor too.
std::uint16_t GifDelayCentiseconds(std::int64_t prev_ts_hns,
                                   std::int64_t cur_ts_hns);

}  // namespace clingfy::capture::export_

#endif  // RUNNER_CAPTURE_EXPORT_GIF_EXPORT_POLICY_H_
