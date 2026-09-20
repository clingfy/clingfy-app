#include "Capture/Indicator/recording_indicator_controller.h"

#include <gtest/gtest.h>

#include <atomic>
#include <cstdint>

// The elapsed-seconds provider must not be invoked while `provider_mutex_` is
// held.
//
// Why this rule exists: the provider installed by `RecordingEngine::Start`
// calls back into `RecordingEngine::ElapsedSeconds()`, which takes the
// engine's `mutex_` — and `Start` holds `mutex_` for its whole body while
// calling `Show()`, which takes `provider_mutex_`. Two threads, two locks,
// opposite order:
//
//   main thread   : holds mutex_          -> wants provider_mutex_ (Show)
//   overlay thread: holds provider_mutex_ -> wants mutex_          (provider)
//
// Both are bare non-recursive `std::mutex` with no timeout and no try_lock, so
// the cycle is permanent once closed, and silent: the two waiters are on
// different threads, so MSVC's same-thread relock check never fires. The
// symptom was `RecordingEngineTest.StartAfterStopIsAllowed` timing out at
// 300 s in CI with no exception, no log and no crash.
//
// This is a GUARD, not a reproduction. It cannot fail against the code as it
// was, because the pre-fix version had no seam to call — the lock was inline
// in `Paint`, which needs a real window. What it does do is fail loudly if
// anyone re-inlines the lock around the provider call, which is the mistake
// that would bring the deadlock back.
namespace clingfy::capture {
namespace {

TEST(RecordingIndicatorProviderLockTest, ProviderRunsWithoutTheProviderLock) {
  auto& indicator = RecordingIndicatorController::Instance();
  std::atomic<bool> reentered{false};

  indicator.Show([&reentered]() -> std::uint64_t {
    // Re-enter on THIS thread. If `provider_mutex_` were still held across the
    // provider call, this second acquisition would throw
    // `std::system_error(resource_deadlock_would_occur)` on MSVC rather than
    // returning — a non-recursive mutex relocked by its own owner.
    if (!reentered.exchange(true)) {
      (void)RecordingIndicatorController::Instance().CurrentElapsedSeconds();
    }
    return 7;
  });

  EXPECT_EQ(indicator.CurrentElapsedSeconds(), 7u);
  EXPECT_TRUE(reentered.load())
      << "the provider never ran, so this asserted nothing";

  // Joins the overlay thread and clears the provider. `Show` may or may not
  // have managed to create a window depending on the window station, and the
  // provider is installed either way — `Show` stores it before it tries.
  indicator.Shutdown();
}

TEST(RecordingIndicatorProviderLockTest, NoProviderReadsAsZero) {
  auto& indicator = RecordingIndicatorController::Instance();
  indicator.Shutdown();  // Clears any provider a previous test installed.

  EXPECT_EQ(indicator.CurrentElapsedSeconds(), 0u);
}

}  // namespace
}  // namespace clingfy::capture
