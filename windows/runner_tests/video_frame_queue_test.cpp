#include "Capture/video_frame_queue.h"

#include <gtest/gtest.h>

#include <chrono>
#include <future>
#include <thread>

namespace clingfy::capture {
namespace {

CapturedVideoFrame MakeFrame(std::uint32_t w, std::uint32_t h,
                             std::int64_t ts) {
  CapturedVideoFrame frame;
  frame.width = w;
  frame.height = h;
  frame.timestamp_hns = ts;
  // Texture intentionally null — Phase 3B does not populate it, and the
  // queue contract is texture-agnostic.
  return frame;
}

TEST(VideoFrameQueueTest, PushPopRoundTripsMetadata) {
  VideoFrameQueue queue(/*capacity=*/4);
  EXPECT_TRUE(queue.Push(MakeFrame(1920, 1080, 1'000)));
  EXPECT_TRUE(queue.Push(MakeFrame(1920, 1080, 2'000)));
  EXPECT_EQ(queue.size(), 2u);
  EXPECT_EQ(queue.dropped_frame_count(), 0u);
  EXPECT_EQ(queue.total_frame_count(), 2u);

  auto first = queue.TryPop();
  ASSERT_TRUE(first.has_value());
  EXPECT_EQ(first->timestamp_hns, 1'000);
  auto second = queue.TryPop();
  ASSERT_TRUE(second.has_value());
  EXPECT_EQ(second->timestamp_hns, 2'000);
  EXPECT_FALSE(queue.TryPop().has_value());
}

TEST(VideoFrameQueueTest, PushPastCapacityDropsOldest) {
  VideoFrameQueue queue(/*capacity=*/2);
  EXPECT_TRUE(queue.Push(MakeFrame(0, 0, 1)));
  EXPECT_TRUE(queue.Push(MakeFrame(0, 0, 2)));
  // Third push exceeds capacity — must drop oldest (timestamp 1) and
  // accept the new frame.
  EXPECT_FALSE(queue.Push(MakeFrame(0, 0, 3)));
  EXPECT_EQ(queue.size(), 2u);
  EXPECT_EQ(queue.dropped_frame_count(), 1u);
  EXPECT_EQ(queue.total_frame_count(), 3u);

  auto first = queue.TryPop();
  ASSERT_TRUE(first.has_value());
  EXPECT_EQ(first->timestamp_hns, 2)
      << "Drop should evict the oldest frame so the queue's contents stay "
         "fresh — encoders care more about latency than completeness.";
  auto second = queue.TryPop();
  ASSERT_TRUE(second.has_value());
  EXPECT_EQ(second->timestamp_hns, 3);
}

TEST(VideoFrameQueueTest, ZeroCapacityFallsBackToOne) {
  // Defensive: a misconfigured queue must not divide-by-zero or assert —
  // it just behaves as a 1-deep ring buffer.
  VideoFrameQueue queue(/*capacity=*/0);
  EXPECT_TRUE(queue.Push(MakeFrame(0, 0, 1)));
  EXPECT_FALSE(queue.Push(MakeFrame(0, 0, 2)));  // Dropped first, accepted.
  auto out = queue.TryPop();
  ASSERT_TRUE(out.has_value());
  EXPECT_EQ(out->timestamp_hns, 2);
}

TEST(VideoFrameQueueTest, CloseUnblocksWaitingConsumer) {
  VideoFrameQueue queue;
  auto consumer = std::async(std::launch::async, [&] { return queue.Pop(); });
  // Give the consumer a moment to enter the cv_.wait — without this the
  // test could race-by-luck on a single-core scheduler.
  std::this_thread::sleep_for(std::chrono::milliseconds(10));
  queue.Close();
  auto result = consumer.get();
  EXPECT_FALSE(result.has_value())
      << "Close() must wake blocked Pop() callers with std::nullopt so the "
         "consumer thread can exit cleanly.";
  EXPECT_TRUE(queue.closed());
}

TEST(VideoFrameQueueTest, ClosedQueueDrainsRemainingFramesThenReturnsNullopt) {
  VideoFrameQueue queue;
  queue.Push(MakeFrame(0, 0, 1));
  queue.Push(MakeFrame(0, 0, 2));
  queue.Close();
  auto first = queue.Pop();
  ASSERT_TRUE(first.has_value());
  EXPECT_EQ(first->timestamp_hns, 1);
  auto second = queue.Pop();
  ASSERT_TRUE(second.has_value());
  EXPECT_EQ(second->timestamp_hns, 2);
  auto third = queue.Pop();
  EXPECT_FALSE(third.has_value());
}

TEST(VideoFrameQueueTest, ProducerConsumerHandoff) {
  // Capacity sized to comfortably hold every push so this test only
  // exercises the cv_ handoff, NOT the drop path (`PushPastCapacityDrops-
  // Oldest` already pins that). Close() at the end wakes the consumer's
  // final Pop call regardless of timing — without that, a fast producer
  // that empties the queue before the consumer asks could leave the
  // consumer waiting on cv_ forever.
  VideoFrameQueue queue(/*capacity=*/256);
  constexpr int kFrameCount = 100;

  auto consumer = std::async(std::launch::async, [&] {
    int collected = 0;
    while (auto frame = queue.Pop()) {
      collected += 1;
    }
    return collected;
  });

  for (int i = 0; i < kFrameCount; ++i) {
    queue.Push(MakeFrame(0, 0, i));
  }
  queue.Close();
  EXPECT_EQ(consumer.get(), kFrameCount);
}

}  // namespace
}  // namespace clingfy::capture
