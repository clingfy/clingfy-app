#include "Capture/Export/gif_export_policy.h"

#include <algorithm>
#include <cctype>

namespace clingfy::capture::export_ {

namespace {

constexpr std::int64_t kHnsPerSecond = 10'000'000;
constexpr std::int64_t kHnsPerCentisecond = 100'000;  // 1/100 s in 100 ns units

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
  const std::int64_t gap = cur_ts_hns - prev_ts_hns;
  if (gap <= 0) {
    return kGifMinDelayCentiseconds;
  }
  // Round to the nearest centisecond.
  const std::int64_t cs = (gap + kHnsPerCentisecond / 2) / kHnsPerCentisecond;
  const std::int64_t floored =
      std::max<std::int64_t>(cs, kGifMinDelayCentiseconds);
  // GIF stores delay in a 16-bit field; clamp to its max so a very long pause
  // can't wrap. 0xFFFF cs ~= 655 s, far beyond any real per-frame gap.
  const std::int64_t capped = std::min<std::int64_t>(floored, 0xFFFF);
  return static_cast<std::uint16_t>(capped);
}

}  // namespace clingfy::capture::export_
