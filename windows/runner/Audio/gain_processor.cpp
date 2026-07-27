#include "Audio/gain_processor.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace clingfy::audio {

namespace {

// Matches `kUnityEpsilon` in export_audio.cpp: below this a stage is treated as
// unity so an untouched preview stays a pure copy.
constexpr double kUnityEpsilon = 1e-6;

bool IsUnity(double v) { return std::abs(v - 1.0) < kUnityEpsilon; }

float ClampUnit(float v) { return std::clamp(v, -1.0f, 1.0f); }

}  // namespace

std::uint64_t GainProcessor::Pack(const GainStages& stages) {
  // float32 is ample for a multiplier and lets both stages share one word.
  const float g = static_cast<float>(stages.gain);
  const float v = static_cast<float>(stages.volume);
  std::uint32_t gb = 0;
  std::uint32_t vb = 0;
  std::memcpy(&gb, &g, sizeof gb);
  std::memcpy(&vb, &v, sizeof vb);
  return (static_cast<std::uint64_t>(gb) << 32) | vb;
}

GainStages GainProcessor::Unpack(std::uint64_t packed) {
  const auto gb = static_cast<std::uint32_t>(packed >> 32);
  const auto vb = static_cast<std::uint32_t>(packed & 0xFFFFFFFFull);
  float g = 1.0f;
  float v = 1.0f;
  std::memcpy(&g, &gb, sizeof g);
  std::memcpy(&v, &vb, sizeof v);
  return GainStages{static_cast<double>(g), static_cast<double>(v)};
}

void GainProcessor::Prepare(double sample_rate_hz) {
  // A degenerate rate must not produce a zero or infinite ramp; one frame just
  // means "apply immediately", which is the old un-smoothed behaviour.
  if (!(sample_rate_hz > 0.0)) {
    ramp_frames_ = 1.0;
    return;
  }
  ramp_frames_ = std::max(1.0, sample_rate_hz * (kGainRampMs / 1000.0));
}

void GainProcessor::SetStages(const GainStages& stages) {
  GainStages clamped;
  // Defensive only — ResolveAudioGainStages already clamps. A negative
  // multiplier here would invert the waveform's phase rather than change its
  // level, which is not a thing any control in the UI can mean.
  clamped.gain = std::max(0.0, stages.gain);
  clamped.volume = std::clamp(stages.volume, 0.0, 1.0);
  target_.store(Pack(clamped), std::memory_order_release);
}

void GainProcessor::Reset() {
  const std::uint64_t packed = target_.load(std::memory_order_acquire);
  const GainStages target = Unpack(packed);
  current_gain_ = target.gain;
  current_volume_ = target.volume;
  // Cancel any in-flight glide too, or the next Process would keep stepping
  // toward a target it is already sitting on.
  last_target_ = packed;
  gain_step_ = 0.0;
  volume_step_ = 0.0;
  ramp_remaining_ = 0.0;
}

void GainProcessor::Process(float* buffer, std::size_t frames,
                            std::uint32_t channels) {
  if (buffer == nullptr || frames == 0 || channels == 0) return;

  const std::uint64_t packed = target_.load(std::memory_order_acquire);
  const GainStages target = Unpack(packed);

  // Arm a new ramp only when the target actually moves. The steps are fixed for
  // the whole glide, so it lasts kGainRampMs of wall clock no matter how the
  // host sizes its buffers.
  if (packed != last_target_) {
    last_target_ = packed;
    gain_step_ = (target.gain - current_gain_) / ramp_frames_;
    volume_step_ = (target.volume - current_volume_) / ramp_frames_;
    ramp_remaining_ = ramp_frames_;
  }

  // Fast path: sitting at unity with no glide in flight. An untouched preview
  // pays one comparison per buffer, not one multiply per sample.
  if (ramp_remaining_ <= 0.0 && IsUnity(current_gain_) &&
      IsUnity(current_volume_)) {
    return;
  }

  std::size_t i = 0;
  for (std::size_t frame = 0; frame < frames; ++frame) {
    if (ramp_remaining_ > 0.0) {
      ramp_remaining_ -= 1.0;
      // Clamp against the target so the last step cannot overshoot, and land
      // exactly on it when the ramp runs out.
      if (gain_step_ > 0.0) {
        current_gain_ = std::min(current_gain_ + gain_step_, target.gain);
      } else if (gain_step_ < 0.0) {
        current_gain_ = std::max(current_gain_ + gain_step_, target.gain);
      }
      if (volume_step_ > 0.0) {
        current_volume_ = std::min(current_volume_ + volume_step_, target.volume);
      } else if (volume_step_ < 0.0) {
        current_volume_ = std::max(current_volume_ + volume_step_, target.volume);
      }
      if (ramp_remaining_ <= 0.0) {
        current_gain_ = target.gain;
        current_volume_ = target.volume;
      }
    }

    const auto gain = static_cast<float>(current_gain_);
    const auto volume = static_cast<float>(current_volume_);

    for (std::uint32_t c = 0; c < channels; ++c, ++i) {
      // ORDER IS LOAD-BEARING and mirrors `ApplyAudioGain`: the gain stage is
      // hard-limited BEFORE volume attenuates the limited result. Collapsing
      // this to one `sample * gain * volume` multiply gives a different, louder
      // answer for anything that clips, and the preview would stop matching the
      // export. macOS does gain-tap-then-setVolume for the same reason.
      float s = ClampUnit(buffer[i] * gain);
      s = ClampUnit(s * volume);
      buffer[i] = s;
    }
  }
}

GainStages GainProcessor::TargetStages() const {
  return Unpack(target_.load(std::memory_order_acquire));
}

GainStages GainProcessor::SmoothedStages() const {
  return GainStages{current_gain_, current_volume_};
}

}  // namespace clingfy::audio
