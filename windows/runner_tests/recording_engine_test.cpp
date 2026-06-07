#include "Capture/recording_engine.h"

#include <gtest/gtest.h>

#include <string>

#include "Bridge/native_error_codes.h"
#include "Capture/wgc_display_capture_backend.h"
#include "Capture/windows_selection_state.h"

namespace clingfy::capture {
namespace {

// Engine is a process-level singleton. Each test resets it to a clean Idle
// state so test ordering does not leak. The selection-state singleton is reset
// too so a window/area-mode test cannot leak its target mode into the next
// case (which assumes the default explicit-display mode).
class RecordingEngineTest : public ::testing::Test {
 protected:
  void SetUp() override {
    RecordingEngine::Instance().ForceResetForTesting();
    WindowsSelectionState::Instance().ResetForTesting();
  }
  void TearDown() override {
    RecordingEngine::Instance().ForceResetForTesting();
    WindowsSelectionState::Instance().ResetForTesting();
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

// === Phase 7.1 window-mode target gating ===================================
//
// Window recording lifts the kBadMode gate for window modes but still resolves
// + validates the target before any capture pipeline setup, so these paths are
// GPU-independent (they fail before the D3D device is created).

TEST_F(RecordingEngineTest, StartRejectsWindowModeWithNoTarget) {
  WindowsSelectionState::Instance().SetTargetMode(
      DisplayTargetMode::kSingleAppWindow);
  // No window picked → friendly target error, not kBadMode (the gate IS lifted
  // for window modes) and not a crash.
  auto error = RecordingEngine::Instance().Start(ValidRequest());
  ASSERT_TRUE(error.has_value());
  EXPECT_EQ(error->code, clingfy::bridge::error::kTargetError);
  EXPECT_FALSE(RecordingEngine::Instance().IsRecording());
}

TEST_F(RecordingEngineTest, StartRejectsWindowModeWithStaleHwnd) {
  WindowsSelectionState::Instance().SetTargetMode(
      DisplayTargetMode::kAppWindow);
  // An int64 that does not name a live window → ResolveAppWindow returns
  // nullopt → friendly target error (the gate was passed; resolution failed).
  WindowsSelectionState::Instance().SetAppWindowId(std::int64_t{0xABCD1234});
  auto error = RecordingEngine::Instance().Start(ValidRequest());
  ASSERT_TRUE(error.has_value());
  EXPECT_EQ(error->code, clingfy::bridge::error::kTargetError);
  EXPECT_FALSE(RecordingEngine::Instance().IsRecording());
}

TEST_F(RecordingEngineTest, StartRejectsAreaModeWithNoRegion) {
  // The area gate is lifted (Phase 7.2), but with no region picked Start fails
  // with a friendly target error, not kBadMode — GPU-free (fails before D3D).
  WindowsSelectionState::Instance().SetTargetMode(
      DisplayTargetMode::kAreaRecording);
  auto error = RecordingEngine::Instance().Start(ValidRequest());
  ASSERT_TRUE(error.has_value());
  EXPECT_EQ(error->code, clingfy::bridge::error::kTargetError);
  EXPECT_FALSE(RecordingEngine::Instance().IsRecording());
}

TEST_F(RecordingEngineTest, StartStillRejectsMouseFollowMode) {
  // Mouse-follow modes remain unsupported (kBadMode) — only display, window,
  // and area are live.
  WindowsSelectionState::Instance().SetTargetMode(
      DisplayTargetMode::kFollowMouse);
  auto error = RecordingEngine::Instance().Start(ValidRequest());
  ASSERT_TRUE(error.has_value());
  EXPECT_EQ(error->code, clingfy::bridge::error::kBadMode);
}

TEST_F(RecordingEngineTest, StartAcceptsAreaModeWithValidRegion) {
  // End-to-end area capture: record a small region of the primary monitor. Like
  // StartTransitionsToRecording this drives the real WGC + crop + encoder
  // pipeline, so it needs a usable GPU/encoder (it is not a GTEST_SKIP-gated
  // test; the existing display test already proves the box has one).
  WindowsSelectionState::Instance().SetTargetMode(
      DisplayTargetMode::kAreaRecording);
  AreaRegion region;
  region.display_id = std::nullopt;  // primary
  region.x = 0;
  region.y = 0;
  region.width = 320;
  region.height = 240;
  WindowsSelectionState::Instance().SetAreaRegion(region);

  auto error = RecordingEngine::Instance().Start(ValidRequest());
  ASSERT_FALSE(error.has_value()) << error->message;
  EXPECT_TRUE(RecordingEngine::Instance().IsRecording());
  ASSERT_FALSE(RecordingEngine::Instance().Stop("sess-test").has_value());
}

// The encoder config and the WGC frame copy both clamp capture dimensions to
// even through this one helper, so an odd-sized window's encoder input always
// equals the surface size it is handed (the Phase 7.1 odd-window fix). Pure,
// no GPU.
TEST(EvenCaptureDimensionTest, ClampsOddDownAndLeavesEvenUnchanged) {
  EXPECT_EQ(EvenCaptureDimension(801u), 800u);
  EXPECT_EQ(EvenCaptureDimension(1081u), 1080u);
  EXPECT_EQ(EvenCaptureDimension(800u), 800u);
  EXPECT_EQ(EvenCaptureDimension(1920u), 1920u);
  EXPECT_EQ(EvenCaptureDimension(1u), 0u);
  EXPECT_EQ(EvenCaptureDimension(0u), 0u);
}

// ResolveCropBox is the single source of truth shared by the engine encoder
// sizing and the backend frame crop (Phase 7.2 area recording): clamp the
// requested rect into the surface, then even-align. Pure, no GPU.
TEST(ResolveCropBoxTest, ClampsToBoundsAndEvenAligns) {
  // Fully inside, even dims preserved.
  const auto inside = ResolveCropBox(1920, 1080, 100, 50, 640, 480);
  EXPECT_EQ(inside.x, 100u);
  EXPECT_EQ(inside.y, 50u);
  EXPECT_EQ(inside.width, 640u);
  EXPECT_EQ(inside.height, 480u);

  // Odd request dims clamp down to even.
  const auto odd = ResolveCropBox(1920, 1080, 0, 0, 801, 601);
  EXPECT_EQ(odd.width, 800u);
  EXPECT_EQ(odd.height, 600u);

  // Oversized request clamps to what fits from the (in-bounds) origin.
  const auto over = ResolveCropBox(1920, 1080, 1900, 1070, 500, 500);
  EXPECT_EQ(over.x, 1900u);
  EXPECT_EQ(over.y, 1070u);
  EXPECT_EQ(over.width, 20u);
  EXPECT_EQ(over.height, 10u);

  // Negative origin clamps to 0.
  const auto neg = ResolveCropBox(1920, 1080, -50, -30, 400, 300);
  EXPECT_EQ(neg.x, 0u);
  EXPECT_EQ(neg.y, 0u);
  EXPECT_EQ(neg.width, 400u);
  EXPECT_EQ(neg.height, 300u);

  // Origin past the edge -> empty region.
  const auto off = ResolveCropBox(1920, 1080, 5000, 0, 100, 100);
  EXPECT_EQ(off.width, 0u);

  // Empty surface -> empty box.
  const auto none = ResolveCropBox(0, 0, 0, 0, 100, 100);
  EXPECT_EQ(none.width, 0u);
  EXPECT_EQ(none.height, 0u);
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
