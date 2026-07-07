#include "Bridge/camera_overlay_move_publisher.h"

#include <gtest/gtest.h>

#include "Bridge/native_channel_names.h"

namespace clingfy::bridge {
namespace {

// The payload shape is the contract with Dart's cameraOverlayMoved handler
// (lib/core/bridges/native_bridge.dart -> OverlayController) — same keys macOS
// ScreenRecorderEventBridge sends. A drifted key compiles and passes the whole
// native suite while silently breaking drag-position persistence, so the keys
// are pinned here (NativeLogPublisher::BuildPayload precedent).
TEST(CameraOverlayMovePublisherTest, BuildMovedPayloadMatchesDartParserContract) {
  const flutter::EncodableMap payload =
      CameraOverlayMovePublisher::BuildMovedPayload(0.25, 0.75);

  const auto x = payload.find(flutter::EncodableValue("normalizedX"));
  ASSERT_NE(x, payload.end());
  EXPECT_DOUBLE_EQ(std::get<double>(x->second), 0.25);

  const auto y = payload.find(flutter::EncodableValue("normalizedY"));
  ASSERT_NE(y, payload.end());
  EXPECT_DOUBLE_EQ(std::get<double>(y->second), 0.75);

  // Exactly the two keys Dart reads — nothing extra to drift.
  EXPECT_EQ(payload.size(), 2u);

  // The reverse method name is part of the same contract
  // (Dart NativeToFlutterMethod.cameraOverlayMoved, macOS NativeChannel.swift).
  EXPECT_STREQ(method::kCameraOverlayMoved, "cameraOverlayMoved");
}

// The publisher borrows a method channel that the FlutterWindow clears on
// teardown. EmitMoved must be a safe no-op when no channel is attached — the
// floating overlay thread can process a drag end during (or in tests, without)
// bridge teardown. No messenger is available in unit tests, so this also
// covers the "no listener" path.

TEST(CameraOverlayMovePublisherTest, EmitWithNoChannelIsANoOp) {
  auto& pub = CameraOverlayMovePublisher::Instance();
  pub.ClearChannel();
  // Must not crash / dereference a null channel.
  pub.EmitMoved(0.0, 0.0);
  pub.EmitMoved(0.5, 0.5);
  pub.EmitMoved(1.0, 1.0);
  SUCCEED();
}

TEST(CameraOverlayMovePublisherTest, SetNullChannelThenEmitIsANoOp) {
  auto& pub = CameraOverlayMovePublisher::Instance();
  pub.SetChannel(nullptr);
  pub.EmitMoved(0.25, 0.75);
  pub.ClearChannel();
  SUCCEED();
}

}  // namespace
}  // namespace clingfy::bridge
