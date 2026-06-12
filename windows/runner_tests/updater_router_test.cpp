#include <gtest/gtest.h>

#include <flutter/event_sink.h>
#include <flutter/method_call.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>
#include <vector>

#include "Bridge/method_router.h"
#include "Bridge/updater_event_publisher.h"
#include "Updater/update_checker.h"
#include "Updater/update_feed.h"
#include "test_support.h"

// Phase 10.6 — end-to-end router tests for the real `checkForUpdates`:
// dispatch through MethodRouter with an injected fetcher, join the worker,
// pump the dispatcher, and assert the events Dart would see. No network.
namespace clingfy::bridge {
namespace {

using test_support::MakeCallWithArgs;
using test_support::MakeRecorder;
using test_support::PumpMessages;
using test_support::RecordedReply;

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

const flutter::EncodableMap* AsMap(const flutter::EncodableValue& v) {
  return std::get_if<flutter::EncodableMap>(&v);
}

std::string ReadString(const flutter::EncodableMap& m, const std::string& k) {
  const auto it = m.find(flutter::EncodableValue(k));
  if (it == m.end()) return {};
  const auto* s = std::get_if<std::string>(&it->second);
  return s ? *s : std::string{};
}

clingfy::updater::AppVersion Version(int major, int minor, int patch,
                                     std::int64_t build) {
  clingfy::updater::AppVersion v;
  v.major = major;
  v.minor = minor;
  v.patch = patch;
  v.build = build;
  return v;
}

class UpdaterRouterTest : public ::testing::Test {
 protected:
  void SetUp() override {
    events_ = std::make_shared<RecordingSink::EventList>();
    UpdaterEventPublisher::Instance().SetSink(
        std::make_unique<RecordingSink>(events_));
    // Pin the "running" version so the test exe's missing version resource
    // does not abort the pipeline.
    clingfy::updater::SetCurrentVersionForTesting(Version(1, 0, 4, 5));
  }

  void TearDown() override {
    clingfy::updater::JoinUpdateCheckForTesting();
    clingfy::updater::SetUpdateFetcherForTesting(nullptr);
    clingfy::updater::ClearCurrentVersionOverrideForTesting();
    UpdaterEventPublisher::Instance().ClearSink();
  }

  // Dispatches checkForUpdates with args, joins the async check, pumps the
  // dispatcher, and returns the method reply.
  RecordedReply Check(flutter::EncodableMap args) {
    RecordedReply reply;
    router_.Dispatch(MakeCallWithArgs("checkForUpdates", std::move(args)),
                     MakeRecorder(reply));
    clingfy::updater::JoinUpdateCheckForTesting();
    PumpMessages();
    return reply;
  }

  void StubFeedBody(const std::string& body) {
    clingfy::updater::SetUpdateFetcherForTesting(
        [body](const std::string& /*url*/) {
          clingfy::updater::FetchResult result;
          result.ok = true;
          result.body = body;
          return result;
        });
  }

  std::vector<std::string> EventTypes() const {
    std::vector<std::string> types;
    for (const auto& event : *events_) {
      const auto* map = AsMap(event);
      types.push_back(map != nullptr ? ReadString(*map, "type") : "<not-map>");
    }
    return types;
  }

