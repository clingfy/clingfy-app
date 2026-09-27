#include <gtest/gtest.h>

#include <vector>

#include "Bridge/method_router.h"
#include "Audio/microphone_level_monitor.h"
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

// `setAudioSource` also drives the pre-recording input meter.
//
// This is the wiring that was missing entirely on Windows: every consumer of
// `microphoneLevel` shipped long ago -- the Dart handler, the meter, the
// `mic_input_too_low_warning` notice -- and none of them fire if the router
// forgets to reconcile the monitor here. Nothing else in the app would go
// red if it were dropped, which is exactly why it is pinned.
class DevicesRouterAudioSourceTest : public ::testing::Test {
 protected:
  void SetUp() override {
    WindowsSelectionState::Instance().ResetForTesting();
    audio::MicrophoneLevelMonitor::Instance().SetEmitterForTesting(
        [this](const audio::MicrophoneLevel& level) {
          emitted_.push_back(level);
        });
  }
  void TearDown() override {
    audio::MicrophoneLevelMonitor::Instance().Stop(/*emit_silence=*/false);
    audio::MicrophoneLevelMonitor::Instance().SetEmitterForTesting(nullptr);
    WindowsSelectionState::Instance().ResetForTesting();
  }

  std::vector<audio::MicrophoneLevel> emitted_;
};

TEST_F(DevicesRouterAudioSourceTest, SetAudioSourceStoresIdInSelectionState) {
  MethodRouter router;
  RecordedReply reply;

  router.Dispatch(MakeCallWithArgs(
                      "setAudioSource",
                      flutter::EncodableMap{
                          {flutter::EncodableValue("id"),
                           flutter::EncodableValue("{0.0.1.00000000}.{mic}")}}),
                  MakeRecorder(reply));

  EXPECT_TRUE(reply.success_called);
  const auto stored = WindowsSelectionState::Instance().MicrophoneId();
  ASSERT_TRUE(stored.has_value());
  EXPECT_EQ(*stored, "{0.0.1.00000000}.{mic}");
}

TEST_F(DevicesRouterAudioSourceTest, SelectingAMicrophoneStartsTheLevelMeter) {
  MethodRouter router;
  RecordedReply reply;

  router.Dispatch(MakeCallWithArgs(
                      "setAudioSource",
                      flutter::EncodableMap{
                          {flutter::EncodableValue("id"),
                           flutter::EncodableValue("{0.0.1.00000000}.{mic}")}}),
                  MakeRecorder(reply));

  // An unresolvable id falls back to the default capture endpoint, so this
  // opens whatever the machine has. On a runner with no input at all it
  // cannot start -- but it must have TRIED, which the emitted floor reading
  // from the failed open proves.
  EXPECT_TRUE(audio::MicrophoneLevelMonitor::Instance().running() ||
              !emitted_.empty());
}

TEST_F(DevicesRouterAudioSourceTest, ClearingTheSelectionStopsTheLevelMeter) {
  MethodRouter router;
  RecordedReply first;
  router.Dispatch(MakeCallWithArgs(
                      "setAudioSource",
                      flutter::EncodableMap{
                          {flutter::EncodableValue("id"),
                           flutter::EncodableValue("{0.0.1.00000000}.{mic}")}}),
                  MakeRecorder(first));

  RecordedReply second;
  router.Dispatch(
      MakeCallWithArgs("setAudioSource",
                       flutter::EncodableMap{{flutter::EncodableValue("id"),
                                              flutter::EncodableValue()}}),
      MakeRecorder(second));

  EXPECT_TRUE(second.success_called);
  EXPECT_FALSE(audio::MicrophoneLevelMonitor::Instance().running());
  EXPECT_FALSE(WindowsSelectionState::Instance().MicrophoneId().has_value());
}

}  // namespace
}  // namespace clingfy::bridge
