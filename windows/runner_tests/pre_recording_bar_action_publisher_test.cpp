#include "Bridge/pre_recording_bar_action_publisher.h"

#include <gtest/gtest.h>

#include "Bridge/native_channel_names.h"

namespace clingfy::bridge {
namespace {

// The reverse method name is the contract with Dart's NativeBridge dispatch
// (lib/core/bridges/native_method_channel.dart
// NativeToFlutterMethod.preRecordingBarAction -> home_actions.handleNativeBarAction).
// A drifted name compiles and passes the whole native suite while silently
// breaking every bar button, so it is pinned here (IndicatorEventPublisher /
// CameraOverlayMovePublisher precedent).
TEST(PreRecordingBarActionPublisherTest, ReverseMethodNameMatchesDartContract) {
  EXPECT_STREQ(method::kPreRecordingBarAction, "preRecordingBarAction");
}

// The publisher borrows a method channel that FlutterWindow clears on teardown.
// Every emit must be a safe no-op when no channel is attached — the overlay
// thread can process a bar tap during (or, in tests, without) bridge teardown.
// No messenger is available in unit tests, so this also covers "no listener".
TEST(PreRecordingBarActionPublisherTest, EmitWithNoChannelIsANoOp) {
  auto& pub = PreRecordingBarActionPublisher::Instance();
  pub.ClearChannel();
  pub.EmitAction("recordTapped");
  SUCCEED();
}

// An empty / null action type is dropped before any channel work.
TEST(PreRecordingBarActionPublisherTest, EmptyActionIsANoOp) {
  auto& pub = PreRecordingBarActionPublisher::Instance();
  pub.SetChannel(nullptr);
  pub.EmitAction("");
  pub.EmitAction(nullptr);
  pub.ClearChannel();
  SUCCEED();
}

}  // namespace
}  // namespace clingfy::bridge
