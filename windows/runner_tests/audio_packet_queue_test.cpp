#include "Audio/audio_packet_queue.h"

#include <gtest/gtest.h>

#include <chrono>
#include <future>
#include <thread>

namespace clingfy::audio {
namespace {

AudioPacket MakePacket(std::uint32_t frames, std::int64_t ts,
                       bool silent = false) {
  AudioPacket packet;
  packet.frame_count = frames;
  packet.timestamp_hns = ts;
  packet.silent = silent;
  packet.samples.assign(static_cast<std::size_t>(frames) * 2, 0.5f);
  return packet;
}

TEST(AudioPacketQueueTest, PushPopRoundTrip) {
  AudioPacketQueue queue(/*capacity=*/4);
  EXPECT_TRUE(queue.Push(MakePacket(480, 1000)));
  EXPECT_TRUE(queue.Push(MakePacket(480, 2000)));
  EXPECT_EQ(queue.size(), 2u);
  EXPECT_EQ(queue.total_packet_count(), 2u);

  auto first = queue.TryPop();
  ASSERT_TRUE(first.has_value());
  EXPECT_EQ(first->timestamp_hns, 1000);
  auto second = queue.TryPop();
  ASSERT_TRUE(second.has_value());
  EXPECT_EQ(second->timestamp_hns, 2000);
}

TEST(AudioPacketQueueTest, PushOverflowDropsOldest) {
  AudioPacketQueue queue(/*capacity=*/2);
  EXPECT_TRUE(queue.Push(MakePacket(480, 1)));
  EXPECT_TRUE(queue.Push(MakePacket(480, 2)));
  EXPECT_FALSE(queue.Push(MakePacket(480, 3)));
  EXPECT_EQ(queue.size(), 2u);
  EXPECT_EQ(queue.dropped_packet_count(), 1u);
  EXPECT_EQ(queue.TryPop()->timestamp_hns, 2);
  EXPECT_EQ(queue.TryPop()->timestamp_hns, 3);
}

TEST(AudioPacketQueueTest, CloseUnblocksWaitingPop) {
  AudioPacketQueue queue;
  auto consumer =
      std::async(std::launch::async, [&] { return queue.Pop(); });
  std::this_thread::sleep_for(std::chrono::milliseconds(10));
  queue.Close();
  auto result = consumer.get();
  EXPECT_FALSE(result.has_value());
  EXPECT_TRUE(queue.closed());
}

TEST(AudioPacketQueueTest, ClosedQueueDrainsPendingPackets) {
  AudioPacketQueue queue;
  queue.Push(MakePacket(480, 1));
  queue.Push(MakePacket(480, 2));
  queue.Close();
  EXPECT_TRUE(queue.Pop().has_value());
  EXPECT_TRUE(queue.Pop().has_value());
  EXPECT_FALSE(queue.Pop().has_value());
}

}  // namespace
}  // namespace clingfy::audio
