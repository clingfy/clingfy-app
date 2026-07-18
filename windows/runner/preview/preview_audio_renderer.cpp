#include "preview/preview_audio_renderer.h"

#include <audioclient.h>
#include <avrt.h>
#include <mmdeviceapi.h>
#include <mmreg.h>
#include <wrl/client.h>

#include <algorithm>
#include <atomic>
#include <cstring>
#include <deque>
#include <mutex>
#include <thread>
#include <utility>

#include "Audio/audio_format.h"
#include "Capture/Export/reorder_audio_pump.h"

namespace clingfy::preview {

namespace {

using Microsoft::WRL::ComPtr;
namespace exp = clingfy::capture::export_;

constexpr REFERENCE_TIME kHundredNanosPerMs = 10'000;
// Same shared-mode-safe buffer the capture side uses: short enough for a
// responsive pause/seek, long enough that an OS preempt never underruns.
constexpr REFERENCE_TIME kBufferDurationHns = 200 * kHundredNanosPerMs;
// The preview's PCM contract — matches the pump/export/endpoint pipeline
// format (Audio/audio_format.h; the endpoint mix format is verified against
// it in Open).
constexpr std::int64_t kSampleRateHz = clingfy::audio::kPipelineSampleRateHz;
constexpr std::uint32_t kChannels = clingfy::audio::kPipelineChannelCount;

class ScopedComInit {
 public:
  ScopedComInit() {
    const HRESULT hr = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    owns_ = SUCCEEDED(hr) && hr != S_FALSE;
  }
  ~ScopedComInit() {
    if (owns_) ::CoUninitialize();
  }
  ScopedComInit(const ScopedComInit&) = delete;
  ScopedComInit& operator=(const ScopedComInit&) = delete;

 private:
  bool owns_ = false;
};

std::int64_t MsToFrames(std::int64_t ms) {
  return (ms * kSampleRateHz) / 1000;  // truncates (§5.1)
}

std::int64_t FramesToMs(std::int64_t frames) {
  return (frames * 1000) / kSampleRateHz;  // truncates
}

}  // namespace

std::int64_t PreviewAudioRenderer::PlaybackEditedFrame(
    std::int64_t base_edited_frame, std::uint64_t submitted_frames,
    std::uint32_t padding_frames) {
  const std::uint64_t played =
      submitted_frames > padding_frames ? submitted_frames - padding_frames
                                        : 0;
  return base_edited_frame + static_cast<std::int64_t>(played);
}

std::int64_t PreviewAudioRenderer::PlanEndEditedFrame(
    const std::vector<capture::export_::clip_planner::AudioSlot>& slots) {
  if (slots.empty()) {
    return 0;
  }
  const auto& last = slots.back();
  return MsToFrames(last.edited_start_ms + last.duration_ms);
}

class PreviewAudioRenderer::Impl {
 public:
  bool Open(const std::wstring& source_path,
            const std::vector<exp::clip_planner::AudioSlot>& slots);
  void Close();

  void Play(std::int64_t edited_ms);
  void Pause();
  void SetSlots(const std::vector<exp::clip_planner::AudioSlot>& slots);
  void SetGainStages(const exp::AudioGainStages& stages);
  std::int64_t PositionEditedMs() const {
    return FramesToMs(position_edited_frame_.load(std::memory_order_relaxed));
  }
  bool playing() const { return playing_.load(std::memory_order_relaxed); }
  void SetOnRenderError(std::function<void(HRESULT)> callback) {
    on_render_error_ = std::move(callback);
  }

  ~Impl() { Close(); }

 private:
  enum class Command { kNone, kStartAt, kPause };

  void RenderLoop();
  void HandleStartAt(std::int64_t start_frame);
  // Refill the device buffer (clamped to the plan's real content so the
  // padding genuinely drains at EOS). Returns false on a device failure.
  bool FillDeviceBuffer(std::uint64_t epoch);
  // Ensure the FIFO holds at least `frames` frames, decoding via the pump;
  // silence inside the plan comes from the pump's own silence-fill, and any
  // decode shortfall is padded so the write below never blocks.
  void TopUpFifo(std::int64_t frames);
  void PublishPosition(std::uint64_t epoch, std::uint32_t padding_frames);
  void ReportRenderError(HRESULT hr);

