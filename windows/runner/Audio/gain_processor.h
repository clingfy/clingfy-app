// Gain/volume DSP node — the first node of the audio effect chain.
//
// DELIBERATELY host-agnostic: no WinRT, no COM, no Media Foundation, no
// Windows headers. It takes a buffer of interleaved float32 and scales it.
// That is the whole contract.
//
// Why it is shaped this way rather than living inside an IBasicAudioEffect:
// the effect wrapper is a host adapter and is expected to be thrown away. The
// same core has to drop into the WASAPI renderer when the passthrough and
// edited paths converge, and a matching adapter gives the macOS
// AVAudioEngine/AudioUnit path the same DSP for free. Anything that knows
// about the host cannot follow it there.
//
// Gain is trivial on purpose. It is the cheapest possible place to get the
// three things that are painful to retrofit right: sample-format negotiation,
// parameter updates arriving from Dart mid-playback, and thread-safety at the
// audio callback. Getting those wrong on a multiply costs nothing to find.
//
// THREADING. Exactly two roles:
//   * Any thread may call SetStages(). It publishes lock-free.
//   * ONE audio thread calls Prepare()/Process()/Reset(). Process() never
//     allocates, never locks, and never blocks — it runs under a real-time
//     deadline where a page fault is an audible glitch.

#ifndef RUNNER_AUDIO_GAIN_PROCESSOR_H_
#define RUNNER_AUDIO_GAIN_PROCESSOR_H_

#include <atomic>
#include <cstddef>
#include <cstdint>

namespace clingfy::audio {

// Ramp length applied when the gain or volume target moves. Long enough that a
// step change is inaudible, short enough that a slider still feels live.
inline constexpr double kGainRampMs = 10.0;

// The two ordered stages, as linear multipliers.
//
// Mirrors `capture::export_::AudioGainStages`. Deliberately re-declared rather
// than included: this unit must not depend on the export pipeline, or it
// cannot move to another host. The conversion from dB/percent stays in
// `ResolveAudioGainStages`, which remains the single source of that math — this
// node only ever receives resolved linear values.
struct GainStages {
  double gain = 1.0;    // amplifies; >= 1.0 in practice
  double volume = 1.0;  // attenuates; in [0, 1]
};

class GainProcessor {
 public:
  GainProcessor() = default;

  GainProcessor(const GainProcessor&) = delete;
  GainProcessor& operator=(const GainProcessor&) = delete;

  // Audio thread. Called when the stream format is known or changes; sets the
  // ramp length in frames. Safe to call with a rate this has already seen.
  void Prepare(double sample_rate_hz);

  // ANY thread, lock-free. Affects only future samples — never re-processes
  // audio that has already been handed to the device, which is why a change
  // lands within one ramp rather than instantly.
  void SetStages(const GainStages& stages);

  // Audio thread ONLY. Scales `frames * channels` interleaved float32 samples
  // in place. A no-op when both stages are at unity and no ramp is in flight,
  // so an untouched preview costs one comparison per buffer.
  void Process(float* buffer, std::size_t frames, std::uint32_t channels);

  // Audio thread. Jumps the smoothed values to their targets. Call after a
  // seek or a device rebuild, where there is no previous audio to glide from
  // and a ramp would just be a fade-in on the first buffer.
  void Reset();

  // Test seam: the stages currently published (not the smoothed values).
  GainStages TargetStages() const;

  // Test seam: the smoothed values the next sample would use.
  GainStages SmoothedStages() const;

 private:
  // Both stages packed into ONE 64-bit word so a reader can never observe a
  // new gain against an old volume. Two separate atomics would tear across the
  // pair, and the mismatched frame would be a click at exactly the moment the
  // user moves a slider.
  static std::uint64_t Pack(const GainStages& stages);
  static GainStages Unpack(std::uint64_t packed);

  std::atomic<std::uint64_t> target_{Pack(GainStages{})};
  static_assert(std::atomic<std::uint64_t>::is_always_lock_free,
                "the parameter block must not take a lock on the audio thread");

  // Audio-thread-only state. Never touched from anywhere else.
  double current_gain_ = 1.0;
  double current_volume_ = 1.0;
  double ramp_frames_ = 1.0;

  // The in-flight ramp. Steps are computed ONCE when the target moves and then
  // consumed frame by frame. Recomputing them per buffer from the remaining
  // distance instead makes the glide an exponential approach whose duration
  // depends on how the host happens to size its buffers — with small buffers it
  // never actually arrives.
  std::uint64_t last_target_ = Pack(GainStages{});
  double gain_step_ = 0.0;
  double volume_step_ = 0.0;
  double ramp_remaining_ = 0.0;
};

}  // namespace clingfy::audio

#endif  // RUNNER_AUDIO_GAIN_PROCESSOR_H_
