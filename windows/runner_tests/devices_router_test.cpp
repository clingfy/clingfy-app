#include <gtest/gtest.h>

#include "Bridge/method_router.h"
#include "Capture/windows_selection_state.h"
#include "test_support.h"

// Phase 9.1: `setVideoSource` stopped being a no-op — it now records the
// selected camera id into WindowsSelectionState (the same singleton the engine
// reads at Start). These tests pin the router → state path so a future refactor
// that drops the wiring is caught here rather than silently making camera
// selection a no-op again.
namespace clingfy::bridge {
namespace {

using capture::WindowsSelectionState;
using test_support::MakeCallWithArgs;
using test_support::MakeRecorder;
using test_support::RecordedReply;

class DevicesRouterVideoSourceTest : public ::testing::Test {
 protected:
  void SetUp() override { WindowsSelectionState::Instance().ResetForTesting(); }
  void TearDown() override {
    WindowsSelectionState::Instance().ResetForTesting();
  }
};

TEST_F(DevicesRouterVideoSourceTest, SetVideoSourceStoresIdInSelectionState) {
  MethodRouter router;
  RecordedReply reply;

  router.Dispatch(
      MakeCallWithArgs(
          "setVideoSource",
          flutter::EncodableMap{
              {flutter::EncodableValue("id"),
               flutter::EncodableValue("\\\\?\\usb#vid_046d&pid_0825")}}),
      MakeRecorder(reply));

  EXPECT_TRUE(reply.success_called);
  EXPECT_FALSE(reply.error_called);
  const auto stored = WindowsSelectionState::Instance().VideoSourceId();
  ASSERT_TRUE(stored.has_value());
  EXPECT_EQ(*stored, "\\\\?\\usb#vid_046d&pid_0825");
}

TEST_F(DevicesRouterVideoSourceTest, SetVideoSourceEmptyStringClearsSelection) {
  WindowsSelectionState::Instance().SetVideoSourceId(std::string("{cam}"));
  MethodRouter router;
  RecordedReply reply;

  // Deselecting in the UI sends an empty id — ReadOptionalString maps "" to
  // nullopt, so the native selection clears.
  router.Dispatch(
      MakeCallWithArgs("setVideoSource",
                       flutter::EncodableMap{
                           {flutter::EncodableValue("id"),
                            flutter::EncodableValue(std::string(""))}}),
      MakeRecorder(reply));

  EXPECT_TRUE(reply.success_called);
  EXPECT_FALSE(WindowsSelectionState::Instance().VideoSourceId().has_value());
}

TEST_F(DevicesRouterVideoSourceTest, SetVideoSourceMissingArgsClearsSelection) {
  WindowsSelectionState::Instance().SetVideoSourceId(std::string("{cam}"));
  MethodRouter router;
  RecordedReply reply;

  // No `id` key at all — treated as "clear", never a parse error.
  router.Dispatch(MakeCallWithArgs("setVideoSource", flutter::EncodableMap{}),
                  MakeRecorder(reply));

  EXPECT_TRUE(reply.success_called);
  EXPECT_FALSE(reply.error_called);
  EXPECT_FALSE(WindowsSelectionState::Instance().VideoSourceId().has_value());
}

}  // namespace
}  // namespace clingfy::bridge