  // --- Set once in Open, immutable afterwards -------------------------------
  std::wstring source_path_;
  ComPtr<IAudioClient> client_;
  ComPtr<IAudioRenderClient> render_client_;
  UINT32 buffer_frames_ = 0;
  HANDLE buffer_event_ = nullptr;
  HANDLE wake_event_ = nullptr;
  HANDLE stop_event_ = nullptr;
  std::thread thread_;

  // --- Guarded by mutex_ (brief holds ONLY — never across decode/WASAPI) ---
  std::mutex mutex_;
  exp::AudioGainStages stages_{};
  Command command_ = Command::kNone;
  std::int64_t command_start_frame_ = 0;
  // Clip edits defer the pump rebuild to the next Play transition, which
  // runs on the render thread: no mid-fill pump swap can ever occur, and
  // the MF reader open cost stays off the platform thread.
  std::vector<exp::clip_planner::AudioSlot> pending_slots_;
  bool slots_dirty_ = false;

  // --- Render-thread-only streaming state (no locks; Open runs before the
  // --- thread starts, Close joins before touching them) ---------------------
  std::unique_ptr<exp::ReorderAudioPump> pump_;
  std::deque<std::int16_t> fifo_;
  std::int64_t plan_end_frame_ = 0;
  std::int64_t base_edited_frame_ = 0;
  std::uint64_t submitted_frames_ = 0;
  bool streaming_ = false;

  // --- Atomics ---------------------------------------------------------------
  std::atomic<bool> running_{false};
  std::atomic<bool> playing_{false};
  std::atomic<std::int64_t> position_edited_frame_{0};
  // Bumped by every Play: a fill that started under an older epoch must not
  // publish its (old-stream) position over the freshly published target.
  std::atomic<std::uint64_t> play_epoch_{0};
  std::atomic<bool> render_error_reported_{false};
  std::function<void(HRESULT)> on_render_error_;
};

bool PreviewAudioRenderer::Impl::Open(
    const std::wstring& source_path,
    const std::vector<exp::clip_planner::AudioSlot>& slots) {
  source_path_ = source_path;
  // Identity stages at the pump — the live mix is applied at the FIFO fill
  // site instead (SetGainStages affects only future samples, D6).
  pump_ = exp::ReorderAudioPump::Create(source_path, slots, kSampleRateHz,
                                        kChannels, exp::AudioGainStages{});
  if (pump_ == nullptr) {
    return false;  // no audio track / reader failure — soft-fail (D7)
  }
  plan_end_frame_ = PlanEndEditedFrame(slots);

  ComPtr<IMMDeviceEnumerator> enumerator;
  HRESULT hr = ::CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                  CLSCTX_INPROC_SERVER,
                                  __uuidof(IMMDeviceEnumerator), &enumerator);
  if (FAILED(hr) || enumerator == nullptr) {
    return false;
  }
  ComPtr<IMMDevice> device;
  hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
  if (FAILED(hr) || device == nullptr) {
    return false;  // no output device — silent-video preview (D7)
  }
  hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, &client_);
  if (FAILED(hr) || client_ == nullptr) {
    return false;
  }

  WAVEFORMATEX* mix_format = nullptr;
  hr = client_->GetMixFormat(&mix_format);
  if (FAILED(hr) || mix_format == nullptr) {
    return false;
  }
  const bool compatible =
      clingfy::audio::IsPipelineCompatible(clingfy::audio::Snapshot(mix_format));
  if (!compatible) {
    // Non-48k/stereo/float endpoint: no resampler yet — same explicit
    // limitation the capture side ships with. Silent-video fallback.
    ::CoTaskMemFree(mix_format);
    return false;
  }
  hr = client_->Initialize(AUDCLNT_SHAREMODE_SHARED,
                           AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
                           kBufferDurationHns, 0, mix_format, nullptr);
  ::CoTaskMemFree(mix_format);
  if (FAILED(hr)) {
    return false;
  }
  if (FAILED(client_->GetBufferSize(&buffer_frames_)) || buffer_frames_ == 0) {
    return false;
  }

  buffer_event_ = ::CreateEventW(nullptr, FALSE, FALSE, nullptr);
  wake_event_ = ::CreateEventW(nullptr, FALSE, FALSE, nullptr);
  stop_event_ = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (buffer_event_ == nullptr || wake_event_ == nullptr ||
      stop_event_ == nullptr) {
    return false;
  }
  if (FAILED(client_->SetEventHandle(buffer_event_))) {
    return false;
  }
  hr = client_->GetService(__uuidof(IAudioRenderClient), &render_client_);
  if (FAILED(hr) || render_client_ == nullptr) {
    return false;
  }

  running_.store(true);
  thread_ = std::thread([this] { RenderLoop(); });
  return true;
}

