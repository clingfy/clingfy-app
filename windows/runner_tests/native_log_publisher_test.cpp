#include "Bridge/native_log_publisher.h"

#include <gtest/gtest.h>

#include <string>

namespace clingfy::bridge {
namespace {

// Phase 10.1: the payload shape is the contract with Dart's
// Log.nativeEvent parser (lib/app/infrastructure/logging/logger_service.dart)
// — same keys macOS NativeLogger.swift sends. A drifted key silently
// downgrades the line to DEBUG/'Native'/'' on the Dart side.

const flutter::EncodableValue* Find(const flutter::EncodableMap& map,
                                    const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  return it == map.end() ? nullptr : &it->second;
}

TEST(NativeLogPublisherTest, BuildPayloadMatchesDartParserContract) {
  const flutter::EncodableMap payload = NativeLogPublisher::BuildPayload(
      "ERROR", "Recording", "mic open failed (hr=0x80070005)",
      "2026-06-10T12:00:00Z");

  const auto* ts = Find(payload, "ts");
  ASSERT_NE(ts, nullptr);
  EXPECT_EQ(std::get<std::string>(*ts), "2026-06-10T12:00:00Z");

  const auto* level = Find(payload, "level");
  ASSERT_NE(level, nullptr);
  EXPECT_EQ(std::get<std::string>(*level), "ERROR");

  const auto* category = Find(payload, "category");
  ASSERT_NE(category, nullptr);
  EXPECT_EQ(std::get<std::string>(*category), "Recording");

  const auto* message = Find(payload, "message");
  ASSERT_NE(message, nullptr);
  EXPECT_EQ(std::get<std::string>(*message),
            "mic open failed (hr=0x80070005)");

  const auto* context = Find(payload, "context");
  ASSERT_NE(context, nullptr);
  const auto* context_map = std::get_if<flutter::EncodableMap>(context);
  ASSERT_NE(context_map, nullptr);
  EXPECT_TRUE(context_map->empty());
}

TEST(NativeLogPublisherTest, EmitWithoutChannelIsSafeNoOp) {
  // Startup races and teardown both hit this path; it must never crash or
  // queue anything against a dead channel.
  NativeLogPublisher::Instance().ClearChannel();
  NativeLogPublisher::Instance().Info("Test", "no channel attached");
  NativeLogPublisher::Instance().Warn("Test", "no channel attached");
  NativeLogPublisher::Instance().Error("Test", "no channel attached");
}

}  // namespace
}  // namespace clingfy::bridge
