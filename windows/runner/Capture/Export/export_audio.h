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

}  // namespace clingfy::capture::export_

#endif  // RUNNER_CAPTURE_EXPORT_EXPORT_AUDIO_H_
