#include "Capture/recording_session_state.h"

#include <gtest/gtest.h>

#include <string>

namespace clingfy::capture {
namespace {

TEST(RecordingSessionStateTest, StartsIdleWithNoSession) {
  RecordingSessionState state;
  EXPECT_EQ(state.state(), RecordingState::kIdle);
  EXPECT_TRUE(state.session_id().empty());
  EXPECT_FALSE(state.IsActive());
}

TEST(RecordingSessionStateTest, HappyPathTransitions) {
  RecordingSessionState state;

  ASSERT_TRUE(state.BeginStart("sess-1"));
  EXPECT_EQ(state.state(), RecordingState::kStarting);
  EXPECT_EQ(state.session_id(), "sess-1");
  EXPECT_TRUE(state.IsActive());

  ASSERT_TRUE(state.MarkStarted());
  EXPECT_EQ(state.state(), RecordingState::kRecording);
  EXPECT_TRUE(state.IsActive());

  ASSERT_TRUE(state.BeginStop());
  EXPECT_EQ(state.state(), RecordingState::kStopping);
  EXPECT_TRUE(state.IsActive());

  ASSERT_TRUE(state.MarkStopped());
  EXPECT_EQ(state.state(), RecordingState::kStopped);
  EXPECT_TRUE(state.session_id().empty())
      << "MarkStopped must clear the session id so a Reset->BeginStart loop "
         "cannot reuse a stale identifier.";
  EXPECT_FALSE(state.IsActive());
}

TEST(RecordingSessionStateTest, BeginStartRejectsWhileActive) {
  RecordingSessionState state;
  ASSERT_TRUE(state.BeginStart("sess-1"));
  EXPECT_FALSE(state.BeginStart("sess-2"))
      << "Starting a second session while the first is in Starting must fail.";

  ASSERT_TRUE(state.MarkStarted());
  EXPECT_FALSE(state.BeginStart("sess-3"))
      << "Starting a session while the first is Recording must fail.";

  ASSERT_TRUE(state.BeginStop());
  EXPECT_FALSE(state.BeginStart("sess-4"))
      << "Starting a session while the first is Stopping must fail.";
}

TEST(RecordingSessionStateTest, BeginStartReusesTerminalState) {
  RecordingSessionState state;
  ASSERT_TRUE(state.BeginStart("sess-1"));
  ASSERT_TRUE(state.MarkStarted());
  ASSERT_TRUE(state.BeginStop());
  ASSERT_TRUE(state.MarkStopped());

  // Stopped -> Starting is allowed without an explicit Reset so a defensive
  // caller can fire start-after-stop without an extra round-trip.
  EXPECT_TRUE(state.BeginStart("sess-2"));
  EXPECT_EQ(state.session_id(), "sess-2");
}

TEST(RecordingSessionStateTest, BeginStartAfterFailure) {
  RecordingSessionState state;
  ASSERT_TRUE(state.BeginStart("sess-1"));
  state.MarkFailed();
  EXPECT_EQ(state.state(), RecordingState::kFailed);

  EXPECT_TRUE(state.BeginStart("sess-2"))
      << "Failed is a reusable terminal state, like Stopped.";
}

TEST(RecordingSessionStateTest, BeginStopFromIdleIsRejected) {
  RecordingSessionState state;
  EXPECT_FALSE(state.BeginStop());
  EXPECT_EQ(state.state(), RecordingState::kIdle);
}

TEST(RecordingSessionStateTest, BeginStopFromStartingIsRejected) {
  RecordingSessionState state;
  ASSERT_TRUE(state.BeginStart("sess-1"));
  EXPECT_FALSE(state.BeginStop())
      << "A session must finish starting before it can stop — the engine "
         "owns capture and encoder handles that aren't ready yet.";
}

TEST(RecordingSessionStateTest, MarkStartedRequiresStartingState) {
  RecordingSessionState state;
  EXPECT_FALSE(state.MarkStarted());
  EXPECT_FALSE(state.MarkStopped());
}

TEST(RecordingSessionStateTest, MarkFailedFromAnyState) {
  RecordingSessionState state;
  state.MarkFailed();
  EXPECT_EQ(state.state(), RecordingState::kFailed);

  // Idempotent.
  state.MarkFailed();
  EXPECT_EQ(state.state(), RecordingState::kFailed);
}

TEST(RecordingSessionStateTest, ResetClearsTerminalState) {
  RecordingSessionState state;
  ASSERT_TRUE(state.BeginStart("sess-1"));
  ASSERT_TRUE(state.MarkStarted());
  ASSERT_TRUE(state.BeginStop());
  ASSERT_TRUE(state.MarkStopped());

  ASSERT_TRUE(state.Reset());
  EXPECT_EQ(state.state(), RecordingState::kIdle);
  EXPECT_TRUE(state.session_id().empty());
}

TEST(RecordingSessionStateTest, ResetRefusedFromActiveState) {
  RecordingSessionState state;
  ASSERT_TRUE(state.BeginStart("sess-1"));
  EXPECT_FALSE(state.Reset())
      << "Resetting while a session is still active would leak capture and "
         "encoder ownership — must finish or fail the session first.";
}

TEST(RecordingSessionStateTest, ToStringMapsEachState) {
  EXPECT_STREQ(ToString(RecordingState::kIdle), "idle");
  EXPECT_STREQ(ToString(RecordingState::kStarting), "starting");
  EXPECT_STREQ(ToString(RecordingState::kRecording), "recording");
  EXPECT_STREQ(ToString(RecordingState::kStopping), "stopping");
  EXPECT_STREQ(ToString(RecordingState::kStopped), "stopped");
  EXPECT_STREQ(ToString(RecordingState::kFailed), "failed");
}

}  // namespace
}  // namespace clingfy::capture
