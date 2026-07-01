#include <flutter/encodable_value.h>
#include <flutter/method_call.h>

#include <gtest/gtest.h>

#include <memory>
#include <set>
#include <string>

#include "Bridge/method_router.h"
#include "test_support.h"

namespace clingfy::bridge {
namespace {

using test_support::MakeRecorder;
using test_support::RecordedReply;

// Phase 10.2: getWindowsPermissionDetails reply-shape contract. Live
// privacy/device state is host-dependent, so these tests pin the SHAPE
// (keys, types, enum membership), never specific states.

const flutter::EncodableMap* SubMap(const flutter::EncodableMap& map,
                                    const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return nullptr;
  return std::get_if<flutter::EncodableMap>(&it->second);
}

std::string SubString(const flutter::EncodableMap& map, const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return {};
  if (const auto* s = std::get_if<std::string>(&it->second)) return *s;
  return {};
}

TEST(PermissionsDetailsRouterTest, ReplyShapeMatchesDartParserContract) {
  MethodRouter router;
  RecordedReply reply;
  router.Dispatch(
      flutter::MethodCall<flutter::EncodableValue>(
          "getWindowsPermissionDetails",
          std::make_unique<flutter::EncodableValue>()),
      MakeRecorder(reply));

  ASSERT_TRUE(reply.success_called);
  const auto* root = std::get_if<flutter::EncodableMap>(&reply.success_value);
  ASSERT_NE(root, nullptr);

  const auto* camera = SubMap(*root, "camera");
  ASSERT_NE(camera, nullptr);
  const std::set<std::string> kReadinessNames = {
      "ready",           "permissionDeniedSystem", "permissionDeniedUser",
      "permissionNotDetermined", "noDevicesAvailable", "noDeviceSelected",
      "selectedDeviceMissing"};
  EXPECT_TRUE(kReadinessNames.count(SubString(*camera, "code")) == 1)
      << "unexpected camera.code: " << SubString(*camera, "code");
  EXPECT_FALSE(SubString(*camera, "reason").empty());
  EXPECT_NE(camera->find(flutter::EncodableValue("deviceSelected")),
            camera->end());
  EXPECT_NE(camera->find(flutter::EncodableValue("devicesAvailable")),
            camera->end());

  const auto* microphone = SubMap(*root, "microphone");
  ASSERT_NE(microphone, nullptr);
  const std::set<std::string> kAccessNames = {
      "granted", "deniedBySystem", "deniedByUser", "notDetermined",
      "unavailableApi"};
  EXPECT_TRUE(kAccessNames.count(SubString(*microphone, "access")) == 1)
      << "unexpected microphone.access: " << SubString(*microphone, "access");
  EXPECT_NE(microphone->find(flutter::EncodableValue("deviceSelected")),
            microphone->end());
  EXPECT_NE(microphone->find(flutter::EncodableValue("selectedDeviceMissing")),
            microphone->end());

  // The explicit "no screen-capture grant needed on Windows" signal.
  const auto* screen = SubMap(*root, "screenRecording");
  ASSERT_NE(screen, nullptr);
  const auto required = screen->find(flutter::EncodableValue("required"));
  ASSERT_NE(required, screen->end());
  EXPECT_EQ(std::get<bool>(required->second), false);
}

}  // namespace
}  // namespace clingfy::bridge
