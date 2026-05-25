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

// === Phase 4 pause / resume happy + sad paths ==============================
//
// The engine's Pause / Resume are idempotent at the engine level and
// surface a structured kNotRecording when called outside an active
// session. Mismatched sessionId returns kInvalidRecordingState
// without touching the live session.

TEST_F(RecordingEngineTest, PauseAndResumeIdempotentWhenIdle) {
  // No recording → both pause + resume return kNotRecording so the
  // Dart UI's defensive double-tap doesn't silently succeed.
  auto pause_err = RecordingEngine::Instance().Pause("any");
  ASSERT_TRUE(pause_err.has_value());
  EXPECT_EQ(pause_err->code, clingfy::bridge::error::kNotRecording);
  auto resume_err = RecordingEngine::Instance().Resume("any");
  ASSERT_TRUE(resume_err.has_value());
  EXPECT_EQ(resume_err->code, clingfy::bridge::error::kNotRecording);
}

TEST_F(RecordingEngineTest, PauseTransitionsToPaused) {
  ASSERT_FALSE(RecordingEngine::Instance().Start(ValidRequest()).has_value());
  ASSERT_FALSE(RecordingEngine::Instance().Pause("sess-test").has_value());
  EXPECT_EQ(RecordingEngine::Instance().state(),
            RecordingState::kPaused);
  EXPECT_FALSE(RecordingEngine::Instance().IsRecording())
      << "While paused, IsRecording() must report false — the Dart UI "
         "uses this to flip the indicator from 'recording' to 'paused'.";
}

TEST_F(RecordingEngineTest, ResumeReturnsToRecording) {
  ASSERT_FALSE(RecordingEngine::Instance().Start(ValidRequest()).has_value());
  ASSERT_FALSE(RecordingEngine::Instance().Pause("sess-test").has_value());
  ASSERT_FALSE(RecordingEngine::Instance().Resume("sess-test").has_value());
  EXPECT_EQ(RecordingEngine::Instance().state(),
            RecordingState::kRecording);
  EXPECT_TRUE(RecordingEngine::Instance().IsRecording());
}

TEST_F(RecordingEngineTest, DoublePauseIsIdempotent) {
  ASSERT_FALSE(RecordingEngine::Instance().Start(ValidRequest()).has_value());
  ASSERT_FALSE(RecordingEngine::Instance().Pause("sess-test").has_value());
  // Already paused → second pause returns success without touching
  // the capture pipeline.
  EXPECT_FALSE(RecordingEngine::Instance().Pause("sess-test").has_value());
  EXPECT_EQ(RecordingEngine::Instance().state(),
            RecordingState::kPaused);
}

TEST_F(RecordingEngineTest, DoubleResumeIsIdempotent) {
  ASSERT_FALSE(RecordingEngine::Instance().Start(ValidRequest()).has_value());
  EXPECT_FALSE(RecordingEngine::Instance().Resume("sess-test").has_value())
      << "Resume while already recording must be a no-op success — the "
         "Dart UI may fire it defensively after a session restart.";
}

TEST_F(RecordingEngineTest, PauseWithMismatchedSessionIdRefuses) {
  ASSERT_FALSE(RecordingEngine::Instance().Start(ValidRequest()).has_value());
  auto err = RecordingEngine::Instance().Pause("other-session");
  ASSERT_TRUE(err.has_value());
  EXPECT_EQ(err->code, clingfy::bridge::error::kInvalidRecordingState);
  // Live session unaffected — still Recording, not Paused.
  EXPECT_EQ(RecordingEngine::Instance().state(),
            RecordingState::kRecording);
}

TEST_F(RecordingEngineTest, StopFromPausedFinalizesCleanly) {
  ASSERT_FALSE(RecordingEngine::Instance().Start(ValidRequest()).has_value());
  ASSERT_FALSE(RecordingEngine::Instance().Pause("sess-test").has_value());
  EXPECT_FALSE(RecordingEngine::Instance().Stop("sess-test").has_value());
  EXPECT_EQ(RecordingEngine::Instance().state(),
            RecordingState::kIdle);
}

}  // namespace
}  // namespace clingfy::capture
