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


// ---------------------------------------------------------------------------
// PopFor. Exists because Pop() cannot tell "idle" from "gone".
//
// With no microphone, system-audio loopback is the ONLY source driving the
// mixer, and WASAPI loopback delivers packets only while something is playing.
// Pop() returns nullopt for both a quiet machine and a dead device, so the
// mixer treated an idle moment as terminal and stopped for good: 0.13 s of
// audio against 38.6 s of video, and 728 of 885 video frames dropped as the
// stalled audio path back-pressured the sink writer.
// ---------------------------------------------------------------------------

using PopStatus = AudioPacketQueue::PopStatus;

TEST(AudioPacketQueuePopForTest, ReturnsAPacketWhenOneIsWaiting) {
  AudioPacketQueue queue;
  queue.Push(MakePacket(480, 7));
  AudioPacket out;
  EXPECT_EQ(queue.PopFor(std::chrono::milliseconds(50), out),
            PopStatus::kPacket);
  EXPECT_EQ(out.frame_count, 480u);
  EXPECT_EQ(out.timestamp_hns, 7);
}

// THE DISTINCTION. An open-but-empty queue is a machine playing nothing, and
// the caller must keep going. Reporting this as closed is what stopped the
// mixer permanently.
TEST(AudioPacketQueuePopForTest, IdleOpenQueueTimesOutRatherThanClosing) {
  AudioPacketQueue queue;
  AudioPacket out;
  EXPECT_EQ(queue.PopFor(std::chrono::milliseconds(20), out),
            PopStatus::kTimeout);
  EXPECT_FALSE(queue.closed());
}

// The other half: a closed, drained queue is terminal and must NOT be reported
// as a timeout, or the caller waits forever on a producer that is gone.
TEST(AudioPacketQueuePopForTest, ClosedAndDrainedReportsClosed) {
  AudioPacketQueue queue;
  queue.Close();
  AudioPacket out;
  EXPECT_EQ(queue.PopFor(std::chrono::milliseconds(20), out),
            PopStatus::kClosed);
}

// Closing must not discard what was already queued: packets first, THEN the
// terminal signal. Dropping the tail here would lose the last audio of every
// recording.
TEST(AudioPacketQueuePopForTest, DrainsBeforeReportingClosed) {
  AudioPacketQueue queue;
  queue.Push(MakePacket(480, 1));
  queue.Push(MakePacket(480, 2));
  queue.Close();

  AudioPacket out;
  EXPECT_EQ(queue.PopFor(std::chrono::milliseconds(20), out),
            PopStatus::kPacket);
  EXPECT_EQ(out.timestamp_hns, 1);
  EXPECT_EQ(queue.PopFor(std::chrono::milliseconds(20), out),
            PopStatus::kPacket);
  EXPECT_EQ(out.timestamp_hns, 2);
  EXPECT_EQ(queue.PopFor(std::chrono::milliseconds(20), out),
            PopStatus::kClosed);
}

// A packet arriving inside the window must be returned, not missed. The
// predicate form of wait_for handles the spurious-wake case; this pins it.
TEST(AudioPacketQueuePopForTest, PicksUpAPacketThatArrivesDuringTheWait) {
  AudioPacketQueue queue;
  auto producer = std::async(std::launch::async, [&] {
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
    queue.Push(MakePacket(480, 42));
  });
  AudioPacket out;
  EXPECT_EQ(queue.PopFor(std::chrono::milliseconds(500), out),
            PopStatus::kPacket);
  EXPECT_EQ(out.timestamp_hns, 42);
  producer.get();
}

// A close landing during the wait is terminal, not a timeout — the caller must
// stop rather than keep synthesising silence forever.
TEST(AudioPacketQueuePopForTest, ObservesACloseDuringTheWait) {
  AudioPacketQueue queue;
  auto closer = std::async(std::launch::async, [&] {
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
    queue.Close();
  });
  AudioPacket out;
  EXPECT_EQ(queue.PopFor(std::chrono::milliseconds(500), out),
            PopStatus::kClosed);
  closer.get();
}

// It must actually WAIT. A PopFor that returned immediately would spin the
// mixer at full CPU and flood the encoder with silence.
TEST(AudioPacketQueuePopForTest, WaitsForRoughlyTheRequestedTimeout) {
  AudioPacketQueue queue;
  AudioPacket out;
  const auto start = std::chrono::steady_clock::now();
  EXPECT_EQ(queue.PopFor(std::chrono::milliseconds(60), out),
            PopStatus::kTimeout);
  const auto waited = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - start);
  // Generous lower bound: scheduler granularity, not precision, is the point.
  EXPECT_GE(waited.count(), 40);
}

// Repeated timeouts stay timeouts. The mixer calls this every slice for as long
// as the machine is quiet — which can be the whole recording.
TEST(AudioPacketQueuePopForTest, StaysTimeoutAcrossManyIdleSlices) {
  AudioPacketQueue queue;
  AudioPacket out;
  for (int i = 0; i < 5; ++i) {
    EXPECT_EQ(queue.PopFor(std::chrono::milliseconds(5), out),
              PopStatus::kTimeout)
        << "slice " << i;
  }
  EXPECT_FALSE(queue.closed());
}

}  // namespace
}  // namespace clingfy::audio