void PreviewAudioRenderer::Impl::Close() {
  // Mirror WasapiAudioCapture::Stop ordering: flag, wake, join, THEN release
  // the client the loop was calling into.
  running_.store(false);
  playing_.store(false);
  if (stop_event_ != nullptr) {
    ::SetEvent(stop_event_);
  }
  if (thread_.joinable()) {
    thread_.join();
  }
  if (client_ != nullptr) {
    client_->Stop();
  }
  for (HANDLE* h : {&buffer_event_, &wake_event_, &stop_event_}) {
    if (*h != nullptr) {
      ::CloseHandle(*h);
      *h = nullptr;
    }
  }
  render_client_.Reset();
  client_.Reset();
  pump_.reset();  // render thread joined — safe without a lock
}

void PreviewAudioRenderer::Impl::Play(std::int64_t edited_ms) {
  const std::int64_t frame = MsToFrames(std::max<std::int64_t>(0, edited_ms));
  {
    std::lock_guard<std::mutex> lock(mutex_);
    command_ = Command::kStartAt;
    command_start_frame_ = frame;
  }
  // New epoch FIRST: an in-flight fill for the old stream sees the bump and
  // suppresses its position store, so the target published below survives
  // until the render thread's kStartAt transition re-publishes it.
  play_epoch_.fetch_add(1, std::memory_order_relaxed);
  position_edited_frame_.store(frame, std::memory_order_relaxed);
  playing_.store(true, std::memory_order_relaxed);
  if (wake_event_ != nullptr) {
    ::SetEvent(wake_event_);
  }
}

void PreviewAudioRenderer::Impl::Pause() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    command_ = Command::kPause;
  }
  playing_.store(false, std::memory_order_relaxed);
  if (wake_event_ != nullptr) {
    ::SetEvent(wake_event_);
  }
}

void PreviewAudioRenderer::Impl::SetSlots(
    const std::vector<exp::clip_planner::AudioSlot>& slots) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    pending_slots_ = slots;
    slots_dirty_ = true;
    command_ = Command::kPause;
  }
  playing_.store(false, std::memory_order_relaxed);
  if (wake_event_ != nullptr) {
    ::SetEvent(wake_event_);
  }
}

void PreviewAudioRenderer::Impl::SetGainStages(
    const exp::AudioGainStages& stages) {
  std::lock_guard<std::mutex> lock(mutex_);
  stages_ = stages;
}

void PreviewAudioRenderer::Impl::TopUpFifo(std::int64_t frames) {
  const std::size_t want_samples =
      static_cast<std::size_t>(frames) * kChannels;
  if (fifo_.size() >= want_samples) {
    return;
  }
  // The device needs the timeline decoded through this edited frame. The
  // target is FIXED for this call (the FIFO head sits at base + submitted).
  const std::int64_t limit_frame =
      base_edited_frame_ + static_cast<std::int64_t>(submitted_frames_) +
      frames;
  if (pump_ != nullptr && !pump_->done()) {
    exp::AudioGainStages stages;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      stages = stages_;
    }
    pump_->PumpUpTo(
        limit_frame,
        [this, &stages](clingfy::audio::MixedPacket&& packet,
                        std::int64_t /*edited_frame*/)
            -> std::optional<clingfy::encoding::EncoderError> {
          // Live mix at the fill site (D6) — the export's exact two-stage
          // clamp semantics, applied only to samples decoded from now on.
          exp::ApplyAudioGain(packet.samples.data(), packet.samples.size(),
                              stages);
          fifo_.insert(fifo_.end(), packet.samples.begin(),
                       packet.samples.end());
          return std::nullopt;
        });
  }
  if (fifo_.size() < want_samples) {
    // Decode shortfall (pump exhausted or cannot advance): pad so the write
    // never blocks. The FillDeviceBuffer clamp bounds this to the plan's
    // real extent, so synthetic padding never delays the EOS drain.
    fifo_.insert(fifo_.end(), want_samples - fifo_.size(), 0);
  }
}

