#ifndef RUNNER_AUDIO_AUDIO_PACKET_QUEUE_H_
#define RUNNER_AUDIO_AUDIO_PACKET_QUEUE_H_

#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <mutex>
#include <optional>

#include "Audio/audio_packet.h"

// Bounded thread-safe queue between a WASAPI capture thread (producer)
// and the mixer thread (consumer).
//
// Mirrors `VideoFrameQueue`'s drop-oldest contract so a slow mixer
// cannot blow up host memory. Audio packets are smaller than video
// frames (one 10ms stereo float32 packet ≈ 3.7 KiB) so the default
// capacity is correspondingly larger — 200 packets is two full seconds
// of buffered audio.
namespace clingfy::audio {

class AudioPacketQueue {
 public:
  explicit AudioPacketQueue(std::size_t capacity = 200);

  // Returns true if the packet was accepted without a drop; false if
  // the queue was at capacity and the oldest packet was evicted.
  bool Push(AudioPacket packet);

  // Blocks until a packet is available or Close() is called. Returns
  // std::nullopt when the queue is closed and drained.
  std::optional<AudioPacket> Pop();

  // Non-blocking variant for the mixer's "drain when stopping" pass.
  std::optional<AudioPacket> TryPop();

  void Close();
  bool closed() const;

  std::size_t size() const;
  std::uint64_t dropped_packet_count() const;
  std::uint64_t total_packet_count() const;

 private:
  std::size_t capacity_;
  mutable std::mutex mutex_;
  std::condition_variable cv_;
  std::deque<AudioPacket> packets_;
  std::uint64_t dropped_ = 0;
  std::uint64_t total_ = 0;
  bool closed_ = false;
};

}  // namespace clingfy::audio

#endif  // RUNNER_AUDIO_AUDIO_PACKET_QUEUE_H_
