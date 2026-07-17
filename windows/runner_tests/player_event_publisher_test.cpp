#include "Bridge/player_event_publisher.h"

#include <gtest/gtest.h>

#include <flutter/event_sink.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <vector>

#include "test_support.h"

namespace clingfy::bridge {
namespace {

// Step 5.4.1 fix: emits route through PlatformThreadDispatcher.
// Once any test in this process calls Initialize() on the dispatcher
// (the dispatcher tests do, in their SetUp), every subsequent
// EmitPlayer* call PostMessages to the test thread instead of running
// inline. Each emit in this file is therefore followed by a
// `test_support::PumpMessages()` call so the assertions land
// deterministically regardless of test-execution order. When the
// dispatcher is still uninitialized (first test in a process), Post()
// runs inline and the pump is a no-op.

// Captures whatever the publisher emits. Mirrors the RecordingSink
// shape from workflow_event_publisher_test — the captured events live
// in a shared_ptr<vector> so they outlive the sink itself (the
// publisher destroys its unique_ptr<EventSink> on ClearSink, and a
// previous design that captured into a `this->events` field became a
// use-after-free dangling read).
class RecordingSink : public flutter::EventSink<flutter::EncodableValue> {
 public:
  using EventList = std::vector<flutter::EncodableValue>;

  explicit RecordingSink(std::shared_ptr<EventList> events)
      : events_(std::move(events)) {}

 protected:
  void SuccessInternal(const flutter::EncodableValue* event) override {
    events_->push_back(event != nullptr ? *event
                                         : flutter::EncodableValue());
  }
  void ErrorInternal(const std::string& /*code*/,
                     const std::string& /*message*/,
                     const flutter::EncodableValue* /*details*/) override {}
  void EndOfStreamInternal() override {}