void PreviewAudioRenderer::Impl::PublishPosition(std::uint64_t epoch,
                                                 std::uint32_t padding_frames) {
  if (play_epoch_.load(std::memory_order_relaxed) != epoch) {
    return;  // a newer Play published its target; don't clobber it
  }
  const std::int64_t at = std::min(
      PlaybackEditedFrame(base_edited_frame_, submitted_frames_,
                          padding_frames),
      plan_end_frame_);
  position_edited_frame_.store(at, std::memory_order_relaxed);
}

bool PreviewAudioRenderer::Impl::FillDeviceBuffer(std::uint64_t epoch) {
  UINT32 padding = 0;
  HRESULT hr = client_->GetCurrentPadding(&padding);
  if (FAILED(hr)) {
    ReportRenderError(hr);
    return false;
  }
  // Clamp to the plan's real content: past plan_end_frame_ nothing more is
  // written, the padding drains to zero within one buffer duration, and the
  // drain-out stop in the render loop can actually fire.
  const std::int64_t remaining_real = std::max<std::int64_t>(
      0, plan_end_frame_ - (base_edited_frame_ +
                            static_cast<std::int64_t>(submitted_frames_)));
  const UINT32 writable = static_cast<UINT32>(std::min<std::int64_t>(
      buffer_frames_ - padding, remaining_real));
  if (writable == 0) {
    PublishPosition(epoch, padding);
    return true;
  }

  TopUpFifo(writable);

  BYTE* out = nullptr;
  hr = render_client_->GetBuffer(writable, &out);
  if (FAILED(hr) || out == nullptr) {
    ReportRenderError(hr);
    return false;
  }
  auto* dst = reinterpret_cast<float*>(out);
  const std::size_t sample_count =
      static_cast<std::size_t>(writable) * kChannels;
  for (std::size_t i = 0; i < sample_count; ++i) {
    dst[i] = static_cast<float>(fifo_.front()) / 32768.0f;
    fifo_.pop_front();
  }
  hr = render_client_->ReleaseBuffer(writable, 0);
  if (FAILED(hr)) {
    ReportRenderError(hr);
    return false;
  }
  submitted_frames_ += writable;
  PublishPosition(epoch, padding + writable);
  return true;
}

void PreviewAudioRenderer::Impl::HandleStartAt(std::int64_t start_frame) {
  client_->Stop();
  client_->Reset();
  // A clip edit deferred its pump rebuild to this transition (render
  // thread — the MF reader open stays off the platform thread, and no
  // mid-fill pump swap can ever occur).
  bool rebuild = false;
  std::vector<exp::clip_planner::AudioSlot> slots;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (slots_dirty_) {
      rebuild = true;
      slots = std::move(pending_slots_);
      pending_slots_.clear();
      slots_dirty_ = false;
    }
  }
  if (rebuild) {
    pump_ = exp::ReorderAudioPump::Create(source_path_, slots, kSampleRateHz,
                                          kChannels, exp::AudioGainStages{});
    // nullptr (e.g. empty slots) leaves this session audio-less: the plan
    // end collapses to the start, so the stream drains immediately and
    // playing() flips false (D7 silent-video behavior).
    plan_end_frame_ = pump_ != nullptr ? PlanEndEditedFrame(slots) : 0;
  }
  fifo_.clear();
  if (pump_ != nullptr) {
    pump_->PrimeAtEditedFrame(start_frame);
  }
  base_edited_frame_ = start_frame;
  submitted_frames_ = 0;
  streaming_ = true;
  const std::uint64_t epoch = play_epoch_.load(std::memory_order_relaxed);
  if (!FillDeviceBuffer(epoch)) {
    streaming_ = false;
    playing_.store(false, std::memory_order_relaxed);
    return;
  }
  const HRESULT hr = client_->Start();
  if (FAILED(hr)) {
    ReportRenderError(hr);
    streaming_ = false;
    playing_.store(false, std::memory_order_relaxed);
  }
}

