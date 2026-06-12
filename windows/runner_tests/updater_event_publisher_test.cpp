#include "Bridge/updater_event_publisher.h"

#include <gtest/gtest.h>

#include <flutter/event_sink.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <vector>

#include "test_support.h"

// Phase 10.6 — payload-shape tests for the updater event channel. The
// `updateAvailable` shape is the macOS Sparkle parity contract (version and
// build are STRINGS — UpdaterController.swift sends displayVersionString /
// versionString); `checking` / `noUpdateAvailable` / `updateError` are the
// Windows-only honest-status events.
namespace clingfy::bridge {
namespace {

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
  UpdaterEventPublisher::Instance().SetSink(
      std::make_unique<RecordingSink>(events));
  return events;
}

class UpdaterEventPublisherTest : public ::testing::Test {
 protected:
  void TearDown() override {
    UpdaterEventPublisher::Instance().ClearSink();
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

TEST_F(UpdaterEventPublisherTest, HasSinkIsFalseByDefault) {
  EXPECT_FALSE(UpdaterEventPublisher::Instance().has_sink());
}

TEST_F(UpdaterEventPublisherTest, NoSinkDropsEventsSilently) {
  UpdaterEventPublisher::Instance().EmitChecking();
  UpdaterEventPublisher::Instance().EmitUpdateAvailable("1.0.5", "7",
                                                        "https://x", "1.0.5+7");
  UpdaterEventPublisher::Instance().EmitNoUpdateAvailable("1.0.4");
  UpdaterEventPublisher::Instance().EmitUpdateError("UPDATE_FEED_MALFORMED",
                                                    "oops");
  test_support::PumpMessages();
}

TEST_F(UpdaterEventPublisherTest, CheckingShape) {
  auto events = InstallRecordingSink();
  UpdaterEventPublisher::Instance().EmitChecking();
  test_support::PumpMessages();
  ASSERT_EQ(events->size(), 1u);
  const auto* map = AsMap((*events)[0]);
  ASSERT_NE(map, nullptr);
  EXPECT_EQ(ReadString(*map, "type"), "checking");
}

TEST_F(UpdaterEventPublisherTest, UpdateAvailableShapeMatchesSparkleParity) {
  auto events = InstallRecordingSink();
  UpdaterEventPublisher::Instance().EmitUpdateAvailable(
      "1.0.5", "7", "https://host.example/Clingfy_Dev_Setup_1.0.5+7.exe",
      "1.0.5+7");
  test_support::PumpMessages();
  ASSERT_EQ(events->size(), 1u);
  const auto* map = AsMap((*events)[0]);
  ASSERT_NE(map, nullptr);
  EXPECT_EQ(ReadString(*map, "type"), "updateAvailable");
  // version/build are STRINGS — the macOS payload contract.
  EXPECT_EQ(ReadString(*map, "version"), "1.0.5");
  EXPECT_EQ(ReadString(*map, "build"), "7");
  EXPECT_EQ(ReadString(*map, "url"),
            "https://host.example/Clingfy_Dev_Setup_1.0.5+7.exe");
  EXPECT_EQ(ReadString(*map, "versionFull"), "1.0.5+7");
}

TEST_F(UpdaterEventPublisherTest, NoUpdateAvailableShape) {
  auto events = InstallRecordingSink();
  UpdaterEventPublisher::Instance().EmitNoUpdateAvailable("1.0.4");
  test_support::PumpMessages();
  ASSERT_EQ(events->size(), 1u);
  const auto* map = AsMap((*events)[0]);
  ASSERT_NE(map, nullptr);
  EXPECT_EQ(ReadString(*map, "type"), "noUpdateAvailable");
  EXPECT_EQ(ReadString(*map, "version"), "1.0.4");
}

TEST_F(UpdaterEventPublisherTest, UpdateErrorShape) {
  auto events = InstallRecordingSink();
  UpdaterEventPublisher::Instance().EmitUpdateError("UPDATE_FEED_UNREACHABLE",
                                                    "HTTP 503");
  test_support::PumpMessages();
  ASSERT_EQ(events->size(), 1u);
  const auto* map = AsMap((*events)[0]);
  ASSERT_NE(map, nullptr);
  EXPECT_EQ(ReadString(*map, "type"), "updateError");
  EXPECT_EQ(ReadString(*map, "code"), "UPDATE_FEED_UNREACHABLE");
  EXPECT_EQ(ReadString(*map, "message"), "HTTP 503");
}

TEST_F(UpdaterEventPublisherTest, ClearSinkStopsDelivery) {
  auto events = InstallRecordingSink();
  EXPECT_TRUE(UpdaterEventPublisher::Instance().has_sink());
  UpdaterEventPublisher::Instance().ClearSink();
  EXPECT_FALSE(UpdaterEventPublisher::Instance().has_sink());
  UpdaterEventPublisher::Instance().EmitChecking();
  test_support::PumpMessages();
  EXPECT_TRUE(events->empty());
}

}  // namespace
}  // namespace clingfy::bridge
