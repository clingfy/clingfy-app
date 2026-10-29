#include "Capture/Export/gif_export_policy.h"

#include <algorithm>
#include <cctype>
#include <cmath>

namespace clingfy::capture::export_ {

namespace {

constexpr std::int64_t kHnsPerSecond = 10'000'000;
constexpr std::int64_t kHnsPerCentisecond = 100'000;  // 1/100 s in 100 ns units
// GIF stores delay in a 16-bit field; clamp to its max so a very long pause
// can't wrap. 0xFFFF cs ~= 655 s, far beyond any real per-frame gap.
constexpr std::int64_t kDelayCeilingCentiseconds = 0xFFFF;

// Round a positive HNS gap to the nearest centisecond. A non-positive gap
// returns 0, which the clamp then lifts to the floor.
std::int64_t RoundToCentiseconds(std::int64_t gap_hns) {
  if (gap_hns <= 0) {
    return 0;
  }
  return (gap_hns + kHnsPerCentisecond / 2) / kHnsPerCentisecond;
}

// Clamp a raw centisecond count into the emit range [floor, 0xFFFF].
std::uint16_t ClampDelayCentiseconds(std::int64_t cs) {
  const std::int64_t floored =
      std::max<std::int64_t>(cs, kGifMinDelayCentiseconds);
  return static_cast<std::uint16_t>(
      std::min<std::int64_t>(floored, kDelayCeilingCentiseconds));
}

std::string TrimmedLowerAscii(const std::string& raw) {
  const auto is_space = [](char c) {
    return std::isspace(static_cast<unsigned char>(c)) != 0;
  };
  std::size_t begin = 0;
  std::size_t end = raw.size();
  while (begin < end && is_space(raw[begin])) {
    ++begin;
  }
  while (end > begin && is_space(raw[end - 1])) {
    --end;
  }
  std::string out = raw.substr(begin, end - begin);
  for (char& c : out) {
    c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  }
  return out;
}

}  // namespace

std::int64_t GifFrameIntervalHns() {
  // kGifTargetFps is a positive constant, so no divide-by-zero guard needed.
  return kHnsPerSecond / static_cast<std::int64_t>(kGifTargetFps);
}

bool IsGifDestination(const std::string& path) {
  static constexpr char kExt[] = ".gif";
  constexpr std::size_t kExtLen = 4;  // strlen(".gif")
  if (path.size() < kExtLen) {
    return false;
  }
  const std::size_t offset = path.size() - kExtLen;
  for (std::size_t i = 0; i < kExtLen; ++i) {
    const char a = static_cast<char>(
        std::tolower(static_cast<unsigned char>(path[offset + i])));
    if (a != kExt[i]) {
      return false;
    }
  }
  return true;
}

bool ShouldKeepGifFrame(std::int64_t frame_ts_hns,
                        std::int64_t emit_target_hns) {
  // kGifEmitTargetStart (INT64_MIN) makes the first frame always pass.
  return frame_ts_hns >= emit_target_hns;
}

std::int64_t AdvanceGifEmitTarget(std::int64_t emit_target_hns,
                                  std::int64_t kept_frame_ts_hns) {
  const std::int64_t interval = GifFrameIntervalHns();
  std::int64_t next = emit_target_hns + interval;
  // Never leave the target behind the frame just kept: from the start sentinel
  // (or after a long gap) snap the grid to one interval past the kept frame.
  if (next <= kept_frame_ts_hns) {
    next = kept_frame_ts_hns + interval;
  }
  return next;
}

std::uint16_t GifDelayCentiseconds(std::int64_t prev_ts_hns,
                                   std::int64_t cur_ts_hns) {
  return ClampDelayCentiseconds(RoundToCentiseconds(cur_ts_hns - prev_ts_hns));
}

std::uint16_t GifDelayAccumulator::Next(std::int64_t gap_hns) {
  if (gap_hns > 0) {
    true_elapsed_hns_ += gap_hns;
  }
  const std::int64_t target_cs =
      (true_elapsed_hns_ + kHnsPerCentisecond / 2) / kHnsPerCentisecond;
  const std::uint16_t delay =
      ClampDelayCentiseconds(target_cs - stamped_centiseconds_);
  stamped_centiseconds_ += delay;
  return delay;
}

double GifMaxLongEdgeForSizePreset(const std::string& raw) {
  const std::string preset = TrimmedLowerAscii(raw);
  if (preset == "small") {
    return kGifSmallMaxLongEdge;
  }
  if (preset == "medium") {
    return kGifMediumMaxLongEdge;
  }
  if (preset == "large") {
    return kGifLargeMaxLongEdge;
  }
  return kGifDefaultMaxLongEdge;
}

SizeF GifRenderSize(SizeF canvas, double max_long_edge) {
  const double long_edge = std::max(canvas.width, canvas.height);
  if (!(max_long_edge > 0.0) || !(long_edge > max_long_edge)) {
    return canvas;
  }
  const double scale = max_long_edge / long_edge;
  // std::round is half-away-from-zero, the same as Swift's `.rounded()`.
  return SizeF{std::max(1.0, std::round(canvas.width * scale)),
               std::max(1.0, std::round(canvas.height * scale))};
}

std::int64_t GifExportedDurationMs(
    const std::vector<clip_planner::ClipKeptRange>& clips,
    std::int64_t asset_duration_ms) {
  if (clips.empty()) {
    return std::max<std::int64_t>(0, asset_duration_ms);
  }
  std::int64_t total = 0;
  for (const auto& range : clips) {
    const std::int64_t in_ms = std::min(
        std::max<std::int64_t>(range.source_in_ms, 0), asset_duration_ms);
    const std::int64_t out_ms = std::min(
        std::max<std::int64_t>(range.source_out_ms, 0), asset_duration_ms);
    total += std::max<std::int64_t>(0, out_ms - in_ms);
  }
  return total;
}

bool GifExceedsDurationCap(std::int64_t exported_ms) {
  return exported_ms > kGifMaxExportedDurationMs + kGifDurationCapSlackMs;
}

PixelSize GifIntermediateRenderSize(SizeF canvas, double max_long_edge) {
  const SizeF capped = GifRenderSize(canvas, max_long_edge);
  const auto even = [](double value) {
    return static_cast<std::uint32_t>(
        std::max(2.0, std::round(value / 2.0) * 2.0));
  };
  return PixelSize{even(capped.width), even(capped.height)};
}

}  // namespace clingfy::capture::export_
