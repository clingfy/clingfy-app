// Slice 4 of Phase 6 (export) — pure audio gain / volume / normalize math.
//
// A faithful C++ port of the macOS export audio mix (CompositionBuilder
// `AudioMixEngine.makeAudioMix` + LetterboxExporter `resolveAudioMixControls`).
// macOS applies the user's gain and volume as TWO ordered stages, not one
// multiply: the int16 gain tap computes `Int16(clamp(sample * gainLinear))`
// FIRST, then `AVAudioMix.setVolume` attenuates that already-clamped result.
// So the signal path is `volume * clamp_int16(sample * gain)`. We mirror that
// exactly — collapsing to a single multiply would clip differently when a
// loud source is boosted (gain>0) AND attenuated (volume<100) at once.
// Everything here is pure (no Win32 / Direct2D / Media Foundation) so the math
// is pinned by `export_audio_test.cpp` without a GPU or a decode pass — the
// same split Slice 3 used for `export_geometry`.
//
// Parity notes (macos/Runner/Capture/Export/):
//   * Gain is AMPLIFY-ONLY, clamped 0..24 dB; attenuation is volume's job
//     (volume clamped 0..100%). gainLinear = 10^(gainDb/20).
//   * Normalize is PEAK based despite the "loudness" name: scale so the
//     measured source peak lands at targetLoudnessDbfs (clamped -24..-6),
//     COMPOSED with the user gain/volume, net clamped to <= +24 dB. macOS
//     folds the normalize result into a SINGLE non-unity factor (gain-only or
//     volume-only), so we carry it in the gain stage with volume = 1.0.
//   * Per int16 sample, each stage: multiply, hard-clamp to [-32768, 32767],
//     truncate toward zero (matches Swift `Int16(clipped)`, which truncates).

#ifndef RUNNER_CAPTURE_EXPORT_EXPORT_AUDIO_H_
#define RUNNER_CAPTURE_EXPORT_EXPORT_AUDIO_H_

#include <cstddef>
#include <cstdint>
#include <deque>
#include <vector>

