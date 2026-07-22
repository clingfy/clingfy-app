#include "Audio/VoiceCleanup/rnnoise_denoiser.h"

extern "C" {
#include "rnnoise.h"
}

namespace clingfy::audio::voice_cleanup {

RnnoiseDenoiser::RnnoiseDenoiser() : state_(rnnoise_create(nullptr)) {}

RnnoiseDenoiser::~RnnoiseDenoiser() {
  if (state_ != nullptr) {
    rnnoise_destroy(state_);
  }
}

int RnnoiseDenoiser::FrameSize() { return rnnoise_get_frame_size(); }

float RnnoiseDenoiser::ProcessFrame(const float* in, float* out) {
  if (state_ == nullptr) {
    return 0.0f;
  }
  // rnnoise_process_frame takes `out` first, then a const `in`.
  return rnnoise_process_frame(state_, out, in);
}

}  // namespace clingfy::audio::voice_cleanup
