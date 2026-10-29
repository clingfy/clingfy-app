#include "Capture/Export/export_format.h"

#include <algorithm>
#include <cstdint>
#include <string>

namespace clingfy::capture::export_ {

namespace {

constexpr std::uint32_t kMinBitrateBps = 2'000'000;    // 2 Mbps floor
constexpr std::uint32_t kMaxBitrateBps = 100'000'000;  // 100 Mbps ceiling

// Export AAC bitrates, macOS's ladder. 192 kbps matches what macOS has always
// produced, so `standard` means the same thing on both platforms. All must
// stay divisible by 8: the encoder sets MF_MT_AUDIO_AVG_BYTES_PER_SECOND as
// `avg_bitrate_bps / 8` with integer arithmetic, so a remainder is silently
// truncated (mf_sink_writer_encoder.cpp, audio_sidecar_writer.cpp).
constexpr std::uint32_t kAudioBitrateStandardBps = 192'000;
constexpr std::uint32_t kAudioBitrateHighBps = 256'000;
constexpr std::uint32_t kAudioBitrateBestBps = 320'000;

std::string ToLowerAscii(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](unsigned char c) {
                   return static_cast<char>(std::tolower(c));
                 });
  return value;
}

}  // namespace

std::string ResolveExportExtension(const std::string& format) {
  const std::string f = ToLowerAscii(format);
  if (f == "mp4") {
    return ".mp4";
  }
  if (f == "gif") {
    // Slice 5B: real animated GIF (WIC), no longer a .mov fallback.
    return ".gif";
  }
  return ".mov";  // "mov" / "" / unknown
}

bool FormatWasDowngraded(const std::string& /*format*/) {
  // Windows now emits .mov, .mp4, and .gif natively (Slices 5A/5B), so no
  // requested format is silently written in a different container. Kept as a
  // contract point (the passthrough still reports it) but always false now.
  return false;
}

std::uint32_t ResolveAudioBitrateBps(const std::string& quality) {
  const std::string preset = ToLowerAscii(quality);
  if (preset == "best") {
    return kAudioBitrateBestBps;
  }
  if (preset == "high") {
    return kAudioBitrateHighBps;
  }
  // "standard", empty (an older Flutter payload sends no key, and ReadString
  // yields "") and anything unrecognised all take the default.
  return kAudioBitrateStandardBps;
}

std::uint32_t ClampAudioBitrateToEncoder(
    std::uint32_t requested_bps,
    const std::function<bool(std::uint32_t)>& encoder_accepts) {
  for (const std::uint32_t rung : {kAudioBitrateBestBps, kAudioBitrateHighBps}) {
    if (rung <= requested_bps && encoder_accepts && encoder_accepts(rung)) {
      return rung;
    }
  }
  return kAudioBitrateStandardBps;
}

std::uint32_t ResolveVideoBitrateBps(const std::string& bitrate,
                                     std::uint32_t width, std::uint32_t height,
                                     std::uint32_t fps) {
  const std::string preset = ToLowerAscii(bitrate);
  double bits_per_pixel_frame = 0.08;  // "auto" / "medium" baseline
  if (preset == "low") {
    bits_per_pixel_frame = 0.04;
  } else if (preset == "high") {
    bits_per_pixel_frame = 0.15;
  }
  // "medium" / "auto" / unknown all use the baseline.

  const std::uint32_t effective_fps = fps == 0 ? 30u : fps;
  const double raw = static_cast<double>(width) * static_cast<double>(height) *
                     static_cast<double>(effective_fps) * bits_per_pixel_frame;
  const double clamped =
      std::min(static_cast<double>(kMaxBitrateBps),
               std::max(static_cast<double>(kMinBitrateBps), raw));
  return static_cast<std::uint32_t>(clamped);
}

}  // namespace clingfy::capture::export_