  MethodRouter router_;
  std::shared_ptr<RecordingSink::EventList> events_;
};

TEST_F(UpdaterRouterTest, MissingFeedUrlRepliesFalseAndEmitsNotConfigured) {
  RecordedReply reply;
  router_.Dispatch(test_support::MakeCall("checkForUpdates"),
                   MakeRecorder(reply));
  PumpMessages();
  ASSERT_TRUE(reply.success_called);
  const auto* value = std::get_if<bool>(&reply.success_value);
  ASSERT_NE(value, nullptr);
  EXPECT_FALSE(*value);
  ASSERT_EQ(events_->size(), 1u);
  const auto* map = AsMap((*events_)[0]);
  ASSERT_NE(map, nullptr);
  EXPECT_EQ(ReadString(*map, "type"), "updateError");
  EXPECT_EQ(ReadString(*map, "code"),
            clingfy::updater::codes::kFeedNotConfigured);
}

TEST_F(UpdaterRouterTest, NonHttpsFeedUrlRepliesFalseAndEmitsError) {
  const RecordedReply reply = Check(flutter::EncodableMap{
      {flutter::EncodableValue("feedUrl"),
       flutter::EncodableValue("http://insecure.example/latest.json")},
  });
  ASSERT_TRUE(reply.success_called);
  const auto* value = std::get_if<bool>(&reply.success_value);
  ASSERT_NE(value, nullptr);
  EXPECT_FALSE(*value);
  ASSERT_EQ(events_->size(), 1u);
  const auto* map = AsMap((*events_)[0]);
  ASSERT_NE(map, nullptr);
  EXPECT_EQ(ReadString(*map, "type"), "updateError");
  EXPECT_EQ(ReadString(*map, "code"),
            clingfy::updater::codes::kFeedUnreachable);
}

TEST_F(UpdaterRouterTest, NewerFeedEmitsCheckingThenUpdateAvailable) {
  StubFeedBody(
      "{\"version\": \"1.0.5\", \"build\": 7, \"versionFull\": \"1.0.5+7\","
      " \"channel\": \"dev\", \"platform\": \"windows-x64\","
      " \"url\": \"https://dl.example/Clingfy_Dev_Setup_1.0.5+7.exe\"}");
  const RecordedReply reply = Check(flutter::EncodableMap{
      {flutter::EncodableValue("feedUrl"),
       flutter::EncodableValue("https://feed.example/latest-windows.json")},
      {flutter::EncodableValue("channel"), flutter::EncodableValue("dev")},
  });
  ASSERT_TRUE(reply.success_called);
  const auto* value = std::get_if<bool>(&reply.success_value);
  ASSERT_NE(value, nullptr);
  EXPECT_TRUE(*value);

  ASSERT_EQ(EventTypes(),
            (std::vector<std::string>{"checking", "updateAvailable"}));
  const auto* map = AsMap((*events_)[1]);
  ASSERT_NE(map, nullptr);
  EXPECT_EQ(ReadString(*map, "version"), "1.0.5");
  EXPECT_EQ(ReadString(*map, "build"), "7");
  EXPECT_EQ(ReadString(*map, "url"),
            "https://dl.example/Clingfy_Dev_Setup_1.0.5+7.exe");
  EXPECT_EQ(ReadString(*map, "versionFull"), "1.0.5+7");
}

TEST_F(UpdaterRouterTest, CurrentVersionEmitsNoUpdateAvailable) {
  StubFeedBody(
      "{\"version\": \"1.0.4\", \"build\": 5, \"channel\": \"dev\","
      " \"platform\": \"windows-x64\","
      " \"url\": \"https://dl.example/Clingfy_Dev_Setup_1.0.4+5.exe\"}");
  const RecordedReply reply = Check(flutter::EncodableMap{
      {flutter::EncodableValue("feedUrl"),
       flutter::EncodableValue("https://feed.example/latest-windows.json")},
      {flutter::EncodableValue("channel"), flutter::EncodableValue("dev")},
  });
  ASSERT_TRUE(reply.success_called);
  ASSERT_EQ(EventTypes(),
            (std::vector<std::string>{"checking", "noUpdateAvailable"}));
  const auto* map = AsMap((*events_)[1]);
  ASSERT_NE(map, nullptr);
  EXPECT_EQ(ReadString(*map, "version"), "1.0.4");
}

TEST_F(UpdaterRouterTest, FetchFailureEmitsFeedUnreachable) {
  clingfy::updater::SetUpdateFetcherForTesting(
      [](const std::string& /*url*/) {
        clingfy::updater::FetchResult result;
        result.ok = false;
        result.error = "feed returned HTTP 503";
        return result;
      });
  Check(flutter::EncodableMap{
      {flutter::EncodableValue("feedUrl"),
       flutter::EncodableValue("https://feed.example/latest-windows.json")},
  });
  ASSERT_EQ(EventTypes(),
            (std::vector<std::string>{"checking", "updateError"}));
  const auto* map = AsMap((*events_)[1]);
  ASSERT_NE(map, nullptr);
  EXPECT_EQ(ReadString(*map, "code"),
            clingfy::updater::codes::kFeedUnreachable);
  EXPECT_EQ(ReadString(*map, "message"), "feed returned HTTP 503");
}

TEST_F(UpdaterRouterTest, MalformedFeedEmitsFeedMalformed) {
  StubFeedBody("<html>blob storage error</html>");
  Check(flutter::EncodableMap{
      {flutter::EncodableValue("feedUrl"),
       flutter::EncodableValue("https://feed.example/latest-windows.json")},
  });
  ASSERT_EQ(EventTypes(),
            (std::vector<std::string>{"checking", "updateError"}));
  const auto* map = AsMap((*events_)[1]);
  ASSERT_NE(map, nullptr);
  EXPECT_EQ(ReadString(*map, "code"), clingfy::updater::codes::kFeedMalformed);
}

TEST_F(UpdaterRouterTest, ChannelMismatchEmitsFeedMismatch) {
  StubFeedBody(
      "{\"version\": \"1.0.5\", \"build\": 7, \"channel\": \"prod\","
      " \"platform\": \"windows-x64\","
      " \"url\": \"https://dl.example/Clingfy_Setup_1.0.5.exe\"}");
  Check(flutter::EncodableMap{
      {flutter::EncodableValue("feedUrl"),
       flutter::EncodableValue("https://feed.example/latest-windows.json")},
      {flutter::EncodableValue("channel"), flutter::EncodableValue("dev")},
  });
  ASSERT_EQ(EventTypes(),
            (std::vector<std::string>{"checking", "updateError"}));
  const auto* map = AsMap((*events_)[1]);
  ASSERT_NE(map, nullptr);
  EXPECT_EQ(ReadString(*map, "code"), clingfy::updater::codes::kFeedMismatch);
}

TEST_F(UpdaterRouterTest, VersionFullIsDerivedNeverForwardedFromTheFeed) {
  // The feed's versionFull is free-form remote text and the Dart dialog
  // prefers it — the emitted value must be rebuilt from the validated
  // version + build, so a compromised feed cannot inject prose into the
  // trusted update dialog.
  StubFeedBody(
      "{\"version\": \"1.0.5\", \"build\": 7,"
      " \"versionFull\": \"1.0.5. IMPORTANT: disable your antivirus\","
      " \"channel\": \"dev\", \"platform\": \"windows-x64\","
      " \"url\": \"https://dl.example/Clingfy_Dev_Setup_1.0.5+7.exe\"}");
  Check(flutter::EncodableMap{
      {flutter::EncodableValue("feedUrl"),
       flutter::EncodableValue("https://feed.example/latest-windows.json")},
      {flutter::EncodableValue("channel"), flutter::EncodableValue("dev")},
  });
  ASSERT_EQ(EventTypes(),
            (std::vector<std::string>{"checking", "updateAvailable"}));
  const auto* map = AsMap((*events_)[1]);
  ASSERT_NE(map, nullptr);
  EXPECT_EQ(ReadString(*map, "versionFull"), "1.0.5+7");
}

TEST_F(UpdaterRouterTest, InvalidUtf8InFeedFieldsIsSanitizedInEvents) {
  // An invalid byte anywhere in an emitted string would make Dart's
  // StandardMessageCodec decode throw and silently drop the event —
  // stranding the About UI on "checking". The mismatch message embeds the
  // feed's channel field; feed it garbage bytes.
  StubFeedBody(
      "{\"version\": \"1.0.5\", \"build\": 7,"
      " \"channel\": \"pro\xFF"
      "d\", \"platform\": \"windows-x64\","
      " \"url\": \"https://dl.example/i.exe\"}");
  Check(flutter::EncodableMap{
      {flutter::EncodableValue("feedUrl"),
       flutter::EncodableValue("https://feed.example/latest-windows.json")},
      {flutter::EncodableValue("channel"), flutter::EncodableValue("dev")},
  });
  ASSERT_EQ(EventTypes(),
            (std::vector<std::string>{"checking", "updateError"}));
  const auto* map = AsMap((*events_)[1]);
  ASSERT_NE(map, nullptr);
  EXPECT_EQ(ReadString(*map, "code"), clingfy::updater::codes::kFeedMismatch);
  const std::string message = ReadString(*map, "message");
  EXPECT_EQ(message.find('\xFF'), std::string::npos)
      << "raw invalid byte leaked into the event payload";
  EXPECT_NE(message.find("pro?d"), std::string::npos)
      << "sanitized channel name should appear in the message";
}

TEST_F(UpdaterRouterTest, MissingVersionResourceEmitsVersionUnknown) {
  // Force the "no version resource" path (deterministic regardless of
  // whether the test exe happens to carry one).
  clingfy::updater::SetCurrentVersionForTesting(std::nullopt);
  StubFeedBody(
      "{\"version\": \"1.0.5\", \"platform\": \"windows-x64\","
      " \"url\": \"https://dl.example/i.exe\"}");
  Check(flutter::EncodableMap{
      {flutter::EncodableValue("feedUrl"),
       flutter::EncodableValue("https://feed.example/latest-windows.json")},
  });
  ASSERT_EQ(EventTypes(),
            (std::vector<std::string>{"checking", "updateError"}));
  const auto* map = AsMap((*events_)[1]);
  ASSERT_NE(map, nullptr);
  EXPECT_EQ(ReadString(*map, "code"),
            clingfy::updater::codes::kVersionUnknown);
}

}  // namespace
}  // namespace clingfy::bridge
