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
#include "Audio/wasapi_stream_format.h"
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
  // One decoded input track. Legacy premix sessions have exactly one spec
  // (flagged is_mic so it rides the merge's always-present slot);
  // separated sessions (D9) have one per decodable sidecar.
  struct TrackSpec {
    std::wstring path;
    bool is_mic = false;  // selects the separated stage + the merge slot
  };

  bool Open(std::vector<TrackSpec> specs, bool separated,
            const std::vector<exp::clip_planner::AudioSlot>& slots);
  void Close();

  void Play(std::int64_t edited_ms);
  void Pause();
  void SetSlots(const std::vector<exp::clip_planner::AudioSlot>& slots);
  void SetGainStages(const exp::AudioGainStages& stages);
  void SetSeparatedGainStages(const exp::SeparatedAudioStages& stages);
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
  // Ensure the FIFO holds at least `frames` frames, decoding via the
  // pump(s); silence inside the plan comes from the pump's own
  // silence-fill, and any decode shortfall is padded so the write below
  // never blocks. Separated sessions decode BOTH tracks to the same limit
  // and move the merge-ready (min-prefix) summed frames into the FIFO.
  void TopUpFifo(std::int64_t frames);
  void PublishPosition(std::uint64_t epoch, std::uint32_t padding_frames);
  void ReportRenderError(HRESULT hr);
  // (Re)build one pump per track spec from `slots` and reset the merge to
  // the LIVE tracks (a track whose pump failed must not gate readiness).
  // Render-thread-only after Open. Returns true when any pump is alive.
  bool RebuildPumps(const std::vector<exp::clip_planner::AudioSlot>& slots);

  // --- Set once in Open, immutable afterwards -------------------------------
  std::vector<TrackSpec> track_specs_;
  bool separated_ = false;
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
  // Separated live mix (D9): the per-track pair, used when separated_.
  exp::SeparatedAudioStages separated_stages_{};
  Command command_ = Command::kNone;
  std::int64_t command_start_frame_ = 0;
  // Clip edits defer the pump rebuild to the next Play transition, which
  // runs on the render thread: no mid-fill pump swap can ever occur, and
  // the MF reader open cost stays off the platform thread.
  std::vector<exp::clip_planner::AudioSlot> pending_slots_;
  bool slots_dirty_ = false;

  // --- Render-thread-only streaming state (no locks; Open runs before the
  // --- thread starts, Close joins before touching them) ---------------------
  // Parallel to track_specs_; a failed create leaves a null slot (the track
  // drops — export soft-fail parity).
  std::vector<std::unique_ptr<exp::ReorderAudioPump>> pumps_;
  // The min-prefix merge across the LIVE tracks (single-track sessions pass
  // through). Reconstructed by RebuildPumps and on every re-prime so no
  // stale skew survives a seek.
  std::optional<exp::SeparatedAudioMerge> merge_;
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

bool PreviewAudioRenderer::Impl::RebuildPumps(
    const std::vector<exp::clip_planner::AudioSlot>& slots) {
  // Identity stages at the pump — the live mix is applied at the FIFO fill
  // site instead (SetGainStages affects only future samples, D6).
  pumps_.clear();
  bool mic_live = false;
  bool system_live = false;
  for (const auto& spec : track_specs_) {
    auto pump = exp::ReorderAudioPump::Create(spec.path, slots, kSampleRateHz,
                                              kChannels,
                                              exp::AudioGainStages{});
    if (pump != nullptr) {
      (spec.is_mic ? mic_live : system_live) = true;
    }
    pumps_.push_back(std::move(pump));
  }
  if (!mic_live && !system_live) {
    merge_.reset();
    return false;
  }
  // The merge gates on the LIVE tracks only — a dropped track must not
  // stall readiness at zero forever.
  merge_.emplace(mic_live, system_live, kChannels);
  return true;
}

