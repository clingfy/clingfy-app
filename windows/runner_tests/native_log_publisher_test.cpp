#include "Bridge/native_log_publisher.h"

#include <gtest/gtest.h>

#include <regex>
#include <string>

namespace clingfy::bridge {
namespace {

// Phase 10.1: the payload shape is the contract with Dart's
// Log.nativeEvent parser (lib/core/logging/logger_service.dart)
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
      "2026-06-10T12:00:00.000Z");

  const auto* ts = Find(payload, "ts");
  ASSERT_NE(ts, nullptr);
  EXPECT_EQ(std::get<std::string>(*ts), "2026-06-10T12:00:00.000Z");

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

  // Optional keys stay absent when not provided — the Dart JSONL line must
  // not carry null padding.
  EXPECT_EQ(Find(payload, "error"), nullptr);
  EXPECT_EQ(Find(payload, "stack"), nullptr);
}

TEST(NativeLogPublisherTest, BuildPayloadCarriesContextErrorAndStack) {
  flutter::EncodableMap context{
      {flutter::EncodableValue("code"),
       flutter::EncodableValue("ENCODER_VIDEO_ERROR")},
  };
  const flutter::EncodableMap payload = NativeLogPublisher::BuildPayload(
      "ERROR", "Recording", "sink writer failed", "2026-06-10T12:00:00.000Z",
      context, "MF_E_HW_MFT_FAILED_START_STREAMING", "frame0\nframe1");

  const auto* ctx = Find(payload, "context");
  ASSERT_NE(ctx, nullptr);
  const auto* ctx_map = std::get_if<flutter::EncodableMap>(ctx);
  ASSERT_NE(ctx_map, nullptr);
  const auto* code = Find(*ctx_map, "code");
  ASSERT_NE(code, nullptr);
  EXPECT_EQ(std::get<std::string>(*code), "ENCODER_VIDEO_ERROR");

  const auto* error = Find(payload, "error");
  ASSERT_NE(error, nullptr);
  EXPECT_EQ(std::get<std::string>(*error),
            "MF_E_HW_MFT_FAILED_START_STREAMING");

  const auto* stack = Find(payload, "stack");
  ASSERT_NE(stack, nullptr);
  EXPECT_EQ(std::get<std::string>(*stack), "frame0\nframe1");
}

// The ts every emit stamps must be the unified cross-platform shape:
// UTC ISO8601, millisecond precision, trailing 'Z' — one clock base in the
// shared JSONL file (Dart Log and macOS NativeLogger emit the same).
TEST(NativeLogPublisherTest, EmittedTimestampIsUtcIso8601WithMilliseconds) {
  auto& pub = NativeLogPublisher::Instance();
  pub.ClearChannel();
  pub.ClearPendingForTest();
  pub.SetMinLevel("debug");

  pub.Info("Test", "stamp me");
  ASSERT_EQ(pub.pending_count(), 1u);

  const flutter::EncodableMap payload = pub.FrontPendingForTest();
  const auto* ts = Find(payload, "ts");
  ASSERT_NE(ts, nullptr);
  const std::string& stamp = std::get<std::string>(*ts);
  EXPECT_TRUE(std::regex_match(
      stamp,
      std::regex(R"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z)")))
      << "unexpected ts shape: " << stamp;

  const auto* level = Find(payload, "level");
  ASSERT_NE(level, nullptr);
  EXPECT_EQ(std::get<std::string>(*level), "INFO");

  pub.ClearPendingForTest();
}

TEST(NativeLogPublisherTest, EmitWithoutChannelBuffersInsteadOfDropping) {
  auto& pub = NativeLogPublisher::Instance();
  pub.ClearChannel();
  pub.ClearPendingForTest();
  pub.SetMinLevel("debug");

  pub.Debug("Test", "no channel attached");
  pub.Info("Test", "no channel attached");
  pub.Warn("Test", "no channel attached");
  pub.Error("Test", "no channel attached");

  // Startup lines are held for the flushPendingNativeLogs drain.
  EXPECT_EQ(pub.pending_count(), 4u);

  // FlushPending with no channel keeps the buffer (a later flush after the
  // channel attaches must still deliver these lines).
  pub.FlushPending();
  EXPECT_EQ(pub.pending_count(), 4u);

  pub.ClearPendingForTest();
}

TEST(NativeLogPublisherTest, PendingBufferIsBoundedDropOldest) {
  auto& pub = NativeLogPublisher::Instance();
  pub.ClearChannel();
  pub.ClearPendingForTest();
  pub.SetMinLevel("debug");

  for (size_t i = 0; i < NativeLogPublisher::kMaxPending + 40; ++i) {
    pub.Info("Test", "line " + std::to_string(i));
  }
  EXPECT_EQ(pub.pending_count(), NativeLogPublisher::kMaxPending);

  pub.ClearPendingForTest();
}

TEST(NativeLogPublisherTest, BelowThresholdEmitsAreNotBuffered) {
  auto& pub = NativeLogPublisher::Instance();
  pub.ClearChannel();
  pub.ClearPendingForTest();
  pub.SetMinLevel("info");

  pub.Debug("Test", "verbose line while threshold is info");
  EXPECT_EQ(pub.pending_count(), 0u);

  pub.SetMinLevel("debug");
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
  pub.ClearPendingForTest();
}

}  // namespace
}  // namespace clingfy::bridge
