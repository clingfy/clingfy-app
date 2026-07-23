#include "Bridge/indicator_event_publisher.h"

#include <gtest/gtest.h>

#include "Bridge/native_channel_names.h"

namespace clingfy::bridge {
namespace {

// The three reverse method names are the contract with Dart's NativeBridge
// dispatch (lib/core/bridges/native_method_channel.dart
// NativeToFlutterMethod.indicator{Pause,Stop,Resume}Tapped -> home_bindings).
// A drifted name compiles and passes the whole native suite while silently
// breaking the pill's controls, so they are pinned here
// (CameraOverlayMovePublisher::kCameraOverlayMoved precedent).
TEST(IndicatorEventPublisherTest, ReverseMethodNamesMatchDartContract) {
  EXPECT_STREQ(method::kIndicatorPauseTapped, "indicatorPauseTapped");
  EXPECT_STREQ(method::kIndicatorStopTapped, "indicatorStopTapped");
  EXPECT_STREQ(method::kIndicatorResumeTapped, "indicatorResumeTapped");
}

// The publisher borrows a method channel that FlutterWindow clears on teardown.
// Every emit must be a safe no-op when no channel is attached — the overlay
// thread can process a control tap during (or, in tests, without) bridge
// teardown. No messenger is available in unit tests, so this also covers the
// "no listener" path.
TEST(IndicatorEventPublisherTest, EmitWithNoChannelIsANoOp) {
  auto& pub = IndicatorEventPublisher::Instance();
  pub.ClearChannel();
  pub.EmitPauseTapped();
  pub.EmitStopTapped();
  pub.EmitResumeTapped();
  SUCCEED();
}

TEST(IndicatorEventPublisherTest, SetNullChannelThenEmitIsANoOp) {
  auto& pub = IndicatorEventPublisher::Instance();
  pub.SetChannel(nullptr);
  pub.EmitPauseTapped();
  pub.ClearChannel();
  SUCCEED();
}

}  // namespace
}  // namespace clingfy::bridge