 private:
  std::shared_ptr<EventList> events_;
};

std::shared_ptr<RecordingSink::EventList> InstallRecordingSink() {
  auto events = std::make_shared<RecordingSink::EventList>();
  PlayerEventPublisher::Instance().SetSink(
      std::make_unique<RecordingSink>(events));
  return events;
}

class PlayerEventPublisherTest : public ::testing::Test {
 protected:
  void TearDown() override {
    // Reset the singleton's sink so other tests don't see emissions
    // captured by this fixture's RecordingSink (which is about to go
    // out of scope).
    PlayerEventPublisher::Instance().ClearSink();
  }
};

const flutter::EncodableMap* AsMap(const flutter::EncodableValue& v) {
  return std::get_if<flutter::EncodableMap>(&v);
}

std::string ReadString(const flutter::EncodableMap& m, const std::string& k) {
  const auto it = m.find(flutter::EncodableValue(k));
  if (it == m.end()) return {};
  const auto* s = std::get_if<std::string>(&it->second);
  return s ? *s : std::string{};
}

std::int64_t ReadInt(const flutter::EncodableMap& m, const std::string& k) {
  const auto it = m.find(flutter::EncodableValue(k));
  if (it == m.end()) return 0;
  if (const auto* v = std::get_if<std::int64_t>(&it->second)) return *v;
  if (const auto* v = std::get_if<std::int32_t>(&it->second)) return *v;
  return 0;
}

// ---- no-sink path ---------------------------------------------------

TEST_F(PlayerEventPublisherTest, HasSinkIsFalseByDefault) {
  EXPECT_FALSE(PlayerEventPublisher::Instance().has_sink());
}

TEST_F(PlayerEventPublisherTest, NoSinkDropsEventsSilently) {
  // Sanity: every Emit* must be safe-when-no-listener. Dart can
  // attach the sink anytime after Open; events emitted before that
  // point are dropped, not crashed-on.
  PlayerEventPublisher::Instance().EmitPlayerTick("sess-no-sink", 0, 0);
  PlayerEventPublisher::Instance().EmitPlayerState("sess-no-sink", "paused");
  PlayerEventPublisher::Instance().EmitPlayerError(
      "sess-no-sink", "VIDEO_FILE_MISSING", "file gone");
  PlayerEventPublisher::Instance().EmitPlayerWarning(
      "sess-no-sink", "CURSOR_FILE_MISSING", "cursor gone");
  test_support::PumpMessages();
}

TEST_F(PlayerEventPublisherTest, HasSinkReflectsAttachAndClear) {
  auto events = InstallRecordingSink();
  EXPECT_TRUE(PlayerEventPublisher::Instance().has_sink());
  PlayerEventPublisher::Instance().ClearSink();
  EXPECT_FALSE(PlayerEventPublisher::Instance().has_sink());
  // Emissions after ClearSink must be silent drops.
  PlayerEventPublisher::Instance().EmitPlayerTick("sess-1", 1, 2);
  test_support::PumpMessages();
  EXPECT_TRUE(events->empty());
}

// ---- playerTick shape ----------------------------------------------

TEST_F(PlayerEventPublisherTest, PlayerTickShapeMatchesMacOS) {
  auto events = InstallRecordingSink();
  PlayerEventPublisher::Instance().EmitPlayerTick("sess-42", 1234, 60000);
  test_support::PumpMessages();

  ASSERT_EQ(events->size(), 1u);
  const auto* map = AsMap((*events)[0]);
  ASSERT_NE(map, nullptr);
  EXPECT_EQ(ReadString(*map, "type"), "playerTick");
  EXPECT_EQ(ReadString(*map, "sessionId"), "sess-42");
  EXPECT_EQ(ReadInt(*map, "positionMs"), 1234);
  EXPECT_EQ(ReadInt(*map, "durationMs"), 60000);
  // No extra keys leak (matches macOS sendTick payload exactly).
  EXPECT_EQ(map->size(), 4u) << "playerTick should only carry "
                                "{type, sessionId, positionMs, durationMs}";
}

TEST_F(PlayerEventPublisherTest, PlayerTickPreservesLargeDurationMs) {
  auto events = InstallRecordingSink();
  // 10-hour duration: covers the int64 range that wouldn't fit in
  // int32, ensuring the Encodable wrapper uses the 64-bit path.
  const std::int64_t kTenHoursMs = 10LL * 60LL * 60LL * 1000LL;
  PlayerEventPublisher::Instance().EmitPlayerTick("sess-long", 0,
                                                  kTenHoursMs);
  test_support::PumpMessages();
  ASSERT_EQ(events->size(), 1u);
  const auto* map = AsMap((*events)[0]);
  ASSERT_NE(map, nullptr);
  EXPECT_EQ(ReadInt(*map, "durationMs"), kTenHoursMs);
}

// ---- playerState shape ---------------------------------------------

TEST_F(PlayerEventPublisherTest, PlayerStatePlayingShape) {
  auto events = InstallRecordingSink();
  PlayerEventPublisher::Instance().EmitPlayerState("sess-42", "playing");
  test_support::PumpMessages();

  ASSERT_EQ(events->size(), 1u);
  const auto* map = AsMap((*events)[0]);
  ASSERT_NE(map, nullptr);
  EXPECT_EQ(ReadString(*map, "type"), "playerState");
  EXPECT_EQ(ReadString(*map, "sessionId"), "sess-42");
  EXPECT_EQ(ReadString(*map, "state"), "playing");
  EXPECT_EQ(map->size(), 3u);
}

TEST_F(PlayerEventPublisherTest, PlayerStatePausedShape) {
  auto events = InstallRecordingSink();
  PlayerEventPublisher::Instance().EmitPlayerState("sess-42", "paused");
  test_support::PumpMessages();
  ASSERT_EQ(events->size(), 1u);
  EXPECT_EQ(ReadString(*AsMap((*events)[0]), "state"), "paused");
}

TEST_F(PlayerEventPublisherTest, PlayerStateCompletedShape) {
  auto events = InstallRecordingSink();
  PlayerEventPublisher::Instance().EmitPlayerState("sess-42", "completed");
  test_support::PumpMessages();
  ASSERT_EQ(events->size(), 1u);
  EXPECT_EQ(ReadString(*AsMap((*events)[0]), "state"), "completed");
}

// ---- playerError + playerWarning shape -----------------------------

TEST_F(PlayerEventPublisherTest, PlayerErrorShapeMatchesMacOS) {
  auto events = InstallRecordingSink();
  PlayerEventPublisher::Instance().EmitPlayerError(
      "sess-42", "VIDEO_FILE_MISSING",
      "Recording file was moved or deleted.");
  test_support::PumpMessages();

  ASSERT_EQ(events->size(), 1u);
  const auto* map = AsMap((*events)[0]);
  ASSERT_NE(map, nullptr);
  EXPECT_EQ(ReadString(*map, "type"), "playerError");
  EXPECT_EQ(ReadString(*map, "sessionId"), "sess-42");
  EXPECT_EQ(ReadString(*map, "code"), "VIDEO_FILE_MISSING");
  EXPECT_EQ(ReadString(*map, "message"),
            "Recording file was moved or deleted.");
  EXPECT_EQ(map->size(), 4u);
}

TEST_F(PlayerEventPublisherTest, PlayerWarningShapeMatchesMacOS) {
  auto events = InstallRecordingSink();
  PlayerEventPublisher::Instance().EmitPlayerWarning(
      "sess-42", "CURSOR_FILE_MISSING",
      "Cursor data is missing. Cursor effects are disabled.");
  test_support::PumpMessages();

  ASSERT_EQ(events->size(), 1u);
  const auto* map = AsMap((*events)[0]);
  ASSERT_NE(map, nullptr);
  EXPECT_EQ(ReadString(*map, "type"), "playerWarning");
  EXPECT_EQ(ReadString(*map, "sessionId"), "sess-42");
  EXPECT_EQ(ReadString(*map, "code"), "CURSOR_FILE_MISSING");
  EXPECT_EQ(ReadString(*map, "message"),
            "Cursor data is missing. Cursor effects are disabled.");
  EXPECT_EQ(map->size(), 4u);
}

// ---- previewInvalidated shape ---------------------------------------

TEST_F(PlayerEventPublisherTest, PreviewInvalidatedShape) {
  // Windows-only event (no macOS counterpart): emitted after a Modern
  // Standby / suspend resume so Dart silently rebuilds the preview in
  // place. Payload is pinned exactly — Dart's PlayerController switches
  // on `type` and reads `reason` for the log line.
  auto events = InstallRecordingSink();
  PlayerEventPublisher::Instance().EmitPreviewInvalidated("sess-42",
                                                          "systemResume");
  test_support::PumpMessages();

  ASSERT_EQ(events->size(), 1u);
  const auto* map = AsMap((*events)[0]);
  ASSERT_NE(map, nullptr);
  EXPECT_EQ(ReadString(*map, "type"), "previewInvalidated");
  EXPECT_EQ(ReadString(*map, "sessionId"), "sess-42");
  EXPECT_EQ(ReadString(*map, "reason"), "systemResume");
  EXPECT_EQ(map->size(), 3u) << "previewInvalidated should only carry "
                                "{type, sessionId, reason}";
}

// ---- multi-event ordering ------------------------------------------

TEST_F(PlayerEventPublisherTest, EventsArriveInEmissionOrder) {
  auto events = InstallRecordingSink();
  auto& pub = PlayerEventPublisher::Instance();
  pub.EmitPlayerState("sess-1", "playing");
  pub.EmitPlayerTick("sess-1", 100, 1000);
  pub.EmitPlayerTick("sess-1", 200, 1000);
  pub.EmitPlayerState("sess-1", "paused");
  pub.EmitPlayerWarning("sess-1", "CURSOR_FILE_MISSING", "no cursor");
  pub.EmitPlayerError("sess-1", "VIDEO_FILE_MISSING", "no video");
  test_support::PumpMessages();

  ASSERT_EQ(events->size(), 6u);
  EXPECT_EQ(ReadString(*AsMap((*events)[0]), "type"), "playerState");
  EXPECT_EQ(ReadString(*AsMap((*events)[1]), "type"), "playerTick");
  EXPECT_EQ(ReadInt(*AsMap((*events)[1]), "positionMs"), 100);
  EXPECT_EQ(ReadInt(*AsMap((*events)[2]), "positionMs"), 200);
  EXPECT_EQ(ReadString(*AsMap((*events)[3]), "type"), "playerState");
  EXPECT_EQ(ReadString(*AsMap((*events)[3]), "state"), "paused");
  EXPECT_EQ(ReadString(*AsMap((*events)[4]), "type"), "playerWarning");
  EXPECT_EQ(ReadString(*AsMap((*events)[5]), "type"), "playerError");
}

// ---- sink replacement ----------------------------------------------

TEST_F(PlayerEventPublisherTest,
       SecondSinkInstallReplacesAndStopsFirstFromReceiving) {
  auto first_events = InstallRecordingSink();
  PlayerEventPublisher::Instance().EmitPlayerTick("sess-1", 1, 1);
  test_support::PumpMessages();
  ASSERT_EQ(first_events->size(), 1u);

  // Install a second sink — Dart re-subscribes after a hot reload, the
  // publisher replaces in place, and the new sink must take over.
  auto second_events = InstallRecordingSink();
  PlayerEventPublisher::Instance().EmitPlayerTick("sess-1", 2, 2);
  test_support::PumpMessages();
  EXPECT_EQ(first_events->size(), 1u)
      << "first sink should not receive events after the second listen";
  ASSERT_EQ(second_events->size(), 1u);
  EXPECT_EQ(ReadInt(*AsMap((*second_events)[0]), "positionMs"), 2);
}

}  // namespace
}  // namespace clingfy::bridge
