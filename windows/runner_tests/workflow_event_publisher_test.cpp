#include "Bridge/workflow_event_publisher.h"

#include <gtest/gtest.h>

#include <flutter/event_sink.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <vector>

namespace clingfy::bridge {
namespace {

// Captures whatever the publisher emits so tests can inspect both the
// fact of emission and the EncodableMap payload. The captured events
// live in a `shared_ptr<vector>` so they outlive the sink itself —
// `ClearSink` destroys the unique_ptr the publisher holds, and a
// previous design captured into a `this->events` field which became a
// use-after-free dangling read.
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
  WorkflowEventPublisher::Instance().SetSink(
      std::make_unique<RecordingSink>(events));
  return events;
}

class WorkflowEventPublisherTest : public ::testing::Test {
 protected:
  void TearDown() override {
    // Reset the singleton's sink so other tests don't see emissions
    // captured by this fixture's RecordingSink (which is about to go
    // out of scope).
    WorkflowEventPublisher::Instance().ClearSink();
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

TEST_F(WorkflowEventPublisherTest, NoSinkDropsEventsSilently) {
  // Sanity: emitting before a Dart listener attaches must not crash.
  WorkflowEventPublisher::Instance().EmitRecordingStarted("no-sink");
}

TEST_F(WorkflowEventPublisherTest, RecordingStartedShape) {
  auto events = InstallRecordingSink();
  WorkflowEventPublisher::Instance().EmitRecordingStarted("sess-42");
  ASSERT_EQ(events->size(), 1u);
  const auto* map = AsMap((*events)[0]);
  ASSERT_NE(map, nullptr);
  EXPECT_EQ(ReadString(*map, "type"), "recordingStarted");
  EXPECT_EQ(ReadString(*map, "sessionId"), "sess-42");
}

TEST_F(WorkflowEventPublisherTest, RecordingFinalizedIncludesProjectPath) {
  auto events = InstallRecordingSink();
  WorkflowEventPublisher::Instance().EmitRecordingFinalized(
      "sess-7", R"(C:\Users\me\AppData\Local\Clingfy\recordings\sess-7.clingfyproj)");
  ASSERT_EQ(events->size(), 1u);
  const auto* map = AsMap((*events)[0]);
  ASSERT_NE(map, nullptr);
  EXPECT_EQ(ReadString(*map, "type"), "recordingFinalized");
  EXPECT_EQ(ReadString(*map, "sessionId"), "sess-7");
  EXPECT_NE(ReadString(*map, "projectPath").find("sess-7.clingfyproj"),
            std::string::npos)
      << "projectPath must round-trip verbatim — Dart fails finalize "
         "when this field is missing.";
}

TEST_F(WorkflowEventPublisherTest, RecordingFailedShape) {
  auto events = InstallRecordingSink();
  WorkflowEventPublisher::Instance().EmitRecordingFailed(
      "sess-x", "start", "BAD_ARGS", "missing sessionId");
  ASSERT_EQ(events->size(), 1u);
  const auto* map = AsMap((*events)[0]);
  ASSERT_NE(map, nullptr);
  EXPECT_EQ(ReadString(*map, "type"), "recordingFailed");
  EXPECT_EQ(ReadString(*map, "sessionId"), "sess-x");
  EXPECT_EQ(ReadString(*map, "stage"), "start");
  EXPECT_EQ(ReadString(*map, "code"), "BAD_ARGS");
  // macOS uses `error` for the message key; mirror it byte-for-byte
  // so Dart needs no Windows-specific branching.
  EXPECT_EQ(ReadString(*map, "error"), "missing sessionId");
}

TEST_F(WorkflowEventPublisherTest, RecordingPausedAndResumedShapes) {
  auto events = InstallRecordingSink();
  WorkflowEventPublisher::Instance().EmitRecordingPaused("sess-p");
  WorkflowEventPublisher::Instance().EmitRecordingResumed("sess-p");
  ASSERT_EQ(events->size(), 2u);

  const auto* paused = AsMap((*events)[0]);
  ASSERT_NE(paused, nullptr);
  EXPECT_EQ(ReadString(*paused, "type"), "recordingPaused");
  EXPECT_EQ(ReadString(*paused, "sessionId"), "sess-p");

  const auto* resumed = AsMap((*events)[1]);
  ASSERT_NE(resumed, nullptr);
  EXPECT_EQ(ReadString(*resumed, "type"), "recordingResumed");
  EXPECT_EQ(ReadString(*resumed, "sessionId"), "sess-p");
}

TEST_F(WorkflowEventPublisherTest, RecordingWarningShape) {
  auto events = InstallRecordingSink();
  WorkflowEventPublisher::Instance().EmitRecordingWarning(
      "sess-q", "loopback endpoint silenced for 3s");
  ASSERT_EQ(events->size(), 1u);
  const auto* map = AsMap((*events)[0]);
  ASSERT_NE(map, nullptr);
  EXPECT_EQ(ReadString(*map, "type"), "recordingWarning");
  EXPECT_EQ(ReadString(*map, "sessionId"), "sess-q");
  EXPECT_EQ(ReadString(*map, "message"),
            "loopback endpoint silenced for 3s");
}

TEST_F(WorkflowEventPublisherTest, ClearSinkStopsEmissions) {
  auto events = InstallRecordingSink();
  WorkflowEventPublisher::Instance().EmitRecordingStarted("sess-1");
  WorkflowEventPublisher::Instance().ClearSink();
  WorkflowEventPublisher::Instance().EmitRecordingStarted("sess-2");
  // First call landed; second was silently dropped. The shared events
  // vector outlives the sink's destruction inside ClearSink, so this
  // observation is safe.
  EXPECT_EQ(events->size(), 1u);
  EXPECT_FALSE(WorkflowEventPublisher::Instance().has_sink());
}

}  // namespace
}  // namespace clingfy::bridge
