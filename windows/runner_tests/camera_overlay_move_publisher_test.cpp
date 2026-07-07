#include "Bridge/camera_overlay_move_publisher.h"

#include <gtest/gtest.h>

namespace clingfy::bridge {
namespace {

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
