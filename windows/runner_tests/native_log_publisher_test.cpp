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
  NativeLogPublisher::Instance().SetMinLevel("debug");
  NativeLogPublisher::Instance().Debug("Test", "no channel attached");
  NativeLogPublisher::Instance().Info("Test", "no channel attached");
  NativeLogPublisher::Instance().Warn("Test", "no channel attached");
  NativeLogPublisher::Instance().Error("Test", "no channel attached");
}

// The Settings "verbose logging" toggle (setNativeLogLevel → SetMinLevel) must
// gate emitted levels the same way macOS NativeLogger does: below-threshold
// lines are dropped at the source so they never cross the channel.
TEST(NativeLogPublisherTest, SetMinLevelGatesEmittedLevels) {
  auto& pub = NativeLogPublisher::Instance();

  pub.SetMinLevel("debug");
  EXPECT_TRUE(pub.ShouldSend("DEBUG"));
  EXPECT_TRUE(pub.ShouldSend("INFO"));
  EXPECT_TRUE(pub.ShouldSend("WARNING"));
  EXPECT_TRUE(pub.ShouldSend("ERROR"));

  pub.SetMinLevel("info");
  EXPECT_FALSE(pub.ShouldSend("DEBUG"));
  EXPECT_TRUE(pub.ShouldSend("INFO"));
  EXPECT_TRUE(pub.ShouldSend("WARNING"));
  EXPECT_TRUE(pub.ShouldSend("ERROR"));

  pub.SetMinLevel("warning");
  EXPECT_FALSE(pub.ShouldSend("DEBUG"));
  EXPECT_FALSE(pub.ShouldSend("INFO"));
  EXPECT_TRUE(pub.ShouldSend("WARNING"));

  pub.SetMinLevel("error");
  EXPECT_FALSE(pub.ShouldSend("WARNING"));
  EXPECT_TRUE(pub.ShouldSend("ERROR"));

  // Aliases + case/whitespace tolerance (matches macOS + the Dart level names).
  pub.SetMinLevel("  Verbose ");
  EXPECT_TRUE(pub.ShouldSend("DEBUG"));
  pub.SetMinLevel("W");
  EXPECT_FALSE(pub.ShouldSend("INFO"));
  EXPECT_TRUE(pub.ShouldSend("WARNING"));

  // Unknown names are ignored (threshold unchanged), like macOS.
  const int before = pub.min_level_rank();
  pub.SetMinLevel("bogus");
  EXPECT_EQ(pub.min_level_rank(), before);

  // Leave a permissive threshold so later tests' emits aren't starved.
  pub.SetMinLevel("debug");
}

}  // namespace
}  // namespace clingfy::bridge
