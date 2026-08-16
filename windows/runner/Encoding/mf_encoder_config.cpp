#include "Encoding/mf_encoder_config.h"

namespace clingfy::encoding {

std::optional<std::string> EncoderConfig::Validate() const {
  if (output_path.empty()) {
    return std::string("EncoderConfig.output_path must be a non-empty path.");
  }
  if (width == 0 || height == 0) {
    return std::string(
        "EncoderConfig.width and height must be > 0 (resolved from the "
        "selected display).");
  }
  // H.264 requires even dimensions on most encoder MFTs — odd values
  // surface as E_INVALIDARG when the encoder's frame size attribute is
  // pushed through. Round the source size up at the engine layer instead
  // of guessing here; we just refuse the bad input.
  if ((width & 1) != 0 || (height & 1) != 0) {
    return std::string(
        "EncoderConfig.width and height must both be even (H.264 "
        "requirement).");
  }
  if (fps == 0 || fps > 240) {
    return std::string(
        "EncoderConfig.fps must be in [1, 240]. Phase 3C clamps the Dart "
        "frameRate request before it reaches the encoder.");
  }
  if (avg_bitrate_bps == 0) {
    return std::string(
        "EncoderConfig.avg_bitrate_bps must be > 0; the Sink Writer "
        "rejects a zero target bitrate.");
  }
  // 0 is legal — it means "let the encoder choose", the pre-#294 behaviour.
  // The upper bound only catches a plainly wrong value (a caller passing
  // milliseconds or microseconds instead of frames); an over-long GOP is a
  // seek-latency problem, not a correctness one, so the ceiling is generous.
  if (keyframe_interval_frames > 3600) {
    return std::string(
        "EncoderConfig.keyframe_interval_frames must be <= 3600 (frames, not "
        "milliseconds); 0 leaves the choice to the encoder.");
  }
  return std::nullopt;
}

std::uint32_t ResolveKeyframeIntervalFrames(std::uint32_t fps) {
  if (fps == 0) {
    return 0;  // malformed config — leave the GOP to the encoder
  }
  return (fps < 30 ? 30u : fps) * 2u;
}

std::optional<std::string> AudioEncoderConfig::Validate() const {
  // The AAC MFT only accepts a tight set of sample rates / channel
  // counts. We pin to the values the WASAPI mixer produces — anything
  // else means a misconfiguration upstream.
  if (sample_rate_hz != 48'000 && sample_rate_hz != 44'100) {
    return std::string(
        "AudioEncoderConfig.sample_rate_hz must be 48000 or 44100; the AAC "
        "MFT rejects other rates.");
  }
  if (channel_count != 1 && channel_count != 2) {
    return std::string(
        "AudioEncoderConfig.channel_count must be 1 (mono) or 2 (stereo).");
  }
  if (bits_per_sample != 16) {
    return std::string(
        "AudioEncoderConfig.bits_per_sample must be 16 — the AAC MFT input "
        "type is PCM int16.");
  }
  if (avg_bitrate_bps == 0) {
    return std::string(
        "AudioEncoderConfig.avg_bitrate_bps must be > 0.");
  }
  return std::nullopt;
}

}  // namespace clingfy::encoding
