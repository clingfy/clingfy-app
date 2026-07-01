#ifndef RUNNER_CAPTURE_VIDEO_FRAME_QUEUE_H_
#define RUNNER_CAPTURE_VIDEO_FRAME_QUEUE_H_

#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <mutex>
#include <optional>

#include "Capture/captured_video_frame.h"

// Bounded thread-safe queue between the WGC capture callback (producer) and
// the encoder pump (consumer).
//
// Capture callbacks fire on a WGC thread-pool thread; the encoder thread —
// when Phase 3C lands — will block on `Pop` waiting for the next frame.
// The queue is bounded so a slow encoder can't blow up host memory; once
// the cap is hit, the oldest frame is dropped and `dropped_frame_count`
// increments so diagnostics can surface the issue.
namespace clingfy::capture {

class VideoFrameQueue {
 public:
  // `capacity` is the maximum number of frames buffered before drops start.
  // 60 is enough for one second at 60 fps, which is the longest stall the
  // encoder should tolerate without being considered "broken".
  explicit VideoFrameQueue(std::size_t capacity = 60);

  // Producer: enqueue a frame. Returns true if the frame was accepted,
  // false if the queue was at capacity and the oldest frame was dropped to
  // make room. Either way the new frame ends up in the queue.
  bool Push(CapturedVideoFrame frame);

  // Consumer: block until a frame is available, then move it out. Returns
  // std::nullopt if `Close()` was called while waiting — the consumer
  // treats that as a clean shutdown signal.
  std::optional<CapturedVideoFrame> Pop();

  // Consumer: non-blocking pop. Returns std::nullopt if no frame is
  // available right now (used by the encoder pump's "drain remaining
  // frames before finalize" pass).
  std::optional<CapturedVideoFrame> TryPop();

  // Wakes any blocked `Pop` callers and rejects future producers. After
  // close, `Push` continues to accept frames (so the capture callback that
  // arrives a few microseconds after stop does not assert), but `Pop`
  // returns the remaining buffered frames and then `std::nullopt`.
  void Close();
  bool closed() const;

  std::size_t size() const;
  std::uint64_t dropped_frame_count() const;
  std::uint64_t total_frame_count() const;

 private:
  std::size_t capacity_;
  mutable std::mutex mutex_;
  std::condition_variable cv_;
  std::deque<CapturedVideoFrame> frames_;
  std::uint64_t dropped_ = 0;
  std::uint64_t total_ = 0;
  bool closed_ = false;
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_VIDEO_FRAME_QUEUE_H_
