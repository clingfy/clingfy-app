#include "Capture/recording_engine.h"

#include <gtest/gtest.h>

#include <flutter/event_sink.h>

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "Bridge/native_error_codes.h"
#include "Bridge/workflow_event_publisher.h"
#include "Capture/wgc_display_capture_backend.h"
#include "Capture/windows_selection_state.h"
#include "test_support.h"

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
    // Drop any workflow-event sink a target-loss test installed so it cannot
    // leak into the next case (an ASSERT early-return skips a test's own
    // ClearSink). Idempotent when no sink is set.
    clingfy::bridge::WorkflowEventPublisher::Instance().ClearSink();
  }
};

// Captures workflow events emitted during a finalize so target-loss tests can
// assert the exact recordingWarning / recordingFinalized / recordingFailed
// shapes. Mirrors the sink in workflow_event_publisher_test.cpp; the captured
// list lives in a shared_ptr so it outlives the sink the publisher owns.
class EngineEventSink : public flutter::EventSink<flutter::EncodableValue> {
 public:
  using EventList = std::vector<flutter::EncodableValue>;
  explicit EngineEventSink(std::shared_ptr<EventList> events)
      : events_(std::move(events)) {}

 protected:
  void SuccessInternal(const flutter::EncodableValue* event) override {
    events_->push_back(event != nullptr ? *event : flutter::EncodableValue());
  }
  void ErrorInternal(const std::string&, const std::string&,
                     const flutter::EncodableValue*) override {}
  void EndOfStreamInternal() override {}

 private:
  std::shared_ptr<EventList> events_;
};

std::shared_ptr<EngineEventSink::EventList> InstallEngineSink() {
  auto events = std::make_shared<EngineEventSink::EventList>();
  clingfy::bridge::WorkflowEventPublisher::Instance().SetSink(
      std::make_unique<EngineEventSink>(events));
  return events;
}

bool HasEventType(const std::shared_ptr<EngineEventSink::EventList>& events,
                  const std::string& type) {
  for (const auto& value : *events) {
    const auto* map = std::get_if<flutter::EncodableMap>(&value);
    if (map == nullptr) continue;
    const auto it = map->find(flutter::EncodableValue(std::string("type")));
    if (it == map->end()) continue;
    const auto* s = std::get_if<std::string>(&it->second);
    if (s != nullptr && *s == type) return true;
  }
  return false;
}

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

// === Phase 7.4 target-loss (window closed / monitor unplugged mid-record) ===
//
// The backend raises GraphicsCaptureItem.Closed on target loss; the engine
// finalizes the partial recording exactly once. Firing a real OS window-close
// is not deterministic in a unit test, so these drive the real WGC + encoder
// pipeline (like StartTransitionsToRecording) and then invoke the engine's
// target-loss entry point directly — the finalize / exactly-once race logic is
// the part that matters and is fully exercised here.

TEST_F(RecordingEngineTest, TargetLostReturnsToIdle) {
  ASSERT_FALSE(RecordingEngine::Instance().Start(ValidRequest()).has_value());
  ASSERT_TRUE(RecordingEngine::Instance().IsRecording());
  RecordingEngine::Instance().HandleTargetLost("sess-test");
  EXPECT_EQ(RecordingEngine::Instance().state(), RecordingState::kIdle);
  EXPECT_FALSE(RecordingEngine::Instance().IsRecording());
}

