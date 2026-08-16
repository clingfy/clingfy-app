#ifndef RUNNER_AUDIO_ECHOCANCEL_MIC_ECHO_CANCELLER_H_
#define RUNNER_AUDIO_ECHOCANCEL_MIC_ECHO_CANCELLER_H_

#include <cstdint>
#include <vector>

// Speaker-to-mic bleed removal — the Windows port of macOS MicEchoCanceller.
//
// THE PROBLEM. When someone records with speakers rather than headphones, the
// microphone picks up a delayed, attenuated copy of the system audio. Mixing
// mic and system then plays the system twice: once clean and once as a smeared
// echo. It gets worse with mic gain, because gain targets the mic and the bleed
// rides along. Windows summed the two raw tracks with no cancellation stage, so
// every speakers-plus-mic export carried the echo.
//
// EVERYTHING HERE IS PURE. Vectors of mono float32 at 48 kHz in, vectors out —
// no file I/O, no Media Foundation, no COM. That keeps the algorithm testable
// against synthetic signals (which is the only way to test a canceller
// deterministically) and matches the project's DSP-core-stays-host-agnostic
// direction; the decode/encode adapter lives in Capture/Export/mic_cleanup.
//
// SHAPE OF THE ALGORITHM, in the order cancel() runs it:
//   1. Estimate the bleed delay by CONSENSUS across sliding windows. Real bleed
//      is one source delayed, so its correlation peak lands at the same lag in
//      every window where the system is audible; a coincidental correlation
//      (music, headphone cross-talk) is a lone window at a random lag.
//   2. Below a correlation gate, do nothing at all and return the mic
//      untouched. Headphones and silent-system recordings must be bit-exact.
//   3. Build a delay-aligned reference and run a 512-tap NLMS filter to
//      subtract the bleed.
//   4. FREEZE adaptation during near-end voice and on a near-silent reference,
//      so the filter can only ever learn the bleed — never the user's voice.
//   5. Blend by system presence: cleaned in the pauses (where the bleed is
//      exposed and audible), RAW during genuine double-talk (where the bleed is
//      masked by the speech at every gain, and subtracting an estimate would
//      only damage the voice).
//
// The constants below are macOS's, unchanged, and each one is load-bearing —
// see the macOS file for the history behind them (several encode fixes for
// specific audible failures: gutted voice, post-silence bursts, quiet-recording
// gating). `kAlgorithmVersion` exists to key a cache; bump it whenever any
// tunable or the algorithm changes, or stale cleaned audio would be reused.
namespace clingfy::audio::echo {

inline constexpr int kAlgorithmVersion = 6;
inline constexpr double kSampleRate = 48000.0;

inline constexpr int kFilterTaps = 512;         // ~10.7 ms at 48 kHz
inline constexpr float kStepSize = 0.3f;        // NLMS mu, 0 < mu < 2
inline constexpr float kRegularization = 1e-6f;
// Below this windowed-peak |mic<->system| correlation there is nothing to
// cancel (headphones, no system audio, silent mic) and cancel() is a no-op.
inline constexpr float kGateCorrelation = 0.15f;
inline constexpr double kMaxDelaySeconds = 0.30;
// Anything closer to zero than this is not an acoustic round-trip; guards
// against a degenerate lock at ~0 lag.
inline constexpr double kMinDelaySeconds = 0.010;
inline constexpr double kClusterToleranceSeconds = 0.006;
inline constexpr int kMinConsensusWindows = 3;
inline constexpr double kPrerollSeconds = 0.008;
inline constexpr int kDelaySearchDecimation = 8;
inline constexpr int kMinSamples = 4800;  // 0.1 s
inline constexpr double kDetectionWindowSeconds = 0.5;
inline constexpr double kEnvelopeWindowSeconds = 0.02;
inline constexpr float kReferencePresentFloor = 0.003f;
inline constexpr double kSystemHoldSeconds = 0.5;
inline constexpr double kSystemBackfillSeconds = 0.06;
inline constexpr double kBlendFastSeconds = 0.004;
inline constexpr double kBlendSlowSeconds = 0.12;
inline constexpr float kPauseDuckDb = -12.0f;
inline constexpr float kPauseDuckMicToRefRatio = 0.25f;
inline constexpr float kVoiceCorrelationThreshold = 0.5f;
inline constexpr double kVoiceCorrelationWindowSeconds = 0.03;
inline constexpr float kVoiceMicFloor = 0.015f;
inline constexpr float kVoiceMicNoiseFloor = 0.004f;
inline constexpr float kVoiceMicFraction = 0.15f;
inline constexpr double kVoiceSpeakingPercentile = 0.95;

struct EchoCancelResult {
  // The mic to use. When `applied` is false this is the input, copied
  // unchanged — callers can always use it without branching.
  std::vector<float> mic;
  // False when there was no measurable bleed (the common headphones case), or
  // the clip was too short to estimate anything.
  bool applied = false;
  float bleed_correlation = 0.0f;
  double delay_ms = 0.0;
  // Residual bleed change in dB (negative = reduced). Diagnostics only.
  double reduction_db = 0.0;
};

// Remove system-audio bleed from `mic`, using `system` as the far-end
// reference. Both are mono float32 at 48 kHz and are compared over their common
// prefix. Returns the mic unchanged when there is nothing to cancel.
EchoCancelResult CancelEcho(const std::vector<float>& mic,
                            const std::vector<float>& system);

// --- The stages, exposed so each can be tested on its own ------------------

// Windowed RMS envelope over kEnvelopeWindowSeconds.
std::vector<float> MovingRms(const std::vector<float>& x);

// Linear-interpolated q-quantile (0..1). 0 for an empty input.
float Percentile(std::vector<float> values, double q);

// Block-average decimation followed by mean removal.
std::vector<float> DecimateZeroMean(const std::vector<float>& x, int factor);

// Bleed delay in 48 kHz samples plus its correlation, by cross-window
// consensus. Returns {0, 0} when no lag reaches the required agreement — which
// cancel() treats as "no bleed".
struct DelayEstimate {
  int samples = 0;
  float correlation = 0.0f;
};
DelayEstimate EstimateDelay(const std::vector<float>& mic,
                            const std::vector<float>& system);

// system[i + preroll - delay], zero-filled outside range. The preroll gives the
// causal filter a few ms of slack for anti-causal reverb and sub-sample
// alignment error. This is the NLMS reference.
std::vector<float> AlignedReference(const std::vector<float>& system,
                                    int delay_samples, size_t n);

// system[i - delay], no preroll. A pure-bleed window is a near-perfect scaled
// copy of THIS, so it correlates ~1 with the mic whatever the system's
// spectrum. Detection only — using the preroll-offset reference here would let
// loud bleed read as voice on noise-like audio.
std::vector<float> BleedAlignedReference(const std::vector<float>& system,
                                         int delay_samples, size_t n);

// Per-sample near-end-voice mask. A window is voice when the mic's correlation
// with the bleed-aligned reference is BELOW kVoiceCorrelationThreshold (the mic
// is dominated by something uncorrelated with the system) and the mic carries
// real energy. Pass BleedAlignedReference, not AlignedReference.
std::vector<bool> NearEndVoiceMask(const std::vector<float>& mic,
                                   const std::vector<float>& reference,
                                   const std::vector<float>& mic_env,
                                   float voice_floor);

// Normalized LMS returning the error signal (the bleed-subtracted mic). The
// filter output is produced everywhere; only ADAPTATION pauses where
// `freeze[i]` is set, so the filter can never learn the near-end voice.
std::vector<float> NlmsDoubleTalk(const std::vector<float>& desired,
                                  const std::vector<float>& reference,
                                  const std::vector<bool>& freeze);

// Emit cleaned where the system is present and there is no near-end voice, raw
// otherwise, crossfaded — fast into cleaned so bleed cannot leak at system
// onsets, slow back to raw so the blend does not chatter at tails.
std::vector<float> SystemPresenceBlend(const std::vector<float>& raw,
                                       const std::vector<float>& cleaned,
                                       const std::vector<float>& mic_env,
                                       const std::vector<float>& ref_env,
                                       const std::vector<bool>& voice);

}  // namespace clingfy::audio::echo

#endif  // RUNNER_AUDIO_ECHOCANCEL_MIC_ECHO_CANCELLER_H_