namespace clingfy::capture::export_ {

// The two ordered per-sample scale factors. `gain` (>= 1, amplify) is applied
// first and hard-clamped to int16 before `volume` (<= 1, attenuate) scales the
// clamped result — mirroring the macOS gain-tap-then-setVolume path. For
// normalize, the whole resolved scale is folded into `gain` with `volume`=1.0.
struct AudioGainStages {
  double gain = 1.0;
  double volume = 1.0;
};

// True when the export must run the re-encode path to honor an audio request.
// The identity defaults (gain 0 dB, volume 100%, normalize off) return false
// so an untouched export stays on the byte-for-byte copy fast-path. Because
// gain only amplifies (>0) and volume only attenuates (<100) after clamping,
// those directions are the only triggers; a tiny epsilon absorbs a benign
// codec round-trip so 99.9999999% does not needlessly force a re-encode.
bool RequiresAudioProcessing(double gain_db, double volume_percent,
                             bool normalize);

// Linear peak of an interleaved int16 buffer in [0, 1]: max |sample| / 32767,
// with INT16_MIN (-32768) mapped to 1.0 (matches macOS AudioLevelEstimator).
// Returns 0.0 for an empty buffer. Callers max() this across every buffer to
// get the whole-track peak the normalize step needs.
double Int16PeakLinear(const std::int16_t* samples, std::size_t count);

// Resolve the gain/volume/normalize request into the two ordered stages.
//   non-normalize: {10^(clamp(gain,0,24)/20), clamp(vol,0,100)/100}
//   normalize: {clamp(userLinear * 10^(clamp(target,-24,-6)/20) /
//               source_peak_linear, 0, 10^(24/20)), 1.0}  — peak<=1e-6 falls
//               back to the plain user stages (no normalize).
// `source_peak_linear` is ignored unless `normalize` is true.
AudioGainStages ResolveAudioGainStages(double gain_db, double volume_percent,
                                       bool normalize,
                                       double target_loudness_dbfs,
                                       double source_peak_linear);

// Apply the two stages in place to interleaved int16 PCM. Each stage does
// out = clamp(value * factor, [-32768, 32767]) truncated toward zero — gain
// first, then volume — and is skipped when its factor is ~1.0. Mirrors the
// macOS gain tap (`Int16(clamp(s*gain))`) followed by `setVolume`.
void ApplyAudioGain(std::int16_t* samples, std::size_t count,
                    const AudioGainStages& stages);

// ---- Audio separation (docs/decisions/windows-audio-separation.md D8) -----

// Per-track stages for a SEPARATED recording (mic.m4a + system.m4a
// sidecars). A faithful port of macOS `resolveSeparatedAudioControls`
// (LetterboxExporter.swift): gain and normalize target the MIC ONLY; the
// master volume attenuates both tracks; system audio is otherwise unity.
//
// The macOS split maps 1:1 onto the ordered AudioGainStages semantics:
// macOS bakes the >1 part of combinedMicLinear into the mic file with an
// int16-truncating gain tap (micGainDb) and applies the <=1 part as the
// AVAudioMix track volume (micVolumeComponent x masterLinear). Here the
// same split is {gain: max(1, combined), volume: min(1, combined) x
// master} — ApplyAudioGain's amplify-clamp-then-attenuate order IS the
// bake-then-volume order.
struct SeparatedAudioStages {
  AudioGainStages mic;     // combined gain*normalize split + master volume
  AudioGainStages system;  // master volume only
};

// Resolve the separated per-track stages.
//   combined = 10^(clamp(gain_db,0,24)/20)
//   normalize (when `normalize` && mic_peak_linear > ~1e-6):
//     combined *= 10^(clamp(target,-24,-6)/20) / mic_peak_linear
//   combined clamped to <= 10^(24/20)  (the TOTAL mic boost cap, macOS
//     parity — gain and normalize never stack past +24 dB)
//   mic    = {max(1, combined), min(1, combined) * master}
//   system = {1, master}          master = clamp(volume_percent,0,100)/100
// When the recording has no decodable mic sidecar, the caller simply never
// uses `.mic` — gain/normalize are inert by construction (macOS D7
// semantics); `.system` carries the volume either way.
SeparatedAudioStages ResolveSeparatedAudioStages(double gain_db,
                                                 double volume_percent,
                                                 bool normalize,
                                                 double target_loudness_dbfs,
                                                 double mic_peak_linear);

// Sum two interleaved int16 buffers element-wise with int32 arithmetic and
// saturation to int16 — the separated tracks' mix-down (macOS's
// AVAssetReaderAudioMixOutput sums the composition tracks the same way).
void SumInt16Saturating(const std::int16_t* a, const std::int16_t* b,
                        std::size_t count, std::int16_t* out);

// FIFO pair merging two independently-pumped separated tracks into summed
// packets. The two ReorderAudioPumps run the SAME AudioSlots plan so their
// TOTAL emitted frames agree at every PumpUpTo limit, but their per-packet
// boundaries need not (decoder priming, silence chunking) — the FIFOs
// absorb the skew and `PopMerged` releases only frames present on every
// active track. Pure (no MF) so the merge behavior is unit-testable.
class SeparatedAudioMerge {
 public:
  // `has_mic` / `has_system` name the tracks that will actually feed the
  // merge; an absent track never gates `ReadyFrames`. At least one must be
  // true. `channels` is the interleave width (2 for the pipeline).
  SeparatedAudioMerge(bool has_mic, bool has_system, std::uint32_t channels);

  void AppendMic(const std::int16_t* samples, std::size_t frame_count);
  void AppendSystem(const std::int16_t* samples, std::size_t frame_count);

  // Frames available on EVERY active track (the mergeable prefix).
  std::int64_t ReadyFrames() const;

  // Pop up to `max_frames` merged frames into `out` (resized to the popped
  // frame count x channels; saturating sum when both tracks are active,
  // pass-through when one). Returns the frames popped.
  std::int64_t PopMerged(std::int64_t max_frames,
                         std::vector<std::int16_t>& out);

  // Drop ALL buffered samples on both tracks — including the unmatched
  // skew PopMerged never releases. Used on a seek/re-prime so no stale
  // pre-seek sample can be summed against post-seek data.
  void Clear();

 private:
  bool has_mic_ = false;
  bool has_system_ = false;
  std::uint32_t channels_ = 2;
  std::deque<std::int16_t> mic_;
  std::deque<std::int16_t> system_;
};

}  // namespace clingfy::capture::export_

#endif  // RUNNER_CAPTURE_EXPORT_EXPORT_AUDIO_H_
