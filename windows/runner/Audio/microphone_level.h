#ifndef RUNNER_AUDIO_MICROPHONE_LEVEL_H_
#define RUNNER_AUDIO_MICROPHONE_LEVEL_H_

#include <chrono>
#include <cstddef>
#include <optional>

// Input-level metering for the pre-recording microphone meter and the
// "your microphone is very quiet" warning.
//
// Pure arithmetic, deliberately separated from the WASAPI monitor that feeds
// it, so the decision table is unit-testable on a headless runner with no
// audio endpoint. The Windows CI job has no microphone; everything that can be
// checked without one is checked here.
//
// PARITY: the wire contract is fixed by the macOS implementation
// (`MicrophoneLevelSample` in macos/Runner/Capture/Backends/CaptureBackend.swift
// and `fireMicrophoneLevel` in MainFlutterWindow.swift). Dart consumes ONE
// shape from both platforms — `{type, linear, dbfs, isLow}`, handled by
// `DeviceController._applyMicrophoneLevelEvent`. Keep the three numbers
// meaning the same thing on both sides or the same meter reads differently
// per platform.
namespace clingfy::audio {

// Floor reported when there is no signal at all, matching macOS's
// `MicrophoneLevelSample(linear: 0.0, dbfs: -160.0)`. Also what Dart's
// `DeviceController` initialises to, so a platform that never reports and one
// reporting silence look the same to the UI.
inline constexpr double kMicLevelSilenceDbfs = -160.0;

// Below this, the input is "too quiet to record with" and the pre-recording
// bar shows the warning. -32 dBFS is the macOS threshold
// (`MicrophoneLevelSample.isLow`); Dart applies the same number as a fallback
// when a platform omits the flag (`device_controller.dart:521`). Three copies
// of one constant is two too many, but the wire format is what it is — if this
// moves, move all three.
inline constexpr double kMicLevelLowDbfs = -32.0;

struct MicrophoneLevel {
  // Peak amplitude, clamped to [0, 1]. Drives the meter's fill.
  double linear = 0.0;
  // Peak in dBFS, floored at [kMicLevelSilenceDbfs]. Drives the numeric
  // readout and the warning.
  double dbfs = kMicLevelSilenceDbfs;
  // Whether to show the quiet-input warning.
  bool is_low = false;
};

// Level of one buffer of interleaved float32 samples in [-1, 1].
//
// PEAK, not RMS, deliberately. The question the meter answers is "is the
// loudest thing you just said anywhere near usable", and RMS over a buffer
// containing a pause reads far lower than the speech inside it — which would
// warn about a perfectly good microphone every time the user stopped for
// breath. Peak also matches what `volumedetect` and every other meter reports,
// so a number quoted from the app can be compared with one from a tool.
//
// A null pointer or zero count reports silence rather than failing: an empty
// buffer is a normal thing for a capture client to hand back.
MicrophoneLevel ComputeMicrophoneLevel(const float* samples,
                                       std::size_t sample_count);

// The silence reading, for stop paths and for a deselected device.
MicrophoneLevel SilentMicrophoneLevel();

// How often a level reaches Dart. 15 Hz, copied from macOS's
// `MicrophoneLevelMonitor` (`1.0 / 15.0`) so the meter animates at the same
// speed on both platforms.
//
// It cannot be per-buffer: WASAPI hands over a packet roughly every 10 ms, and
// 100 method-channel events a second per microphone is a measurable cost for a
// bar that redraws at display rate anyway.
inline constexpr std::chrono::microseconds kMicLevelEmitInterval{66'667};

// Folds many capture buffers into one reading per [kMicLevelEmitInterval].
//
// Separated from the WASAPI monitor on purpose: the Windows CI runner has no
// audio endpoint, so the cadence and the hold-the-peak behavior can only be
// tested if they live somewhere a test can drive with a fake clock. The
// monitor above it is then thin enough to read.
class MicrophoneLevelAccumulator {
 public:
  explicit MicrophoneLevelAccumulator(
      std::chrono::steady_clock::duration interval = kMicLevelEmitInterval);

  // Fold one capture buffer in. Cheap; called on the capture consumer thread
  // for every packet.
  void Add(const float* samples, std::size_t sample_count);

  // The reading to publish, or nullopt when the interval has not elapsed.
  //
  // Returns the PEAK ACROSS THE WHOLE WINDOW, not the last buffer's — a
  // 66 ms window holds about seven packets, and reporting only the last would
  // make the meter miss most transients and flicker toward zero between
  // syllables.
  //
  // Emits even when nothing was added, which is what makes a microphone that
  // has gone silent read as silent instead of freezing at its last value.
  std::optional<MicrophoneLevel> TakeIfDue(
      std::chrono::steady_clock::time_point now);

  // Drop the accumulated peak and the schedule, so the next TakeIfDue emits
  // immediately. For stop / device-switch.
  void Reset();

 private:
  std::chrono::steady_clock::duration interval_;
  float peak_ = 0.0f;
  bool scheduled_ = false;
  std::chrono::steady_clock::time_point next_emit_{};
};

}  // namespace clingfy::audio

#endif  // RUNNER_AUDIO_MICROPHONE_LEVEL_H_
