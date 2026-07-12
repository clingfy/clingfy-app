#include "Services/keep_awake.h"

#include <gtest/gtest.h>

namespace clingfy::services {
namespace {

// The scope must actually hold a system-required power request while alive —
// this is what keeps Modern Standby from invalidating the GPU/media stack
// mid-recording / mid-export (the 55-minute-recording failure class).
TEST(KeepAwakeTest, HoldsASystemPowerRequestWhileAlive) {
  KeepAwake awake(KeepAwake::Mode::kSystem, L"runner_tests keep-awake probe");
  // PowerCreateRequest/PowerSetRequest have no capability gate — they work
  // in services and CI sessions alike, so an inactive request is a real bug,
  // not an environment limitation.
  EXPECT_TRUE(awake.active());
}

TEST(KeepAwakeTest, SystemAndDisplayModeAlsoHoldsTheSystemRequest) {
  KeepAwake awake(KeepAwake::Mode::kSystemAndDisplay,
                  L"runner_tests keep-awake display probe");
  EXPECT_TRUE(awake.active());
}

// Destruction must release cleanly (no crash, no leaked handle assert under
// the debug CRT). Creating a second scope after the first is torn down
// proves the clear/close path leaves the process able to re-acquire.
TEST(KeepAwakeTest, ReacquiresAfterRelease) {
  {
    KeepAwake first(KeepAwake::Mode::kSystem, L"runner_tests first scope");
    EXPECT_TRUE(first.active());
  }
  KeepAwake second(KeepAwake::Mode::kSystem, L"runner_tests second scope");
  EXPECT_TRUE(second.active());
}

TEST(KeepAwakeTest, NullReasonFallsBackSafely) {
  KeepAwake awake(KeepAwake::Mode::kSystem, nullptr);
  EXPECT_TRUE(awake.active());
}

}  // namespace
}  // namespace clingfy::services
