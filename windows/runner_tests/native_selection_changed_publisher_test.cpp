#include "Bridge/native_selection_changed_publisher.h"

#include <gtest/gtest.h>

#include "Bridge/native_channel_names.h"

namespace clingfy::bridge {
namespace {

// The reverse method name is the contract with Dart's NativeBridge dispatch
// (NativeToFlutterMethod.nativeSelectionChanged -> home_actions
// .handleNativeSelectionChanged). A drifted name silently breaks every picker.
TEST(NativeSelectionChangedPublisherTest, ReverseMethodNameMatchesDartContract) {
  EXPECT_STREQ(method::kNativeSelectionChanged, "nativeSelectionChanged");
}

// Every emit variant is a safe no-op with no channel attached — the overlay
// thread can process a pick during / without bridge teardown, and no messenger
// exists in unit tests.
TEST(NativeSelectionChangedPublisherTest, EmitsWithNoChannelAreNoOps) {
  auto& pub = NativeSelectionChangedPublisher::Instance();
  pub.ClearChannel();
  pub.EmitStringSelection("mic", "endpoint-id");
  pub.EmitIntSelection("display", 42);
  pub.EmitNoneSelection("camera");
  SUCCEED();
}

// A null type is dropped before any channel work.
TEST(NativeSelectionChangedPublisherTest, NullTypeIsANoOp) {
  auto& pub = NativeSelectionChangedPublisher::Instance();
  pub.SetChannel(nullptr);
  pub.EmitStringSelection(nullptr, "x");
  pub.EmitIntSelection(nullptr, 1);
  pub.EmitNoneSelection(nullptr);
  pub.ClearChannel();
  SUCCEED();
}

}  // namespace
}  // namespace clingfy::bridge
