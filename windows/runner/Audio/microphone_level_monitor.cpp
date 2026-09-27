#include "Audio/microphone_level_monitor.h"

#include <chrono>
#include <cstdio>
#include <utility>

#include "Bridge/device_event_publisher.h"
#include "Bridge/Devices/device_probe_log.h"

namespace clingfy::audio {
namespace {

// How long the consumer waits for a packet before checking its own state.
//
// Shorter than the emit interval on purpose: the wait is what paces the loop
// when the device stops delivering, and it has to come back often enough that
// a starved window still reports on time. It also bounds how long Stop()
// waits for the thread to notice.
constexpr auto kPollTimeout = std::chrono::milliseconds(20);

}  // namespace

bool ShouldMonitorMicrophoneLevel(const std::optional<std::string>& selected_id,
                                  bool recording) {
  if (recording) {
    return false;
  }
  // An empty string is how the router represents "cleared", the same as a
  // missing value -- `ReadOptionalString` maps "" to nullopt, but a caller
  // reading straight from selection state can still hand one over.
  return selected_id.has_value() && !selected_id->empty();
}

MicrophoneLevelMonitor& MicrophoneLevelMonitor::Instance() {
  static MicrophoneLevelMonitor instance;
  return instance;
}

MicrophoneLevelMonitor::MicrophoneLevelMonitor() = default;

MicrophoneLevelMonitor::~MicrophoneLevelMonitor() { Stop(false); }

void MicrophoneLevelMonitor::SetEmitterForTesting(Emitter emitter) {
  std::lock_guard<std::mutex> lock(mutex_);
  emitter_ = std::move(emitter);
}

bool MicrophoneLevelMonitor::running() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return running_;
}

std::string MicrophoneLevelMonitor::device_id() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return device_id_;
}

void MicrophoneLevelMonitor::Apply(const std::optional<std::string>& selected_id,
                                   bool recording) {
  if (!ShouldMonitorMicrophoneLevel(selected_id, recording)) {
    Stop(/*emit_silence=*/true);
    return;
  }
  Start(*selected_id);
}

void MicrophoneLevelMonitor::Start(const std::string& device_id) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (running_ && device_id_ == device_id && !capture_failed_.load()) {
      return;  // already metering this endpoint
    }
  }

  // Outside the lock: Stop() joins threads, and those threads call Emit(),
  // which takes this same non-recursive mutex. Holding it across the join is
  // the self-inflicted deadlock this codebase has already paid for once.
  Stop(/*emit_silence=*/false);

  auto queue = std::make_unique<AudioPacketQueue>();
  auto capture = std::make_unique<WasapiAudioCapture>();
  capture_failed_.store(false);
  capture->SetOnCaptureError([this](WasapiCaptureKind, HRESULT) {
    // Runs ON the capture thread. Flag only -- see the member comment.
    capture_failed_.store(true);
  });

  if (capture->Start(WasapiCaptureKind::kMicrophone, device_id, *queue)) {
    // Opening the endpoint failed outright (missing, in exclusive use by
    // another app, permission denied). Report the floor so the meter shows
    // something honest rather than nothing, but do NOT flag it low: we have
    // no reading, and the UI has its own surface for a device that will not
    // open.
    clingfy::bridge::devices::LogDeviceProbe(
        "MicrophoneLevelMonitor: could not open the selected input; meter "
        "stays at the floor");
    Emit(SilentMicrophoneLevel());
    return;
  }

  {
    std::lock_guard<std::mutex> lock(mutex_);
    logged_low_ = false;
    queue_ = std::move(queue);
    capture_ = std::move(capture);
    device_id_ = device_id;
    running_ = true;
  }
  clingfy::bridge::devices::LogDeviceProbe(
      "MicrophoneLevelMonitor: metering the selected input");
  consumer_ = std::thread([this] { ConsumeLoop(); });
}

void MicrophoneLevelMonitor::Stop(bool emit_silence) {
  std::unique_ptr<AudioPacketQueue> queue;
  std::unique_ptr<WasapiAudioCapture> capture;
  bool was_running = false;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    was_running = running_;
    running_ = false;
    device_id_.clear();
    queue = std::move(queue_);
    capture = std::move(capture_);
  }

  // Unblock the consumer before joining it, or the join waits out a full
  // PopFor timeout for nothing.
  if (queue) {
    queue->Close();
  }
  if (consumer_.joinable()) {
    consumer_.join();
  }
  if (capture) {
    capture->Stop();
  }

  // Only after everything is down, and only if there was something to stop --
  // a Stop on an idle monitor should not push a reading at all, or every
  // startup would emit one.
  if (emit_silence && was_running) {
    Emit(SilentMicrophoneLevel());
  }
}

void MicrophoneLevelMonitor::ConsumeLoop() {
  AudioPacketQueue* queue = nullptr;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    queue = queue_.get();
  }
  if (queue == nullptr) {
    return;
  }

  MicrophoneLevelAccumulator accumulator;
  while (!capture_failed_.load()) {
    AudioPacket packet;
    const auto status = queue->PopFor(kPollTimeout, packet);
    if (status == AudioPacketQueue::PopStatus::kClosed) {
      break;
    }
    if (status == AudioPacketQueue::PopStatus::kPacket) {
      // A packet WASAPI flagged silent carries whatever was left in the
      // buffer, so fold zeros rather than its contents -- but do fold, since
      // a run of silent buffers is exactly the dead-microphone case the
      // warning is for, and skipping them would leave the peak stale.
      if (!packet.silent) {
        accumulator.Add(packet.samples.data(), packet.samples.size());
      }
    }
    // Runs on a timeout too: that is what makes a microphone that has stopped
    // delivering read as silent instead of freezing.
    if (const auto level =
            accumulator.TakeIfDue(std::chrono::steady_clock::now())) {
      NoteIfQuiet(*level);
      Emit(*level);
    }
  }

  if (capture_failed_.load()) {
    // The endpoint died mid-session (unplug, driver reset). Drop the meter to
    // the floor; the teardown itself waits for a Stop or the next Apply,
    // because joining the capture thread from here would be joining ourselves
    // out of a callback it raised.
    clingfy::bridge::devices::LogDeviceProbe(
        "MicrophoneLevelMonitor: the input endpoint failed mid-session; "
        "meter dropped to the floor");
    Emit(SilentMicrophoneLevel());
  }
}

void MicrophoneLevelMonitor::NoteIfQuiet(const MicrophoneLevel& level) {
  if (!level.is_low) {
    return;
  }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (logged_low_) {
      return;
    }
    logged_low_ = true;
  }
  // Worth a line because this is the state a user does not notice until the
  // recording is over. The support thread that produced this whole feature
  // was a microphone sitting at -50 dBFS, and nothing in the logs said so.
  char buf[160];
  std::snprintf(buf, sizeof(buf),
                "MicrophoneLevelMonitor: input is very quiet (%.1f dBFS, "
                "warning threshold %.1f)",
                level.dbfs, kMicLevelLowDbfs);
  clingfy::bridge::devices::LogDeviceProbe(buf);
}

void MicrophoneLevelMonitor::Emit(const MicrophoneLevel& level) {
  Emitter emitter;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    emitter = emitter_;
  }
  if (emitter) {
    emitter(level);
    return;
  }
  clingfy::bridge::DeviceEventPublisher::Instance().EmitMicrophoneLevel(
      level.linear, level.dbfs, level.is_low);
}

}  // namespace clingfy::audio