bool PreviewAudioRenderer::Impl::Open(
    std::vector<TrackSpec> specs, bool separated,
    const std::vector<exp::clip_planner::AudioSlot>& slots) {
  track_specs_ = std::move(specs);
  separated_ = separated;
  if (!RebuildPumps(slots)) {
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
  // A non-48 kHz/stereo/float endpoint used to end the preview's audio here:
  // it returned false and the session played as silent video, and unlike the
  // capture side there was no user-visible notice at all — just a Warn on the
  // diagnostics rail. The audio engine now resamples for us. Everything below
  // keeps assuming 48 kHz float32 stereo, which stays true because the
  // APP-side format is canonical whichever branch runs.
  const clingfy::audio::SharedStreamInit init =
      clingfy::audio::InitializeSharedStream(client_.Get(),
                                             AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
                                             kBufferDurationHns, mix_format);
  ::CoTaskMemFree(mix_format);
  if (FAILED(init.hr)) {
    return false;  // still soft-fail to silent video (D7)
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
  pumps_.clear();  // render thread joined — safe without a lock
  merge_.reset();
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

void PreviewAudioRenderer::Impl::SetSeparatedGainStages(
    const exp::SeparatedAudioStages& stages) {
  std::lock_guard<std::mutex> lock(mutex_);
  separated_stages_ = stages;
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
  exp::AudioGainStages legacy_stages;
  exp::SeparatedAudioStages pair;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    legacy_stages = stages_;
    pair = separated_stages_;
  }
  // Decode every live track to the SAME limit; per-track stages apply at
  // the fill site (D6 — future samples only). Both pumps run the same plan
  // so their totals agree at every limit; the merge FIFOs absorb packet-
  // boundary skew and release only the min-prefix, summed (D9).
  for (std::size_t i = 0; i < pumps_.size(); ++i) {
    auto* pump = pumps_[i].get();
    if (pump == nullptr || pump->done()) {
      continue;
    }
    const bool is_mic = track_specs_[i].is_mic;
    const exp::AudioGainStages& stages =
        separated_ ? (is_mic ? pair.mic : pair.system) : legacy_stages;
    pump->PumpUpTo(
        limit_frame,
        [this, &stages, is_mic](clingfy::audio::MixedPacket&& packet,
                                std::int64_t /*edited_frame*/)
            -> std::optional<clingfy::encoding::EncoderError> {
          // Live mix at the fill site (D6) — the export's exact two-stage
          // clamp semantics, applied only to samples decoded from now on.
          exp::ApplyAudioGain(packet.samples.data(), packet.samples.size(),
                              stages);
          if (is_mic) {
            merge_->AppendMic(packet.samples.data(), packet.frame_count);
          } else {
            merge_->AppendSystem(packet.samples.data(), packet.frame_count);
          }
          return std::nullopt;
        });
  }
  if (merge_.has_value() && merge_->ReadyFrames() > 0) {
    std::vector<std::int16_t> merged;
    merge_->PopMerged(merge_->ReadyFrames(), merged);
    fifo_.insert(fifo_.end(), merged.begin(), merged.end());
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
    // No live pump (e.g. empty slots) leaves this session audio-less: the
    // plan end collapses to the start, so the stream drains immediately and
    // playing() flips false (D7 silent-video behavior).
    plan_end_frame_ = RebuildPumps(slots) ? PlanEndEditedFrame(slots) : 0;
  } else if (merge_.has_value()) {
    // Re-prime without a rebuild: drop EVERYTHING buffered in the merge —
    // including the unmatched skew PopMerged never releases — so no stale
    // pre-seek sample can be summed against post-seek data.
    merge_->Clear();
  }
  fifo_.clear();
  for (auto& pump : pumps_) {
    if (pump != nullptr) {
      pump->PrimeAtEditedFrame(start_frame);
    }
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
  if (source_path.empty()) {
    return nullptr;
  }
  auto renderer =
      std::unique_ptr<PreviewAudioRenderer>(new PreviewAudioRenderer());
  // The single premix track rides the merge's mic slot (pass-through).
  if (!renderer->impl_->Open({{source_path, /*is_mic=*/true}},
                             /*separated=*/false, slots)) {
    return nullptr;
  }
  return renderer;
}

std::unique_ptr<PreviewAudioRenderer> PreviewAudioRenderer::OpenSeparated(
    const std::wstring& mic_path, const std::wstring& system_path,
    const std::vector<capture::export_::clip_planner::AudioSlot>& slots) {
  std::vector<Impl::TrackSpec> specs;
  if (!mic_path.empty()) {
    specs.push_back({mic_path, /*is_mic=*/true});
  }
  if (!system_path.empty()) {
    specs.push_back({system_path, /*is_mic=*/false});
  }
  if (specs.empty()) {
    return nullptr;
  }
  auto renderer =
      std::unique_ptr<PreviewAudioRenderer>(new PreviewAudioRenderer());
  if (!renderer->impl_->Open(std::move(specs), /*separated=*/true, slots)) {
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

void PreviewAudioRenderer::SetSeparatedGainStages(
    const capture::export_::SeparatedAudioStages& stages) {
  impl_->SetSeparatedGainStages(stages);
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