TEST_F(RecordingEngineTest, TargetLostKeepsPartialWhenFramesCaptured) {
  ASSERT_FALSE(RecordingEngine::Instance().Start(ValidRequest()).has_value());
  // Wait for the real display capture to deliver at least one frame so the
  // partial is "keepable" — the user-chosen behavior is to keep what was
  // recorded with a friendly notice rather than discard it.
  std::uint64_t frames = 0;
  for (int i = 0; i < 300 && frames == 0; ++i) {
    frames = RecordingEngine::Instance().Diagnostics().frames_received;
    if (frames == 0) {
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
  }
  ASSERT_GT(frames, 0u)
      << "display capture delivered no frames within 3s; cannot exercise the "
         "keep-the-partial path";

  auto events = InstallEngineSink();
  RecordingEngine::Instance().HandleTargetLost("sess-test");
  clingfy::bridge::test_support::PumpMessages();

  EXPECT_TRUE(HasEventType(events, "recordingWarning"))
      << "the user is told why recording stopped";
  EXPECT_TRUE(HasEventType(events, "recordingFinalized"))
      << "the partial opens into preview/export";
  EXPECT_FALSE(HasEventType(events, "recordingFailed"));
  EXPECT_EQ(RecordingEngine::Instance().state(), RecordingState::kIdle);
}

TEST_F(RecordingEngineTest, TargetLostReportsEvenCaptureDimensions) {
  // The non-crop copy path pins the staging texture to the even-clamped initial
  // size, so the dims surfaced to the project manifest are always even (H.264).
  ASSERT_FALSE(RecordingEngine::Instance().Start(ValidRequest()).has_value());
  std::uint64_t frames = 0;
  for (int i = 0; i < 300 && frames == 0; ++i) {
    frames = RecordingEngine::Instance().Diagnostics().frames_received;
    if (frames == 0) {
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
  }
  ASSERT_GT(frames, 0u);
  const auto diag = RecordingEngine::Instance().Diagnostics();
  EXPECT_GT(diag.frame_width, 0u);
  EXPECT_GT(diag.frame_height, 0u);
  EXPECT_EQ(diag.frame_width % 2, 0u);
  EXPECT_EQ(diag.frame_height % 2, 0u);
  ASSERT_FALSE(RecordingEngine::Instance().Stop("sess-test").has_value());
}

TEST_F(RecordingEngineTest, BackendTargetLostCallbackRoutesToFinalize) {
  // Drives the REAL production wiring the direct-HandleTargetLost tests bypass:
  // Start installs SetTargetLostCallback on the backend; firing it must route
  // through PlatformThreadDispatcher::Post -> HandleTargetLost and finalize.
  ASSERT_FALSE(RecordingEngine::Instance().Start(ValidRequest()).has_value());
  ASSERT_TRUE(RecordingEngine::Instance().IsRecording());
  RecordingEngine::Instance().FireTargetLostForTesting();
  clingfy::bridge::test_support::PumpMessages();
  EXPECT_EQ(RecordingEngine::Instance().state(), RecordingState::kIdle);
  EXPECT_FALSE(RecordingEngine::Instance().IsRecording());
}

TEST_F(RecordingEngineTest, BackendTargetLostCallbackIsExactlyOnceVsUserStop) {
  // Fire the backend callback (real wiring) then a user Stop: exactly one
  // terminal outcome, no duplicate event, no double finalize.
  ASSERT_FALSE(RecordingEngine::Instance().Start(ValidRequest()).has_value());
  auto events = InstallEngineSink();
  RecordingEngine::Instance().FireTargetLostForTesting();
  clingfy::bridge::test_support::PumpMessages();
  const std::size_t after_loss = events->size();
  ASSERT_GT(after_loss, 0u);
  EXPECT_FALSE(RecordingEngine::Instance().Stop("sess-test").has_value());
  clingfy::bridge::test_support::PumpMessages();
  EXPECT_EQ(events->size(), after_loss);
  EXPECT_EQ(RecordingEngine::Instance().state(), RecordingState::kIdle);
}

TEST_F(RecordingEngineTest, TargetLostThenUserStopEmitsNoDuplicateEvents) {
  ASSERT_FALSE(RecordingEngine::Instance().Start(ValidRequest()).has_value());
  auto events = InstallEngineSink();

  RecordingEngine::Instance().HandleTargetLost("sess-test");
  clingfy::bridge::test_support::PumpMessages();
  const std::size_t after_loss = events->size();
  ASSERT_GT(after_loss, 0u) << "target loss emits a terminal outcome";

  // The user then presses Stop on the already-finalized session: a clean no-op
  // that emits nothing more. This is the exactly-once / no-double-finalize gate.
  EXPECT_FALSE(RecordingEngine::Instance().Stop("sess-test").has_value());
  clingfy::bridge::test_support::PumpMessages();
  EXPECT_EQ(events->size(), after_loss);
  EXPECT_EQ(RecordingEngine::Instance().state(), RecordingState::kIdle);
}

TEST_F(RecordingEngineTest, UserStopThenTargetLostEmitsNoDuplicateEvents) {
  ASSERT_FALSE(RecordingEngine::Instance().Start(ValidRequest()).has_value());
  auto events = InstallEngineSink();

  ASSERT_FALSE(RecordingEngine::Instance().Stop("sess-test").has_value());
  clingfy::bridge::test_support::PumpMessages();
  const std::size_t after_stop = events->size();  // recordingFinalized.

  // A Closed delivery that slipped through after the user's Stop must be a no-op
  // (the backend revokes on Stop, but an in-flight delivery can still land).
  RecordingEngine::Instance().HandleTargetLost("sess-test");
  clingfy::bridge::test_support::PumpMessages();
  EXPECT_EQ(events->size(), after_stop);
  EXPECT_EQ(RecordingEngine::Instance().state(), RecordingState::kIdle);
}

TEST_F(RecordingEngineTest, TargetLostWithMismatchedSessionKeepsRecording) {
  ASSERT_FALSE(RecordingEngine::Instance().Start(ValidRequest()).has_value());
  // A stale Closed from a previous target names a different session — ignore it
  // so the live recording is untouched.
  RecordingEngine::Instance().HandleTargetLost("some-old-session");
  EXPECT_TRUE(RecordingEngine::Instance().IsRecording());
  EXPECT_EQ(RecordingEngine::Instance().state(), RecordingState::kRecording);
  ASSERT_FALSE(RecordingEngine::Instance().Stop("sess-test").has_value());
}

// === Phase 8.1 cursor sidecar ==============================================
//
// These drive the real capture pipeline (like StartTransitionsToRecording) so
// the sampler actually opens its sidecar + the WGC cursor flip runs. They assert
// the engine-level wiring; the sampler/mapper internals are unit-tested
// separately (cursor_sampler_test / cursor_sample_mapper_test).

TEST_F(RecordingEngineTest, StartOpensCursorSidecar) {
  ASSERT_FALSE(RecordingEngine::Instance().Start(ValidRequest()).has_value());
  EXPECT_TRUE(RecordingEngine::Instance().cursor_enabled_for_testing())
      << "the sampler should start and the cursor be stripped on a healthy box";
  const std::string path =
      RecordingEngine::Instance().cursor_sidecar_path_for_testing();
  ASSERT_FALSE(path.empty());
  // The sampler wrote the header line on Open, so the temp sidecar exists now.
  EXPECT_TRUE(std::filesystem::exists(std::filesystem::u8path(path)));
  ASSERT_FALSE(RecordingEngine::Instance().Stop("sess-test").has_value());
}

TEST_F(RecordingEngineTest, StopMovesCursorSidecarOutOfTemp) {
  ASSERT_FALSE(RecordingEngine::Instance().Start(ValidRequest()).has_value());
  const std::string path =
      RecordingEngine::Instance().cursor_sidecar_path_for_testing();
  ASSERT_FALSE(path.empty());
  ASSERT_FALSE(RecordingEngine::Instance().Stop("sess-test").has_value());
  // TeardownPipeline stopped+flushed the sampler, then the project writer moved
  // the sidecar into the bundle — so the temp file is gone.
  EXPECT_FALSE(std::filesystem::exists(std::filesystem::u8path(path)))
      << "the cursor sidecar should be flushed + moved into the project bundle";
}

TEST_F(RecordingEngineTest, TargetLossFinalizesCursorSidecar) {
  ASSERT_FALSE(RecordingEngine::Instance().Start(ValidRequest()).has_value());
  const std::string path =
      RecordingEngine::Instance().cursor_sidecar_path_for_testing();
  ASSERT_FALSE(path.empty());
  // A target loss runs the same teardown→finalize, so the sidecar is flushed +
  // bundled (keep-partial) — the temp file is gone, no crash, back to Idle.
  RecordingEngine::Instance().HandleTargetLost("sess-test");
  EXPECT_EQ(RecordingEngine::Instance().state(), RecordingState::kIdle);
  EXPECT_FALSE(std::filesystem::exists(std::filesystem::u8path(path)));
}

TEST_F(RecordingEngineTest, TargetLostWhenIdleIsNoOp) {
  // No active session → nothing to finalize, no crash, no events.
  auto events = InstallEngineSink();
  RecordingEngine::Instance().HandleTargetLost("whatever");
  clingfy::bridge::test_support::PumpMessages();
  EXPECT_TRUE(events->empty());
  EXPECT_EQ(RecordingEngine::Instance().state(), RecordingState::kIdle);
}

}  // namespace
}  // namespace clingfy::capture
