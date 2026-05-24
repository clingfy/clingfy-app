#include "Capture/recording_engine.h"

#include <gtest/gtest.h>

#include <string>

#include "Bridge/native_error_codes.h"

namespace clingfy::capture {
namespace {

// Engine is a process-level singleton. Each test resets it to a clean Idle
// state so test ordering does not leak.
class RecordingEngineTest : public ::testing::Test {
 protected:
  void SetUp() override { RecordingEngine::Instance().ForceResetForTesting(); }
  void TearDown() override {
    RecordingEngine::Instance().ForceResetForTesting();
  }
};

StartRecordingRequest ValidRequest() {
  StartRecordingRequest request;
  request.session_id = "sess-test";
  request.frame_rate = 30;
  return request;
}

TEST_F(RecordingEngineTest, FreshEngineReportsIdle) {
  EXPECT_EQ(RecordingEngine::Instance().state(), RecordingState::kIdle);
  EXPECT_FALSE(RecordingEngine::Instance().IsRecording());
  EXPECT_TRUE(RecordingEngine::Instance().session_id().empty());
}

TEST_F(RecordingEngineTest, StartTransitionsToRecording) {
  ASSERT_FALSE(RecordingEngine::Instance().Start(ValidRequest()).has_value());
  EXPECT_TRUE(RecordingEngine::Instance().IsRecording());
  EXPECT_EQ(RecordingEngine::Instance().session_id(), "sess-test");
}

TEST_F(RecordingEngineTest, StartRejectsEmptySessionId) {
  StartRecordingRequest request = ValidRequest();
  request.session_id.clear();
  auto error = RecordingEngine::Instance().Start(std::move(request));
  ASSERT_TRUE(error.has_value());
  EXPECT_EQ(error->code, clingfy::bridge::error::kBadArgs);
}

TEST_F(RecordingEngineTest, StartRejectsNonPositiveFrameRate) {
  StartRecordingRequest request = ValidRequest();
  request.frame_rate = 0;
  auto error = RecordingEngine::Instance().Start(std::move(request));
  ASSERT_TRUE(error.has_value());
  EXPECT_EQ(error->code, clingfy::bridge::error::kBadArgs);
}

TEST_F(RecordingEngineTest, StartTwiceReturnsAlreadyRecording) {
  ASSERT_FALSE(RecordingEngine::Instance().Start(ValidRequest()).has_value());
  auto error = RecordingEngine::Instance().Start(ValidRequest());
  ASSERT_TRUE(error.has_value());
  EXPECT_EQ(error->code, clingfy::bridge::error::kAlreadyRecording);
}

TEST_F(RecordingEngineTest, StopReturnsToIdle) {
  ASSERT_FALSE(RecordingEngine::Instance().Start(ValidRequest()).has_value());
  ASSERT_FALSE(RecordingEngine::Instance().Stop("sess-test").has_value());
  EXPECT_EQ(RecordingEngine::Instance().state(), RecordingState::kIdle);
  EXPECT_FALSE(RecordingEngine::Instance().IsRecording());
}

TEST_F(RecordingEngineTest, StopWithoutSessionIsIdempotent) {
  // A defensive double-stop from Dart must not leak a confusing toast.
  EXPECT_FALSE(RecordingEngine::Instance().Stop("").has_value());
  EXPECT_FALSE(RecordingEngine::Instance().Stop("sess-test").has_value());
  EXPECT_EQ(RecordingEngine::Instance().state(), RecordingState::kIdle);
}

TEST_F(RecordingEngineTest, StopWithMismatchedSessionIdReturnsError) {
  ASSERT_FALSE(RecordingEngine::Instance().Start(ValidRequest()).has_value());
  auto error = RecordingEngine::Instance().Stop("other-session");
  ASSERT_TRUE(error.has_value());
  EXPECT_EQ(error->code, clingfy::bridge::error::kInvalidRecordingState);
  // Session must remain active so the user can retry stop with the right id.
  EXPECT_TRUE(RecordingEngine::Instance().IsRecording());
}

TEST_F(RecordingEngineTest, StopWithEmptySessionIdIsTolerated) {
  // Phase 1 stopRecording carried no payload; the new engine must keep
  // accepting the legacy form so cached older Dart clients work.
  ASSERT_FALSE(RecordingEngine::Instance().Start(ValidRequest()).has_value());
  EXPECT_FALSE(RecordingEngine::Instance().Stop("").has_value());
  EXPECT_FALSE(RecordingEngine::Instance().IsRecording());
}

TEST_F(RecordingEngineTest, StartAfterStopIsAllowed) {
  ASSERT_FALSE(RecordingEngine::Instance().Start(ValidRequest()).has_value());
  ASSERT_FALSE(RecordingEngine::Instance().Stop("sess-test").has_value());

  StartRecordingRequest second = ValidRequest();
  second.session_id = "sess-test-2";
  EXPECT_FALSE(RecordingEngine::Instance().Start(std::move(second)).has_value());
  EXPECT_EQ(RecordingEngine::Instance().session_id(), "sess-test-2");
}

}  // namespace
}  // namespace clingfy::capture
