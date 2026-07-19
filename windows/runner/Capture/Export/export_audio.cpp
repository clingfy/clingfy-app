#include "Capture/Export/export_audio.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>

namespace clingfy::capture::export_ {

namespace {

constexpr double kMaxGainDb = 24.0;
constexpr double kMinTargetDbfs = -24.0;
constexpr double kMaxTargetDbfs = -6.0;
// Below this peak the source is effectively silent; normalizing it would
// divide by ~0 and blow up, so macOS skips normalize and falls back to the
// plain user gain (LetterboxExporter.swift:2723).
constexpr double kSilenceFloorLinear = 1e-6;
constexpr double kUnityEpsilon = 1e-9;
constexpr double kInt16Max = 32767.0;
constexpr double kInt16Min = -32768.0;

double Clamp(double value, double lo, double hi) {
  return std::min(std::max(value, lo), hi);
}

double DbToLinear(double db) { return std::pow(10.0, db / 20.0); }

// Multiply, hard-clamp to the asymmetric int16 range, then truncate toward
// zero (the static_cast truncates) to match Swift `Int16(clipped)`.
std::int16_t ScaleClampTruncInt16(std::int16_t sample, double factor) {
  double scaled = static_cast<double>(sample) * factor;
  if (scaled > kInt16Max) {
    scaled = kInt16Max;
  } else if (scaled < kInt16Min) {
    scaled = kInt16Min;
  }
  return static_cast<std::int16_t>(scaled);
}

}  // namespace

bool RequiresAudioProcessing(double gain_db, double volume_percent,
                             bool normalize) {
  return normalize || gain_db > 1e-6 || volume_percent < 100.0 - 1e-6;
}

double Int16PeakLinear(const std::int16_t* samples, std::size_t count) {
  double peak = 0.0;
  for (std::size_t i = 0; i < count; ++i) {
    const std::int16_t s = samples[i];
    // Map INT16_MIN to 1.0 rather than 32768/32767 (> 1) — macOS parity.
    // Negate via int promotion only for non-INT16_MIN values to avoid the
    // signed-overflow UB of -INT16_MIN.
    const double linear =
        (s == INT16_MIN)
            ? 1.0
            : static_cast<double>(s < 0 ? -static_cast<int>(s) : s) / kInt16Max;
    if (linear > peak) {
      peak = linear;
    }
  }
  return std::min(peak, 1.0);
}

AudioGainStages ResolveAudioGainStages(double gain_db, double volume_percent,
                                       bool normalize,
                                       double target_loudness_dbfs,
                                       double source_peak_linear) {
  const double gain_linear = DbToLinear(Clamp(gain_db, 0.0, kMaxGainDb));
  const double volume_linear = Clamp(volume_percent, 0.0, 100.0) / 100.0;

  if (!normalize || source_peak_linear <= kSilenceFloorLinear) {
    return AudioGainStages{gain_linear, volume_linear};
  }

  // Normalize: macOS scales the measured peak toward the target and folds the
  // user gain/volume + normalize into a SINGLE non-unity factor (gain-only or
  // volume-only). We carry that whole scale in the gain stage (volume = 1.0),
  // which the two-stage apply reduces to one clamp — the same result, since
  // only one factor is ever non-unity. Net clamped to <= +24 dB so a quiet
  // recording can't be amplified into extreme clipping.
  const double user_linear = volume_linear * gain_linear;
  const double target_linear =
      DbToLinear(Clamp(target_loudness_dbfs, kMinTargetDbfs, kMaxTargetDbfs));
  const double resolved =
      Clamp(user_linear * (target_linear / source_peak_linear), 0.0,
            DbToLinear(kMaxGainDb));
  return AudioGainStages{resolved, 1.0};
}

SeparatedAudioStages ResolveSeparatedAudioStages(double gain_db,
                                                 double volume_percent,
                                                 bool normalize,
                                                 double target_loudness_dbfs,
                                                 double mic_peak_linear) {
  const double master = Clamp(volume_percent, 0.0, 100.0) / 100.0;

  // Combined mic boost: user gain composed with the normalize scale, capped
  // at +24 dB TOTAL (macOS resolveSeparatedAudioControls clamps the
  // combination, not each factor — gain 24 dB + normalize never stacks).
  double combined = DbToLinear(Clamp(gain_db, 0.0, kMaxGainDb));
  if (normalize && mic_peak_linear > kSilenceFloorLinear) {
    const double target_linear = DbToLinear(
        Clamp(target_loudness_dbfs, kMinTargetDbfs, kMaxTargetDbfs));
    combined *= target_linear / mic_peak_linear;
  }
  combined = Clamp(combined, 0.0, DbToLinear(kMaxGainDb));

  // The macOS split: the >1 part is baked with an int16-truncating gain tap
  // (micGainDb), the <=1 part rides the track volume (micVolumeComponent),
  // and masterLinear multiplies every track's volume.
  SeparatedAudioStages out;
  out.mic = AudioGainStages{std::max(1.0, combined),
                            std::min(1.0, combined) * master};
  out.system = AudioGainStages{1.0, master};
  return out;
}

void SumInt16Saturating(const std::int16_t* a, const std::int16_t* b,
                        std::size_t count, std::int16_t* out) {
  for (std::size_t i = 0; i < count; ++i) {
    const std::int32_t sum =
        static_cast<std::int32_t>(a[i]) + static_cast<std::int32_t>(b[i]);
    out[i] = static_cast<std::int16_t>(
        std::min<std::int32_t>(32767, std::max<std::int32_t>(-32768, sum)));
  }
}

SeparatedAudioMerge::SeparatedAudioMerge(bool has_mic, bool has_system,
                                         std::uint32_t channels)
    : has_mic_(has_mic),
      has_system_(has_system),
      channels_(channels == 0 ? 1 : channels) {}

void SeparatedAudioMerge::AppendMic(const std::int16_t* samples,
                                    std::size_t frame_count) {
  if (!has_mic_ || samples == nullptr) {
    return;
  }
  mic_.insert(mic_.end(), samples, samples + frame_count * channels_);
}

void SeparatedAudioMerge::AppendSystem(const std::int16_t* samples,
                                       std::size_t frame_count) {
  if (!has_system_ || samples == nullptr) {
    return;
  }
  system_.insert(system_.end(), samples, samples + frame_count * channels_);
}

std::int64_t SeparatedAudioMerge::ReadyFrames() const {
  std::int64_t ready = std::numeric_limits<std::int64_t>::max();
  if (has_mic_) {
    ready = std::min<std::int64_t>(
        ready, static_cast<std::int64_t>(mic_.size() / channels_));
  }
  if (has_system_) {
    ready = std::min<std::int64_t>(
        ready, static_cast<std::int64_t>(system_.size() / channels_));
  }
  return ready == std::numeric_limits<std::int64_t>::max() ? 0 : ready;
}

std::int64_t SeparatedAudioMerge::PopMerged(std::int64_t max_frames,
                                            std::vector<std::int16_t>& out) {
  const std::int64_t frames =
      std::max<std::int64_t>(0, std::min(max_frames, ReadyFrames()));
  const std::size_t count =
      static_cast<std::size_t>(frames) * static_cast<std::size_t>(channels_);
  out.resize(count);
  if (frames == 0) {
    return 0;
  }
  if (has_mic_ && has_system_) {
    for (std::size_t i = 0; i < count; ++i) {
      const std::int32_t sum = static_cast<std::int32_t>(mic_[i]) +
                               static_cast<std::int32_t>(system_[i]);
      out[i] = static_cast<std::int16_t>(
          std::min<std::int32_t>(32767, std::max<std::int32_t>(-32768, sum)));
    }
    mic_.erase(mic_.begin(), mic_.begin() + count);
    system_.erase(system_.begin(), system_.begin() + count);
  } else if (has_mic_) {
    std::copy(mic_.begin(), mic_.begin() + count, out.begin());
    mic_.erase(mic_.begin(), mic_.begin() + count);
  } else {
    std::copy(system_.begin(), system_.begin() + count, out.begin());
    system_.erase(system_.begin(), system_.begin() + count);
  }
  return frames;
}

void ApplyAudioGain(std::int16_t* samples, std::size_t count,
                    const AudioGainStages& stages) {
  const bool apply_gain = std::abs(stages.gain - 1.0) >= kUnityEpsilon;
  const bool apply_volume = std::abs(stages.volume - 1.0) >= kUnityEpsilon;
  if (!apply_gain && !apply_volume) {
    return;  // no-op
  }
  for (std::size_t i = 0; i < count; ++i) {
    std::int16_t s = samples[i];
    // Gain stage first (clamped to int16), then volume attenuates the clamped
    // result — matches the macOS gain-tap-then-setVolume order so a boosted
    // loud sample is hard-limited before volume scales it.
    if (apply_gain) {
      s = ScaleClampTruncInt16(s, stages.gain);
    }
    if (apply_volume) {
      s = ScaleClampTruncInt16(s, stages.volume);
    }
    samples[i] = s;
  }
}

}  // namespace clingfy::capture::export_
