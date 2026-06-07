#include "Capture/Camera/camera_format.h"

#include <algorithm>

namespace clingfy::capture {

namespace {

constexpr std::uint32_t kMaxWidth = 1920;
constexpr std::uint32_t kMaxHeight = 1080;
constexpr std::uint32_t kFallbackWidth = 1280;
constexpr std::uint32_t kFallbackHeight = 720;
constexpr std::uint32_t kPreferredFps = 30;

// Clamp DOWN to even (H.264 needs even dimensions), with a floor of 2 so a
// 1px input can never produce a zero dimension.
std::uint32_t ClampEven(std::uint32_t value) {
  if (value < 2) {
    return 2;
  }
  return value & ~1u;
}

}  // namespace

CameraDimensions ChooseCameraTargetResolution(std::uint32_t native_width,
                                              std::uint32_t native_height) {
  if (native_width == 0 || native_height == 0) {
    return CameraDimensions{kFallbackWidth, kFallbackHeight};
  }

  // Fits within the 1080p box already → keep native (never upscale).
  if (native_width <= kMaxWidth && native_height <= kMaxHeight) {
    return CameraDimensions{ClampEven(native_width), ClampEven(native_height)};
  }

  // Downscale proportionally so both dimensions fit within the cap. Use the
  // smaller of the two ratios so neither axis exceeds its max.
  const double width_ratio =
      static_cast<double>(kMaxWidth) / static_cast<double>(native_width);
  const double height_ratio =
      static_cast<double>(kMaxHeight) / static_cast<double>(native_height);
  const double scale = std::min(width_ratio, height_ratio);

  std::uint32_t scaled_w =
      static_cast<std::uint32_t>(static_cast<double>(native_width) * scale);
  std::uint32_t scaled_h =
      static_cast<std::uint32_t>(static_cast<double>(native_height) * scale);
  // Guard against rounding pushing a dimension one pixel over the cap.
  scaled_w = std::min(scaled_w, kMaxWidth);
  scaled_h = std::min(scaled_h, kMaxHeight);
  return CameraDimensions{ClampEven(scaled_w), ClampEven(scaled_h)};
}

std::uint32_t ChooseCameraFps(std::uint32_t native_fps_numerator,
                              std::uint32_t native_fps_denominator) {
  if (native_fps_denominator == 0 || native_fps_numerator == 0) {
    return kPreferredFps;
  }
  // Rounded native fps.
  const std::uint32_t native =
      (native_fps_numerator + native_fps_denominator / 2) /
      native_fps_denominator;
  if (native == 0) {
    return kPreferredFps;
  }
  return std::min(native, kPreferredFps);
}

}  // namespace clingfy::capture
