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

}  // namespace clingfy::capture::export_

#endif  // RUNNER_CAPTURE_EXPORT_MIC_CLEANUP_H_
