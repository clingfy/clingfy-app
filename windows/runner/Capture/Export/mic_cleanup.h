#ifndef RUNNER_CAPTURE_EXPORT_MIC_CLEANUP_H_
#define RUNNER_CAPTURE_EXPORT_MIC_CLEANUP_H_

#include <functional>
#include <string>

namespace clingfy::capture::export_ {

// The VoiceCleanup mode's wet/dry mix, mirroring macOS
// AudioEnhancementPipeline.VoiceCleanupMode.wetMix: "light" leaves the noise
// ~6 dB down with fewer artifacts (0.5), everything else ("balanced" and the
// reserved "highQuality") is full RNNoise (1.0). Unknown/empty -> 1.0.
float VoiceCleanupWetMix(const std::string& mode);

// Export-side voice cleanup (Phase 4). Decodes the separated mic sidecar at
// `mic_path` to mono 48 kHz, runs it through the RNNoise engine
// (Audio/VoiceCleanup/RnnoiseDenoiser) in 480-sample (10 ms) frames, and writes
// the result to `output_path` as a stereo AAC .mp4 -- the mono result
// duplicated to both channels, so the existing stereo mic pump
// (ReorderAudioPump) opens the cleaned file exactly like the raw sidecar.
//
// `wet_mix` (clamped 0..1) blends the suppressed signal against the original:
// out = wet_mix * denoised + (1 - wet_mix) * original (macOS RNNoiseEngine
// parity). The denoised stream is REALIGNED to the source first -- RNNoise has
// a 2-frame (20 ms) algorithmic latency, so each output frame is written back
// 960 samples and the priming frames are dropped -- otherwise a full-strength
// mix would sit 20 ms late (A/V drift) and a partial mix would comb-filter
// against the un-delayed original.
//
// The macOS analog is EnhancedMicCache / AudioEnhancementPipeline. This is the
// stateless Windows cut: no on-disk cache, so the cleaned file is a per-export
// (or per-preview) temp the caller deletes afterward.
//
// Best-effort like the rest of the audio path: returns false on ANY failure
// (empty/unreadable sidecar, engine allocation, writer error, or cancel) and
// the caller degrades to the raw mic. `is_cancelled` (may be empty) aborts
// between frames.
bool ProduceCleanedMic(const std::wstring& mic_path,
                       const std::string& output_path,
                       const std::function<bool()>& is_cancelled,
                       float wet_mix);

// What the cancellation pass measured. Diagnostics only — the caller logs it
// so an on-device investigation can tell "no bleed found" from "bleed found
// and removed" without guessing from the audio.
struct EchoCancelReport {
  bool applied = false;
  float bleed_correlation = 0.0f;
  double delay_ms = 0.0;
  double reduction_db = 0.0;
};

// Export-side speaker-to-mic bleed removal. Decodes both separated sidecars to
// mono 48 kHz, runs `audio::echo::CancelEcho`, and writes the cleaned mic to
// `output_path` in the same stereo AAC shape ProduceCleanedMic produces, so the
// existing mic pump opens it exactly like the raw sidecar.
//
// Returns FALSE when there was no measurable bleed — the headphone case, and
// the overwhelmingly common one. That is not an error: the caller keeps the
// ORIGINAL mic file, which is both cheaper and avoids a needless AAC
// generation loss on a recording that needed nothing.
//
// Also false on any real failure (unreadable sidecar, writer error, cancel),
// with the same degrade-to-raw-mic outcome.
//
// ORDER MATTERS relative to the other mic passes: cancellation must run BEFORE
// voice cleanup (whose noise suppression would distort the bleed the
// correlation needs to find it) and before the normalize peak scan (which
// would otherwise measure a peak inflated by the echo).
bool ProduceEchoCancelledMic(const std::wstring& mic_path,
                             const std::wstring& system_path,
                             const std::string& output_path,
                             const std::function<bool()>& is_cancelled,
                             EchoCancelReport* report);

}  // namespace clingfy::capture::export_

#endif  // RUNNER_CAPTURE_EXPORT_MIC_CLEANUP_H_
