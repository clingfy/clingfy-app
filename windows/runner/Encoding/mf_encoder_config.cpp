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
  return std::nullopt;
}

}  // namespace clingfy::encoding
