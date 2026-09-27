#ifndef RUNNER_AUDIO_MICROPHONE_LEVEL_MONITOR_H_
#define RUNNER_AUDIO_MICROPHONE_LEVEL_MONITOR_H_

#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

#include "Audio/audio_packet_queue.h"
#include "Audio/microphone_level.h"
#include "Audio/wasapi_audio_capture.h"

// Live input metering for the pre-recording bar, and the source of the
// "your microphone is very quiet" warning on Windows.
//
// WHY THIS EXISTS. Every consumer of `microphoneLevel` shipped long before
// this file: `DeviceController._applyMicrophoneLevelEvent` parses it, the
// meter widget draws it, and `recording_audio_section.dart` shows
// `mic_input_too_low_warning` off it -- none of them platform-gated. Windows
// simply never sent the event, so `_micInputLevelDbfs` sat at its initial
// -160.0 for the life of the process and the warning could not fire. A user
// recorded a full take into a microphone putting out nothing but a noise
// floor and only found out afterwards. macOS has had this since
// `MicrophoneLevelMonitor.swift`; this is the Windows half.
//
// SCOPE: pre-recording only. macOS runs an idle monitor and then lets the
// recording's own tap take over (`refreshMicrophoneLevelMonitoring`); here
// the monitor stops for the duration of a recording. The warning's job is to
// be seen BEFORE the take, which is the part that was missing.
namespace clingfy::audio {

// Whether the monitor should be running, given the current selection and
// recording state. Pure so the policy can be asserted without an endpoint.
//
// Not running while recording is deliberate. WASAPI shared mode would happily
// give us a second client on the same endpoint, but a meter is not worth a
// second capture thread on the device the recording depends on, and a monitor
// that outlived a Stop would keep the microphone's in-use indicator lit after
// the user finished.
bool ShouldMonitorMicrophoneLevel(const std::optional<std::string>& selected_id,
                                  bool recording);

class MicrophoneLevelMonitor {
 public:
  using Emitter = std::function<void(const MicrophoneLevel&)>;

  static MicrophoneLevelMonitor& Instance();

  MicrophoneLevelMonitor(const MicrophoneLevelMonitor&) = delete;
  MicrophoneLevelMonitor& operator=(const MicrophoneLevelMonitor&) = delete;

  // Reconcile against the current selection and recording state. Idempotent:
  // re-applying the same device while already running does NOT restart the
  // capture, so the repeated `setAudioSource` calls the UI makes cannot churn
  // the endpoint open and closed.
  void Apply(const std::optional<std::string>& selected_id, bool recording);

  void Start(const std::string& device_id);

  // `emit_silence` sends one last floor reading so the meter falls to zero
  // rather than freezing at the user's last syllable. It reports
  // [SilentMicrophoneLevel], which does NOT set `is_low` -- stopping is not a
  // quiet microphone.
  void Stop(bool emit_silence);

  bool running() const;
  std::string device_id() const;

  // Test seam. Replaces the DeviceEventPublisher hop so the loop can be
  // observed without a Flutter sink. Pass nullptr to restore the default.
  void SetEmitterForTesting(Emitter emitter);

  ~MicrophoneLevelMonitor();

 private:
  MicrophoneLevelMonitor();

  void ConsumeLoop();
  void Emit(const MicrophoneLevel& level);
  void NoteIfQuiet(const MicrophoneLevel& level);

  mutable std::mutex mutex_;
  Emitter emitter_;
  std::string device_id_;
  bool running_ = false;

  // Set from the WASAPI capture thread when the endpoint dies under us
  // (AUDCLNT_E_DEVICE_INVALIDATED on unplug). The consumer loop observes it
  // and exits; it must NOT call Stop() from that callback, because Stop()
  // joins the capture thread and that callback runs ON it.
  std::atomic<bool> capture_failed_{false};

  // One breadcrumb per monitored session when the input turns out to be too
  // quiet to record with. Latched because the level crosses the threshold
  // between syllables -- logging every crossing at 15 Hz would bury the log,
  // and the fact worth recording is "this session saw a quiet input", once.
  bool logged_low_ = false;

  std::unique_ptr<AudioPacketQueue> queue_;
  std::unique_ptr<WasapiAudioCapture> capture_;
  std::thread consumer_;
};

}  // namespace clingfy::audio

#endif  // RUNNER_AUDIO_MICROPHONE_LEVEL_MONITOR_H_
