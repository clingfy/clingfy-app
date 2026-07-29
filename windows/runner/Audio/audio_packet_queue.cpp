#include "Audio/audio_packet_queue.h"

#include <utility>

namespace clingfy::audio {

AudioPacketQueue::AudioPacketQueue(std::size_t capacity)
    : capacity_(capacity == 0 ? 1 : capacity) {}

bool AudioPacketQueue::Push(AudioPacket packet) {
  bool accepted = true;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (packets_.size() >= capacity_) {
      packets_.pop_front();
      ++dropped_;
      accepted = false;
    }
    packets_.push_back(std::move(packet));
    ++total_;
  }
  cv_.notify_one();
  return accepted;
}

std::optional<AudioPacket> AudioPacketQueue::Pop() {
  std::unique_lock<std::mutex> lock(mutex_);
  cv_.wait(lock, [this] { return !packets_.empty() || closed_; });
  if (packets_.empty()) {
    return std::nullopt;
  }
  AudioPacket front = std::move(packets_.front());
  packets_.pop_front();
  return front;
}

AudioPacketQueue::PopStatus AudioPacketQueue::PopFor(
    std::chrono::milliseconds timeout, AudioPacket& out) {
  std::unique_lock<std::mutex> lock(mutex_);
  // The predicate form handles spurious wakes: a packet arriving late in the
  // window is still returned rather than reported as a timeout. The return
  // value is not needed — the state below is authoritative either way.
  cv_.wait_for(lock, timeout, [this] {
    return !packets_.empty() || closed_;
  });
  if (!packets_.empty()) {
    out = std::move(packets_.front());
    packets_.pop_front();
    return PopStatus::kPacket;
  }
  // Drained AND closed is terminal; drained but open is just quiet. Checking
  // `closed_` before `ready` matters: a close that lands exactly on the
  // deadline must report kClosed, not kTimeout, or the caller keeps waiting on
  // a producer that is gone.
  if (closed_) {
    return PopStatus::kClosed;
  }
  return PopStatus::kTimeout;
}

std::optional<AudioPacket> AudioPacketQueue::TryPop() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (packets_.empty()) {
    return std::nullopt;
  }
  AudioPacket front = std::move(packets_.front());
  packets_.pop_front();
  return front;
}

void AudioPacketQueue::Close() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    closed_ = true;
  }
  cv_.notify_all();
}

bool AudioPacketQueue::closed() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return closed_;
}

std::size_t AudioPacketQueue::size() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return packets_.size();
}

std::uint64_t AudioPacketQueue::dropped_packet_count() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return dropped_;
}

std::uint64_t AudioPacketQueue::total_packet_count() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return total_;
}

}  // namespace clingfy::audio
