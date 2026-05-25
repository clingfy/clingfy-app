#include "Audio/wasapi_audio_capture.h"

#include <windows.h>
#include <audioclient.h>
#include <avrt.h>
#include <mmdeviceapi.h>
#include <mmreg.h>
#include <wrl/client.h>

#include <atomic>
#include <chrono>
#include <cstring>
#include <thread>
#include <utility>

namespace clingfy::audio {

namespace {

using Microsoft::WRL::ComPtr;

constexpr REFERENCE_TIME kHundredNanosPerMs = 10'000;

class ScopedComInit {
 public:
  ScopedComInit() {
    HRESULT hr = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    owns_ = SUCCEEDED(hr);
    if (hr == S_FALSE || hr == RPC_E_CHANGED_MODE) {
      owns_ = false;
    }
  }
  ~ScopedComInit() {
    if (owns_) ::CoUninitialize();
  }
  ScopedComInit(const ScopedComInit&) = delete;
  ScopedComInit& operator=(const ScopedComInit&) = delete;

 private:
  bool owns_ = false;
};

WasapiCaptureError MakeError(const char* message, HRESULT hr) {
  return WasapiCaptureError{std::string(message), hr};
}

}  // namespace

class WasapiAudioCapture::Impl {
 public:
  std::optional<WasapiCaptureError> Start(WasapiCaptureKind kind,
                                          const std::string& device_id,
                                          AudioPacketQueue& queue);
  void Stop();
  void Pause();
  void Resume();

  WasapiCaptureKind kind() const { return kind_; }
  AudioFormatSnapshot format() const { return format_; }
  std::uint64_t packets_emitted() const { return packets_emitted_.load(); }
  bool running() const { return running_.load(); }

  ~Impl() { Stop(); }

 private:
  void CaptureLoop();
  ComPtr<IMMDevice> OpenDevice(WasapiCaptureKind kind,
                               const std::string& device_id,
                               WasapiCaptureError* out_error);

  WasapiCaptureKind kind_ = WasapiCaptureKind::kMicrophone;
  AudioPacketQueue* queue_ = nullptr;
  AudioFormatSnapshot format_{};

  ComPtr<IAudioClient> client_;
  ComPtr<IAudioCaptureClient> capture_client_;
  HANDLE event_ = nullptr;
  HANDLE stop_event_ = nullptr;
  std::thread thread_;
  std::atomic<bool> running_{false};
  std::atomic<bool> paused_{false};
  std::atomic<std::uint64_t> packets_emitted_{0};
};

ComPtr<IMMDevice> WasapiAudioCapture::Impl::OpenDevice(
    WasapiCaptureKind kind,
    const std::string& device_id,
    WasapiCaptureError* out_error) {
  ComPtr<IMMDeviceEnumerator> enumerator;
  HRESULT hr = ::CoCreateInstance(
      __uuidof(MMDeviceEnumerator), nullptr, CLSCTX_INPROC_SERVER,
      __uuidof(IMMDeviceEnumerator), &enumerator);
  if (FAILED(hr) || enumerator == nullptr) {
    if (out_error)
      *out_error = MakeError("CoCreateInstance(MMDeviceEnumerator) failed.", hr);
    return nullptr;
  }

  ComPtr<IMMDevice> device;
  // Loopback always opens the default *render* endpoint per WASAPI
  // contract; the AUDCLNT_STREAMFLAGS_LOOPBACK flag during Initialize
  // turns the render endpoint into a capture source for everything
  // currently playing through it.
  if (kind == WasapiCaptureKind::kSystemLoopback) {
    hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
    if (FAILED(hr) || device == nullptr) {
      if (out_error)
        *out_error = MakeError(
            "GetDefaultAudioEndpoint(eRender) failed — system audio loopback "
            "unavailable.",
            hr);
      return nullptr;
    }
    return device;
  }

  // Microphone path: prefer the user's saved selection, fall back to the
  // default capture endpoint.
  if (!device_id.empty()) {
    const int needed = ::MultiByteToWideChar(
        CP_UTF8, 0, device_id.c_str(), static_cast<int>(device_id.size()),
        nullptr, 0);
    if (needed > 0) {
      std::wstring wide(static_cast<size_t>(needed), L'\0');
      ::MultiByteToWideChar(CP_UTF8, 0, device_id.c_str(),
                            static_cast<int>(device_id.size()), wide.data(),
                            needed);
      hr = enumerator->GetDevice(wide.c_str(), &device);
      if (SUCCEEDED(hr) && device != nullptr) {
        return device;
      }
      // Fall through to the default endpoint; a stale device id (e.g.
      // headset unplugged) should not block the recording.
    }
  }
  hr = enumerator->GetDefaultAudioEndpoint(eCapture, eConsole, &device);
  if (FAILED(hr) || device == nullptr) {
    if (out_error)
      *out_error = MakeError(
          "GetDefaultAudioEndpoint(eCapture) failed — no microphone "
          "available.",
          hr);
    return nullptr;
  }
  return device;
}

std::optional<WasapiCaptureError> WasapiAudioCapture::Impl::Start(
    WasapiCaptureKind kind,
    const std::string& device_id,
    AudioPacketQueue& queue) {
  if (running_.load()) {
    return MakeError("WasapiAudioCapture is already running.", S_FALSE);
  }

  ScopedComInit com_init;
  WasapiCaptureError err;
  auto device = OpenDevice(kind, device_id, &err);
  if (device == nullptr) {
    return err;
  }

  HRESULT hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                                  &client_);
  if (FAILED(hr) || client_ == nullptr) {
    return MakeError("IMMDevice::Activate(IAudioClient) failed.", hr);
  }

