#ifndef RUNNER_AUDIO_VOICE_CLEANUP_RNNOISE_DENOISER_H_
#define RUNNER_AUDIO_VOICE_CLEANUP_RNNOISE_DENOISER_H_

// Opaque RNNoise state, defined in the vendored C engine
// (macos/Runner/Capture/Audio/RNNoise/denoise.c). Forward-declared here so
// this header stays free of the C API surface.
struct DenoiseState;

namespace clingfy::audio::voice_cleanup {

// RAII wrapper over the vendored RNNoise C engine -- the SAME 48 kHz mono
// denoiser the macOS voice-cleanup path uses (#297). This is the Windows seam
// for Phase 4 voice cleanup: the mic-cache / export wiring that feeds the
// separated mic sidecar through it lands in later slices; this unit just owns
// the engine and denoises one frame at a time.
//
// RNNoise operates on fixed-size frames of float PCM in INT16 RANGE
// ([-32768, 32767]), NOT normalized [-1, 1]. Callers scale accordingly.
class RnnoiseDenoiser {
 public:
  // Constructs with the built-in model baked into the engine (rnnoise_data.c);
  // no runtime weights file. Check ok() before use.
  RnnoiseDenoiser();
  ~RnnoiseDenoiser();

  RnnoiseDenoiser(const RnnoiseDenoiser&) = delete;
  RnnoiseDenoiser& operator=(const RnnoiseDenoiser&) = delete;

  // False if the engine failed to allocate (out of memory) -- ProcessFrame is
  // then a no-op returning 0.
  bool ok() const { return state_ != nullptr; }

  // Samples the engine consumes/produces per ProcessFrame call
  // (480 @ 48 kHz = 10 ms). Static so callers can size buffers without an
  // instance.
  static int FrameSize();

  // Denoise exactly FrameSize() mono samples from `in` into `out` (each may
  // point at the same buffer). Returns the voice-activity probability [0, 1]
  // for the frame; 0 when !ok().
  float ProcessFrame(const float* in, float* out);

 private:
  DenoiseState* state_;
};

}  // namespace clingfy::audio::voice_cleanup

#endif  // RUNNER_AUDIO_VOICE_CLEANUP_RNNOISE_DENOISER_H_
