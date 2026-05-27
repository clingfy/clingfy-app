#include "Bridge/project_open_coordinator.h"

#include <gtest/gtest.h>

#include <flutter/event_sink.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <vector>

#include "Bridge/workflow_event_publisher.h"
#include "test_support.h"

namespace clingfy::bridge {
namespace {

// Same shape as workflow_event_publisher_test's RecordingSink — duplicated
// here so each test file is self-contained.
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
  void ErrorInternal(const std::string&, const std::string&,
                     const flutter::EncodableValue*) override {}
  void EndOfStreamInternal() override {}

 private:
  std::shared_ptr<EventList> events_;
};

std::shared_ptr<RecordingSink::EventList> InstallSink() {
  auto events = std::make_shared<RecordingSink::EventList>();
  WorkflowEventPublisher::Instance().SetSink(
      std::make_unique<RecordingSink>(events));
  return events;
}

const flutter::EncodableMap* AsMap(const flutter::EncodableValue& v) {
  return std::get_if<flutter::EncodableMap>(&v);
}

std::string ReadString(const flutter::EncodableMap& m, const std::string& k) {
  const auto it = m.find(flutter::EncodableValue(k));
  if (it == m.end()) return {};
  const auto* s = std::get_if<std::string>(&it->second);
  return s ? *s : std::string{};
}

class ProjectOpenCoordinatorTest : public ::testing::Test {
 protected:
  void SetUp() override {
    ProjectOpenCoordinator::Instance().ResetForTesting();
    WorkflowEventPublisher::Instance().ClearSink();
  }
  void TearDown() override {
    WorkflowEventPublisher::Instance().ClearSink();
    ProjectOpenCoordinator::Instance().ResetForTesting();
  }
};

TEST_F(ProjectOpenCoordinatorTest, EnqueueWithoutSinkQueues) {
  auto events = InstallSink();
  // Drain whatever the SetSink-before-Reset might have created;
  // intentionally reset AFTER attaching to start clean.
  ProjectOpenCoordinator::Instance().ResetForTesting();

  ProjectOpenCoordinator::Instance().Enqueue("C:\\path\\a.clingfyproj");
  test_support::PumpMessages();
  EXPECT_TRUE(events->empty())
      << "Enqueue must NOT emit until the coordinator sees OnSinkAttached.";
  EXPECT_FALSE(ProjectOpenCoordinator::Instance().has_sink());
}

TEST_F(ProjectOpenCoordinatorTest, OnSinkAttachedFlushesQueue) {
  ProjectOpenCoordinator::Instance().Enqueue("C:\\path\\a.clingfyproj");
  ProjectOpenCoordinator::Instance().Enqueue("C:\\path\\b.clingfyproj");

  auto events = InstallSink();
  ProjectOpenCoordinator::Instance().OnSinkAttached();
  test_support::PumpMessages();

  ASSERT_EQ(events->size(), 2u);
  const auto* a = AsMap((*events)[0]);
  const auto* b = AsMap((*events)[1]);
  ASSERT_NE(a, nullptr);
  ASSERT_NE(b, nullptr);
  EXPECT_EQ(ReadString(*a, "type"), "openProjectRequest");
  EXPECT_EQ(ReadString(*a, "projectPath"), "C:\\path\\a.clingfyproj");
  EXPECT_EQ(ReadString(*b, "type"), "openProjectRequest");
  EXPECT_EQ(ReadString(*b, "projectPath"), "C:\\path\\b.clingfyproj");
}

TEST_F(ProjectOpenCoordinatorTest, EnqueueAfterAttachEmitsImmediately) {
  auto events = InstallSink();
  ProjectOpenCoordinator::Instance().OnSinkAttached();
  ProjectOpenCoordinator::Instance().Enqueue("C:\\path\\c.clingfyproj");
  test_support::PumpMessages();

  ASSERT_EQ(events->size(), 1u);
  const auto* m = AsMap((*events)[0]);
  ASSERT_NE(m, nullptr);
  EXPECT_EQ(ReadString(*m, "type"), "openProjectRequest");
  EXPECT_EQ(ReadString(*m, "projectPath"), "C:\\path\\c.clingfyproj");
}

TEST_F(ProjectOpenCoordinatorTest, DuplicatePendingEnqueuesAreDeduped) {
  ProjectOpenCoordinator::Instance().Enqueue("C:\\same.clingfyproj");
  ProjectOpenCoordinator::Instance().Enqueue("C:\\same.clingfyproj");
  ProjectOpenCoordinator::Instance().Enqueue("C:\\different.clingfyproj");

  auto events = InstallSink();
  ProjectOpenCoordinator::Instance().OnSinkAttached();
  test_support::PumpMessages();

  ASSERT_EQ(events->size(), 2u);
  EXPECT_EQ(ReadString(*AsMap((*events)[0]), "projectPath"),
            "C:\\same.clingfyproj");
  EXPECT_EQ(ReadString(*AsMap((*events)[1]), "projectPath"),
            "C:\\different.clingfyproj");
}

TEST_F(ProjectOpenCoordinatorTest, EmptyPathIsIgnored) {
  auto events = InstallSink();
  ProjectOpenCoordinator::Instance().OnSinkAttached();
  ProjectOpenCoordinator::Instance().Enqueue("");
  test_support::PumpMessages();
  EXPECT_TRUE(events->empty());
}

TEST_F(ProjectOpenCoordinatorTest, OnSinkDetachedSwitchesBackToQueueing) {
  auto events = InstallSink();
  ProjectOpenCoordinator::Instance().OnSinkAttached();
  ProjectOpenCoordinator::Instance().OnSinkDetached();
  EXPECT_FALSE(ProjectOpenCoordinator::Instance().has_sink());

  ProjectOpenCoordinator::Instance().Enqueue("C:\\queued.clingfyproj");
  test_support::PumpMessages();
  EXPECT_TRUE(events->empty());

  // Re-attach and flush.
  ProjectOpenCoordinator::Instance().OnSinkAttached();
  test_support::PumpMessages();
  ASSERT_EQ(events->size(), 1u);
  EXPECT_EQ(ReadString(*AsMap((*events)[0]), "projectPath"),
            "C:\\queued.clingfyproj");
}

}  // namespace
}  // namespace clingfy::bridge