  WAVEFORMATEX* mix_format = nullptr;
  hr = client_->GetMixFormat(&mix_format);
  if (FAILED(hr) || mix_format == nullptr) {
    return MakeError("IAudioClient::GetMixFormat failed.", hr);
  }
  format_ = Snapshot(mix_format);
  if (!IsPipelineCompatible(format_)) {
    ::CoTaskMemFree(mix_format);
    return MakeError(
        "Endpoint mix format is not 48 kHz float32 stereo; Phase 3D does not "
        "yet resample.",
        E_NOTIMPL);
  }

  const DWORD stream_flags =
      AUDCLNT_STREAMFLAGS_EVENTCALLBACK |
      (kind == WasapiCaptureKind::kSystemLoopback
           ? static_cast<DWORD>(AUDCLNT_STREAMFLAGS_LOOPBACK)
           : 0u);
  // Buffer duration of 200 ms is the shared-mode safe choice: shorter
  // periods can produce AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED on some
  // drivers, and longer ones balloon end-to-end latency.
  const REFERENCE_TIME buffer_duration_hns = 200 * kHundredNanosPerMs;
  hr = client_->Initialize(AUDCLNT_SHAREMODE_SHARED, stream_flags,
                            buffer_duration_hns, 0, mix_format, nullptr);
  ::CoTaskMemFree(mix_format);
  if (FAILED(hr)) {
    return MakeError("IAudioClient::Initialize failed.", hr);
  }

  event_ = ::CreateEventW(nullptr, FALSE, FALSE, nullptr);
  stop_event_ = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (event_ == nullptr || stop_event_ == nullptr) {
    return MakeError("CreateEvent failed for WASAPI capture wake handle.",
                     E_FAIL);
  }
  hr = client_->SetEventHandle(event_);
  if (FAILED(hr)) {
    return MakeError("IAudioClient::SetEventHandle failed.", hr);
  }

  hr = client_->GetService(__uuidof(IAudioCaptureClient), &capture_client_);
  if (FAILED(hr) || capture_client_ == nullptr) {
    return MakeError("IAudioClient::GetService(IAudioCaptureClient) failed.",
                     hr);
  }

  hr = client_->Start();
  if (FAILED(hr)) {
    return MakeError("IAudioClient::Start failed.", hr);
  }

  kind_ = kind;
  queue_ = &queue;
  running_.store(true);
  thread_ = std::thread([this] { CaptureLoop(); });
  return std::nullopt;
}

