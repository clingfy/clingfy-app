#include "Capture/video_frame_queue.h"

namespace clingfy::capture {

VideoFrameQueue::VideoFrameQueue(std::size_t capacity)
    : capacity_(capacity == 0 ? 1 : capacity) {}

bool VideoFrameQueue::Push(CapturedVideoFrame frame) {
  bool accepted_without_drop = true;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (frames_.size() >= capacity_) {
      // Drop the oldest frame so the latest one is always in the queue.
      // Phase 3B has no consumer, so this happens every ~60 frames; once
      // Phase 3C wires the encoder the drop count should idle at 0 under
      // normal load.
      frames_.pop_front();
      ++dropped_;
      accepted_without_drop = false;
    }
    frames_.push_back(std::move(frame));
    ++total_;
  }
  cv_.notify_one();
  return accepted_without_drop;
}

std::optional<CapturedVideoFrame> VideoFrameQueue::Pop() {
  std::unique_lock<std::mutex> lock(mutex_);
  cv_.wait(lock, [this] { return !frames_.empty() || closed_; });
  if (frames_.empty()) {
    return std::nullopt;
  }
  CapturedVideoFrame frame = std::move(frames_.front());
  frames_.pop_front();
  return frame;
}

std::optional<CapturedVideoFrame> VideoFrameQueue::TryPop() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (frames_.empty()) {
    return std::nullopt;
  }
  CapturedVideoFrame frame = std::move(frames_.front());
  frames_.pop_front();
  return frame;
}

void VideoFrameQueue::Close() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    closed_ = true;
  }
  cv_.notify_all();
}

bool VideoFrameQueue::closed() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return closed_;
}

std::size_t VideoFrameQueue::size() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return frames_.size();
}

std::uint64_t VideoFrameQueue::dropped_frame_count() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return dropped_;
}

std::uint64_t VideoFrameQueue::total_frame_count() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return total_;
}

}  // namespace clingfy::capture
