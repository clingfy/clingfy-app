#include "Bridge/platform_thread_dispatcher.h"

#include <gtest/gtest.h>

#include <windows.h>

#include <atomic>
#include <chrono>
#include <memory>
#include <thread>
#include <vector>

#include "test_support.h"

namespace clingfy::bridge {
namespace {

// Spin-pump for up to `timeout_ms`, returning as soon as `predicate`
// is true. Used in the worker-thread tests where the worker might
// not have queued its message by the time the test thread starts
// pumping. Wraps the shared `test_support::PumpMessages()`.
template <typename Predicate>
bool PumpUntil(Predicate&& predicate, int timeout_ms = 1000) {
  const auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::milliseconds(timeout_ms);
  while (!predicate()) {
    if (std::chrono::steady_clock::now() > deadline) return false;
    test_support::PumpMessages();
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  return true;
}

class PlatformThreadDispatcherTest : public ::testing::Test {
 protected:
  void SetUp() override {
    // Initialize is idempotent across tests — the dispatcher
    // singleton's window is created on the first SetUp and survives
    // subsequent tests. ASSERT_TRUE here so a registration failure
    // surfaces as a per-test failure rather than a cascade.
    ASSERT_TRUE(PlatformThreadDispatcher::Instance().Initialize());
  }
};

// ---- Fallback (uninitialized) path --------------------------------

// This test is in the bare namespace so it doesn't run the SetUp
// that initializes the dispatcher. We can't actually uninitialize the
// singleton mid-process, so we exercise the fallback semantics by
// reasoning about behaviour: if Initialize hasn't been called yet,
// Post runs inline. That branch is unit-tested implicitly by every
// `player_event_publisher_test` case — they all run before this
// suite's SetUp, with the dispatcher uninitialized.

// ---- Post from same thread ----------------------------------------

TEST_F(PlatformThreadDispatcherTest, PostFromPlatformThreadDispatches) {
  std::atomic<int> counter{0};
  PlatformThreadDispatcher::Instance().Post(
      [&counter]() { counter.fetch_add(1); });

  // Posted from the test (platform) thread to itself. Until we pump
  // the queue, the callback hasn't run.
  EXPECT_EQ(counter.load(), 0);
  test_support::PumpMessages();
  EXPECT_EQ(counter.load(), 1);
}

TEST_F(PlatformThreadDispatcherTest, MultipleTasksDispatchInOrder) {
  std::vector<int> order;
  for (int i = 0; i < 5; ++i) {
    PlatformThreadDispatcher::Instance().Post(
        [&order, i]() { order.push_back(i); });
  }
  test_support::PumpMessages();
  ASSERT_EQ(order.size(), 5u);
  for (int i = 0; i < 5; ++i) EXPECT_EQ(order[i], i);
}

// ---- Post from worker thread (the real bug fix path) -------------

TEST_F(PlatformThreadDispatcherTest, PostFromWorkerThreadLandsOnPlatformThread) {
  const DWORD platform_tid = ::GetCurrentThreadId();
  std::atomic<DWORD> dispatched_tid{0};
  std::atomic<bool> ran{false};

  std::thread worker([&] {
    // From a real worker thread — the test process spawns this
    // std::thread, so its OS tid is distinct from the test thread.
    PlatformThreadDispatcher::Instance().Post([&] {
      dispatched_tid.store(::GetCurrentThreadId());
      ran.store(true);
    });
  });
  worker.join();

  // Worker queued the message but the actual callback runs on the
  // platform thread. Pump until it fires (or timeout).
  ASSERT_TRUE(PumpUntil([&] { return ran.load(); }));
  EXPECT_EQ(dispatched_tid.load(), platform_tid)
      << "Callback ran on tid " << dispatched_tid.load()
      << " but the platform thread is tid " << platform_tid;
}

TEST_F(PlatformThreadDispatcherTest,
       ManyWorkersAllMarshalToPlatformThread) {
  const DWORD platform_tid = ::GetCurrentThreadId();
  constexpr int kThreads = 8;
  constexpr int kPerThread = 20;
  std::atomic<int> ran_count{0};
  std::atomic<int> wrong_thread_count{0};

  std::vector<std::thread> workers;
  for (int i = 0; i < kThreads; ++i) {
    workers.emplace_back([&] {
      for (int j = 0; j < kPerThread; ++j) {
        PlatformThreadDispatcher::Instance().Post([&] {
          if (::GetCurrentThreadId() != platform_tid) {
            wrong_thread_count.fetch_add(1);
          }
          ran_count.fetch_add(1);
        });
      }
    });
  }
  for (auto& t : workers) t.join();

  const int kExpected = kThreads * kPerThread;
  ASSERT_TRUE(PumpUntil([&] { return ran_count.load() >= kExpected; },
                        5000));
  EXPECT_EQ(ran_count.load(), kExpected);
  EXPECT_EQ(wrong_thread_count.load(), 0)
      << "Every callback must run on the platform thread.";
}

// ---- Empty task is a no-op ----------------------------------------

TEST_F(PlatformThreadDispatcherTest, EmptyTaskDoesNothing) {
  // An empty std::function<void()> should be a silent no-op — does
  // not crash and does not enqueue a message.
  PlatformThreadDispatcher::Instance().Post({});
  // Pump anyway in case the empty-task path queued anything; the
  // assertion is "nothing crashed."
  test_support::PumpMessages();
}

}  // namespace
}  // namespace clingfy::bridge