void WasapiAudioCapture::Impl::CaptureLoop() {
  ScopedComInit com_init;
  // Promote the capture thread to "Pro Audio" via the multimedia
  // scheduler so OS preempts don't blow our buffer budget. If the call
  // fails (e.g. running unprivileged), the thread continues at default
  // priority — audio still records, just with marginally higher jitter.
  DWORD task_index = 0;
  HANDLE mmcss =
      ::AvSetMmThreadCharacteristicsW(L"Pro Audio", &task_index);

  HANDLE waits[2] = {event_, stop_event_};
  while (running_.load()) {
    const DWORD wait = ::WaitForMultipleObjects(2, waits, FALSE, 1000);
    if (wait == WAIT_OBJECT_0 + 1) {
      break;  // stop_event_
    }
    if (wait == WAIT_TIMEOUT) {
      continue;
    }
    if (wait != WAIT_OBJECT_0) {
      break;
    }

    UINT32 packet_length = 0;
    while (SUCCEEDED(capture_client_->GetNextPacketSize(&packet_length)) &&
           packet_length > 0) {
      BYTE* data = nullptr;
      UINT32 frames = 0;
      DWORD flags = 0;
      UINT64 device_position = 0;
      UINT64 qpc_position = 0;
      HRESULT hr = capture_client_->GetBuffer(&data, &frames, &flags,
                                               &device_position, &qpc_position);
      if (FAILED(hr)) {
        break;
      }

      AudioPacket packet;
      packet.frame_count = frames;
      packet.timestamp_hns =
          static_cast<std::int64_t>(qpc_position);
      packet.silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
      packet.samples.resize(static_cast<std::size_t>(frames) *
                            kPipelineChannelCount);
      if (data != nullptr && !packet.silent) {
        std::memcpy(packet.samples.data(), data,
                    packet.samples.size() * sizeof(float));
      }
      capture_client_->ReleaseBuffer(frames);

      if (queue_ != nullptr) {
        queue_->Push(std::move(packet));
        packets_emitted_.fetch_add(1);
      }
    }
  }

  if (mmcss != nullptr) {
    ::AvRevertMmThreadCharacteristics(mmcss);
  }
}

void WasapiAudioCapture::Impl::Stop() {
  // Signal the capture loop to exit and wait for it. Order matters:
  // running_ = false short-circuits the next iteration; SetEvent wakes
  // the thread out of WaitForMultipleObjects; join blocks until the
  // thread function returns (which is also where the MMCSS handle is
  // released). Only after the thread has fully returned do we tear
  // down the WASAPI client and close the wake handles — otherwise the
  // capture loop would call into a half-released client.
  running_.store(false);
  if (stop_event_ != nullptr) {
    ::SetEvent(stop_event_);
  }
  if (thread_.joinable()) {
    thread_.join();
  }
  if (client_ != nullptr) {
    client_->Stop();
  }
  if (event_ != nullptr) {
    ::CloseHandle(event_);
    event_ = nullptr;
  }
  if (stop_event_ != nullptr) {
    ::CloseHandle(stop_event_);
    stop_event_ = nullptr;
  }
  capture_client_.Reset();
  client_.Reset();
  queue_ = nullptr;
  paused_.store(false);
}

void WasapiAudioCapture::Impl::Pause() {
  if (!running_.load() || paused_.exchange(true)) {
    return;
  }
  if (client_ != nullptr) {
    // Stop the WASAPI client. Buffer events stop firing; the capture
    // thread's WaitForMultipleObjects sees the timeout path and idles.
    client_->Stop();
  }
}

void WasapiAudioCapture::Impl::Resume() {
  if (!running_.load() || !paused_.exchange(false)) {
    return;
  }
  if (client_ != nullptr) {
    client_->Start();
  }
}

// ---- Public forwarding ----------------------------------------------------

WasapiAudioCapture::WasapiAudioCapture()
    : impl_(std::make_unique<Impl>()) {}

WasapiAudioCapture::~WasapiAudioCapture() = default;

std::optional<WasapiCaptureError> WasapiAudioCapture::Start(
    WasapiCaptureKind kind,
    const std::string& device_id,
    AudioPacketQueue& queue) {
  return impl_->Start(kind, device_id, queue);
}

void WasapiAudioCapture::Stop() {
  impl_->Stop();
}

void WasapiAudioCapture::Pause() {
  impl_->Pause();
}

void WasapiAudioCapture::Resume() {
  impl_->Resume();
}

WasapiCaptureKind WasapiAudioCapture::kind() const {
  return impl_->kind();
}

AudioFormatSnapshot WasapiAudioCapture::format() const {
  return impl_->format();
}

std::uint64_t WasapiAudioCapture::packets_emitted() const {
  return impl_->packets_emitted();
}

bool WasapiAudioCapture::running() const {
  return impl_->running();
}

}  // namespace clingfy::audio