void PreviewAudioRenderer::Impl::RenderLoop() {
  ScopedComInit com_init;
  DWORD task_index = 0;
  HANDLE mmcss = ::AvSetMmThreadCharacteristicsW(L"Pro Audio", &task_index);

  HANDLE waits[3] = {stop_event_, wake_event_, buffer_event_};
  while (running_.load()) {
    const DWORD wait = ::WaitForMultipleObjects(3, waits, FALSE, 500);
    if (!running_.load() || wait == WAIT_OBJECT_0) {
      break;  // stop_event_
    }
    if (wait == WAIT_TIMEOUT) {
      continue;
    }

    // Transport command (posted by Play/Pause/SetSlots on the platform
    // thread).
    Command command = Command::kNone;
    std::int64_t start_frame = 0;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      command = command_;
      start_frame = command_start_frame_;
      command_ = Command::kNone;
    }
    if (command == Command::kStartAt) {
      HandleStartAt(start_frame);
      continue;
    }
    if (command == Command::kPause) {
      client_->Stop();
      streaming_ = false;
      continue;
    }

    if (wait == WAIT_OBJECT_0 + 2 && streaming_) {
      const std::uint64_t epoch = play_epoch_.load(std::memory_order_relaxed);
      if (!FillDeviceBuffer(epoch)) {
        client_->Stop();
        streaming_ = false;
        playing_.store(false, std::memory_order_relaxed);
        continue;
      }
      // Drain-out: everything real has been submitted AND played. The fill
      // clamp stopped writing at the plan end, so the padding genuinely
      // decays to zero within one buffer duration.
      const bool plan_exhausted =
          base_edited_frame_ + static_cast<std::int64_t>(submitted_frames_) >=
          plan_end_frame_;
      if (plan_exhausted) {
        UINT32 padding = 0;
        if (SUCCEEDED(client_->GetCurrentPadding(&padding)) && padding == 0) {
          client_->Stop();
          streaming_ = false;
          playing_.store(false, std::memory_order_relaxed);
          PublishPosition(epoch, 0);
        }
      }
    }
  }

  if (mmcss != nullptr) {
    ::AvRevertMmThreadCharacteristics(mmcss);
  }
}

void PreviewAudioRenderer::Impl::ReportRenderError(HRESULT hr) {
  if (render_error_reported_.exchange(true)) {
    return;
  }
  if (on_render_error_) {
    on_render_error_(hr);
  }
}

// ---- Public forwarding ------------------------------------------------------

PreviewAudioRenderer::PreviewAudioRenderer() : impl_(std::make_unique<Impl>()) {}

PreviewAudioRenderer::~PreviewAudioRenderer() = default;

std::unique_ptr<PreviewAudioRenderer> PreviewAudioRenderer::Open(
    const std::wstring& source_path,
    const std::vector<capture::export_::clip_planner::AudioSlot>& slots) {
  auto renderer =
      std::unique_ptr<PreviewAudioRenderer>(new PreviewAudioRenderer());
  if (!renderer->impl_->Open(source_path, slots)) {
    return nullptr;
  }
  return renderer;
}

void PreviewAudioRenderer::Play(std::int64_t edited_ms) {
  impl_->Play(edited_ms);
}

void PreviewAudioRenderer::Pause() { impl_->Pause(); }

void PreviewAudioRenderer::SetSlots(
    const std::vector<capture::export_::clip_planner::AudioSlot>& slots) {
  impl_->SetSlots(slots);
}

void PreviewAudioRenderer::SetGainStages(
    const capture::export_::AudioGainStages& stages) {
  impl_->SetGainStages(stages);
}

std::int64_t PreviewAudioRenderer::PositionEditedMs() const {
  return impl_->PositionEditedMs();
}

bool PreviewAudioRenderer::playing() const { return impl_->playing(); }

void PreviewAudioRenderer::SetOnRenderError(
    std::function<void(HRESULT)> callback) {
  impl_->SetOnRenderError(std::move(callback));
}

}  // namespace clingfy::preview
