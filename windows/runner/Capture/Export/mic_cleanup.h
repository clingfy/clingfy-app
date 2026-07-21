#ifndef RUNNER_CAPTURE_EXPORT_MIC_CLEANUP_H_
#define RUNNER_CAPTURE_EXPORT_MIC_CLEANUP_H_

#include <functional>
#include <string>

namespace clingfy::capture::export_ {

// Export-side voice cleanup (Phase 4). Decodes the separated mic sidecar at
// `mic_path` to mono 48 kHz, runs every 480-sample (10 ms) frame through the
// RNNoise engine (Audio/VoiceCleanup/RnnoiseDenoiser), and writes the denoised
// signal to `output_path` as a stereo AAC .mp4 -- the mono result duplicated
// to both channels, so the existing stereo mic pump (ReorderAudioPump) opens
// the cleaned file exactly like the raw sidecar.
//
// The macOS analog is EnhancedMicCache / AudioEnhancementPipeline. This is the
// stateless first Windows cut: no on-disk cache, so the cleaned file is a
// per-export temp the caller deletes after the render.
//
// RNNoise runs on the FULL-STRENGTH model output; the VoiceCleanup mode
// (light/balanced) is not yet a wet/dry blend (a later refinement, matching
// macOS's reserved high-quality mode).
//
// Best-effort like the rest of the audio path: returns false on ANY failure
// (empty/unreadable sidecar, engine allocation, writer error, or cancel) and
// the caller degrades to the raw mic. `is_cancelled` (may be empty) aborts the
// decode between samples.
bool ProduceCleanedMic(const std::wstring& mic_path,
                       const std::string& output_path,
                       const std::function<bool()>& is_cancelled);

}  // namespace clingfy::capture::export_

#endif  // RUNNER_CAPTURE_EXPORT_MIC_CLEANUP_H_
