#ifndef RUNNER_AUDIO_WASAPI_AUDIO_CAPTURE_H_
#define RUNNER_AUDIO_WASAPI_AUDIO_CAPTURE_H_

#include <windows.h>

#include <cstdint>
#include <memory>
#include <optional>
#include <string>

#include "Audio/audio_format.h"
#include "Audio/audio_packet_queue.h"

// Unified WASAPI capture client used for both the microphone path and the
// system-audio loopback path. The two paths share 90% of the same Win32
// dance (activate IAudioClient → Initialize with shared-mode +
// event-driven → IAudioCaptureClient → service loop), differing only in:
//
//   * Which IMMDevice they open (eCapture → microphone,
//     eRender + AUDCLNT_STREAMFLAGS_LOOPBACK → system audio)
//   * The user-facing label in diagnostics
//
// Phase 3D rejects mix formats that aren't 48 kHz float32 stereo with a
// structured error rather than attempting to resample. The pinned format
// matches both the typical Windows shared-mode default and the AAC
// encoder configured in `MfSinkWriterEncoder`.
namespace clingfy::audio {

enum class WasapiCaptureKind {
  kMicrophone,
  kSystemLoopback,
};

struct WasapiCaptureError {
  std::string message;
  HRESULT hr = 0;
};

class WasapiAudioCapture {
 public:
  WasapiAudioCapture();
  ~WasapiAudioCapture();

  WasapiAudioCapture(const WasapiAudioCapture&) = delete;
  WasapiAudioCapture& operator=(const WasapiAudioCapture&) = delete;

  // Open + start capture. `device_id` selects the WASAPI endpoint by
  // its `IMMDevice::GetId` value; when empty, the default endpoint for
  // the matching flow is used. Captured packets are pushed into
  // `queue` on a dedicated capture thread.
  std::optional<WasapiCaptureError> Start(WasapiCaptureKind kind,
                                          const std::string& device_id,
                                          AudioPacketQueue& queue);

  // Stop the capture thread, signal the WASAPI client to stop, and
  // wait for everything to drain. Safe to call multiple times.
  void Stop();

  // Phase 4: pause / resume. Pause calls IAudioClient::Stop, which
  // halts buffer production at the OS level — the capture thread
  // keeps spinning on its event handle but the wait times out
  // cleanly because no new buffers fire. Resume restarts via
  // IAudioClient::Start. Both are idempotent.
  void Pause();
  void Resume();

  WasapiCaptureKind kind() const;
  AudioFormatSnapshot format() const;
  std::uint64_t packets_emitted() const;
  bool running() const;

 private:
  // Pimpl so the IMMDevice / IAudioClient / IAudioCaptureClient COM
  // pointers stay out of consumer headers. The implementation includes
  // <audioclient.h> and <mmdeviceapi.h>; everything else here is a
  // simple owner / accessor.
  class Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace clingfy::audio

#endif  // RUNNER_AUDIO_WASAPI_AUDIO_CAPTURE_H_
