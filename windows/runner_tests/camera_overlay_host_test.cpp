// Unit tests for CameraOverlayHost — the mid-session GDI fallback owner
// (renderer redesign P4c-c3). Uses fake presenters so the swap logic is
// exercised with no window/GPU; the real DComp->GDI swap on parked hardware is
// covered by the integration test in camera_dcomp_overlay_poc_test.cpp.

#include "Capture/Camera/camera_overlay_host.h"

#include <atomic>
#include <functional>
#include <memory>
#include <utility>

#include <gtest/gtest.h>

#include "Capture/Camera/camera_overlay_presenter.h"

namespace clingfy::capture {
namespace {

// Controllable ICameraOverlayPresenter double. All observation flags are read
// on the test thread after the host call returns, so plain members are fine
// except needs_fallback(), which the host samples and we flip between calls.
class FakePresenter : public ICameraOverlayPresenter {
 public:
  bool Start(const FloatingPlacement&) override {
    started_ = true;
    return start_ok_;
  }
  void Show() override { shown_ = true; }
  void Hide() override { shown_ = false; }
  void PublishBgra(const std::uint8_t*, int, int) override { ++frames_; }
  void Stop() override { stopped_ = true; }
  bool running() const override { return started_ && !stopped_; }
  bool wda_excluded() const override { return wda_; }
  bool needs_fallback() const override { return fallback_.load(); }
  void SetParkObserver(std::function<void()> observer) override {
    // Matches the real presenter: storing only. Firing on install would
    // re-enter the host while it holds mutex_ — which is precisely the
    // "resource deadlock would occur" this design avoids, and the
    // already-parked case is the owner's post-install poll instead.
    park_observer_ = std::move(observer);
  }
  // Simulate the presenter's tick reaching the park with no frame in sight.
  void FirePark() {
    fallback_.store(true);
    if (park_observer_) park_observer_();
  }
  bool has_park_observer() const { return static_cast<bool>(park_observer_); }

  // Controls.
  bool start_ok_ = true;
  bool wda_ = true;
  std::atomic<bool> fallback_{false};
  std::function<void()> park_observer_;
  // Observations.
  bool started_ = false;
  bool stopped_ = false;
  bool shown_ = false;
  int frames_ = 0;
};

FloatingPlacement Placement() {
  FloatingPlacement p;
  p.x = 10;
  p.y = 10;
  p.width = 220;
  p.height = 220;
  return p;
}

// Build a host wired to a given inner presenter and a GDI factory returning the
// given fallback (or nullptr). AdoptInnerForTest bypasses the real ladder.
std::shared_ptr<CameraOverlayHost> MakeHost(
    std::shared_ptr<FakePresenter> inner,
    std::shared_ptr<FakePresenter> gdi_fallback) {
  auto host = std::make_shared<CameraOverlayHost>(
      [gdi_fallback](const FloatingPlacement&)
          -> std::shared_ptr<ICameraOverlayPresenter> {
        if (gdi_fallback != nullptr && gdi_fallback->Start(FloatingPlacement{})) {
          return gdi_fallback;
        }
        return nullptr;
      },
      // Inline poster: the fake presenter has no thread of its own, so there is
      // no thread to self-join and the swap can be asserted synchronously.
      // Production MUST NOT do this — see CameraOverlayHost::TaskPoster.
      [](std::function<void()> task) {
        task();
        return true;
      });
  host->AdoptInnerForTest(inner, Placement());
  return host;
}

const std::uint8_t kPixel[4] = {255, 0, 255, 255};

TEST(CameraOverlayHost, ForwardsToInnerWhenNoFallbackNeeded) {
  auto inner = std::make_shared<FakePresenter>();
  auto host = MakeHost(inner, std::make_shared<FakePresenter>());
  host->Show();
  host->PublishBgra(kPixel, 1, 1);
  host->PublishBgra(kPixel, 1, 1);
  EXPECT_TRUE(inner->shown_);
  EXPECT_EQ(inner->frames_, 2);
  EXPECT_TRUE(host->wda_excluded());
  EXPECT_FALSE(host->did_fall_back_for_test());
}

TEST(CameraOverlayHost, SwapsToGdiWhenInnerParksAndReShowsWhenExcluded) {
  auto inner = std::make_shared<FakePresenter>();
  auto gdi = std::make_shared<FakePresenter>();
  auto host = MakeHost(inner, gdi);
  host->Show();  // bubble is showing before the loss
  host->PublishBgra(kPixel, 1, 1);
  ASSERT_EQ(inner->frames_, 1);

  inner->fallback_.store(true);   // device loss exhausts the rebuild budget
  host->PublishBgra(kPixel, 1, 1);  // this publish triggers the swap

  EXPECT_TRUE(inner->stopped_) << "the parked inner was not stopped";
  EXPECT_TRUE(gdi->started_) << "the GDI fallback was not started";
  EXPECT_TRUE(gdi->shown_) << "the GDI fallback was not re-shown after the swap";
  EXPECT_EQ(gdi->frames_, 1) << "the triggering frame did not reach the GDI "
                                "presenter";
  EXPECT_TRUE(host->did_fall_back_for_test());

  // Subsequent frames go to the GDI presenter; the inner sees no more.
  host->PublishBgra(kPixel, 1, 1);
  EXPECT_EQ(gdi->frames_, 2);
  EXPECT_EQ(inner->frames_, 1);
}

TEST(CameraOverlayHost, SwapWhileHiddenDoesNotShowTheGdiBubble) {
  auto inner = std::make_shared<FakePresenter>();
  auto gdi = std::make_shared<FakePresenter>();
  auto host = MakeHost(inner, gdi);
  // Never shown (or explicitly hidden).
  host->Hide();
  inner->fallback_.store(true);
  host->PublishBgra(kPixel, 1, 1);
  EXPECT_TRUE(gdi->started_);
  EXPECT_FALSE(gdi->shown_) << "a hidden bubble must not be shown after a swap";
  EXPECT_TRUE(host->did_fall_back_for_test());
}

TEST(CameraOverlayHost, SwapNeverShowsAnUnexcludedGdiBubble) {
  auto inner = std::make_shared<FakePresenter>();
  auto gdi = std::make_shared<FakePresenter>();
  gdi->wda_ = false;  // the GDI window's capture-exclusion failed
  auto host = MakeHost(inner, gdi);
  host->Show();
  inner->fallback_.store(true);
  host->PublishBgra(kPixel, 1, 1);
  EXPECT_TRUE(gdi->started_);
  EXPECT_FALSE(gdi->shown_)
      << "must never show a bubble whose capture-exclusion failed";
  EXPECT_FALSE(host->wda_excluded());
}

TEST(CameraOverlayHost, FailedGdiFallbackLeavesNoBubbleAndNoCrash) {
  auto inner = std::make_shared<FakePresenter>();
  // gdi factory returns nullptr (safe mode could not start either).
  auto host = MakeHost(inner, /*gdi_fallback=*/nullptr);
  host->Show();
  inner->fallback_.store(true);
  host->PublishBgra(kPixel, 1, 1);  // swap attempt fails -> no inner
  EXPECT_TRUE(inner->stopped_);
  EXPECT_FALSE(host->running());
  EXPECT_FALSE(host->wda_excluded());
  // Further frames are safe no-ops.
  host->PublishBgra(kPixel, 1, 1);
}

TEST(CameraOverlayHost, SwapIsOneShot) {
  auto inner = std::make_shared<FakePresenter>();
  auto gdi = std::make_shared<FakePresenter>();
  gdi->fallback_.store(true);  // even if the GDI (wrongly) asked to fall back
  auto host = MakeHost(inner, gdi);
  host->Show();
  inner->fallback_.store(true);
  host->PublishBgra(kPixel, 1, 1);  // swap #1
  ASSERT_TRUE(host->did_fall_back_for_test());
  const bool gdi_stopped_after_first = gdi->stopped_;
  host->PublishBgra(kPixel, 1, 1);  // must NOT swap again
  EXPECT_FALSE(gdi->stopped_)
      << "the fallback presenter was swapped out — fallback must be one-shot";
  EXPECT_EQ(gdi_stopped_after_first, false);
  EXPECT_EQ(gdi->frames_, 2);
}

TEST(CameraOverlayHost, ShowDoesNotForwardToUnexcludedInner) {
  // The host gates Show on capture-exclusion atomically under its own mutex, so
  // the engine's separate wda_excluded()+Show() pair can't be raced by a swap
  // into showing an unexcluded bubble. A direct Show() on an unexcluded inner
  // must not reach it.
  auto inner = std::make_shared<FakePresenter>();
  inner->wda_ = false;
  auto host = MakeHost(inner, std::make_shared<FakePresenter>());
  host->Show();
  EXPECT_FALSE(inner->shown_)
      << "Show() forwarded to an inner whose capture-exclusion failed";
  EXPECT_FALSE(host->wda_excluded());
}

TEST(CameraOverlayHost, ShowRefusesAfterSwapToUnexcludedGdi) {
  // The TOCTOU the fix closes: inner is excluded and the user's show intent is
  // set, the inner parks and swaps to an UNEXCLUDED GDI, then a fresh Show()
  // (as the engine re-issues) must still refuse to show the unexcluded bubble.
  auto inner = std::make_shared<FakePresenter>();
  auto gdi = std::make_shared<FakePresenter>();
  gdi->wda_ = false;
  auto host = MakeHost(inner, gdi);
  host->Show();                    // inner excluded -> shown
  inner->fallback_.store(true);
  host->PublishBgra(kPixel, 1, 1);  // swap to the unexcluded GDI
  ASSERT_TRUE(host->did_fall_back_for_test());
  gdi->shown_ = false;              // clear any prior state
  host->Show();                     // engine re-issues Show after the swap
  EXPECT_FALSE(gdi->shown_)
      << "Show() showed the unexcluded GDI bubble after the swap (leak)";
}

TEST(CameraOverlayHost, SwapForwardsHostPlacementToGdiFactory) {
  auto inner = std::make_shared<FakePresenter>();
  auto gdi = std::make_shared<FakePresenter>();
  FloatingPlacement received{};
  bool factory_called = false;
  auto host = std::make_shared<CameraOverlayHost>(
      [&](const FloatingPlacement& p)
          -> std::shared_ptr<ICameraOverlayPresenter> {
        received = p;
        factory_called = true;
        return gdi;
      });
  FloatingPlacement place;
  place.x = 7;
  place.y = 8;
  place.width = 333;
  place.height = 222;
  host->AdoptInnerForTest(inner, place);
  inner->fallback_.store(true);
  host->PublishBgra(kPixel, 1, 1);
  EXPECT_TRUE(factory_called) << "the GDI fallback factory was not invoked";
  EXPECT_EQ(received.x, 7);
  EXPECT_EQ(received.y, 8);
  EXPECT_EQ(received.width, 333);
  EXPECT_EQ(received.height, 222)
      << "the swap did not forward the host's placement to the GDI presenter";
}

TEST(CameraOverlayHost, StopForwardsAndClears) {
  auto inner = std::make_shared<FakePresenter>();
  auto host = MakeHost(inner, std::make_shared<FakePresenter>());
  host->Show();
  host->Stop();
  EXPECT_TRUE(inner->stopped_);
  EXPECT_FALSE(host->running());
}

// --- park notification: the swap without a frame ----------------------------

TEST(CameraOverlayHost, SwapsToGdiWhenInnerParksWithNoFramesPublished) {
  // THE regression test. Previously the swap could only happen inside
  // PublishBgra, so a park during a pause / after end-of-stream / behind a
  // wedged ReadSample left the bubble frozen on screen forever.
  auto inner = std::make_shared<FakePresenter>();
  auto gdi = std::make_shared<FakePresenter>();
  auto host = MakeHost(inner, gdi);
  host->Show();
  ASSERT_TRUE(inner->has_park_observer())
      << "the host never registered a park observer on its inner presenter";

  inner->FirePark();  // no PublishBgra anywhere in this test

  EXPECT_TRUE(inner->stopped_) << "the parked inner was not stopped";
  EXPECT_TRUE(gdi->started_) << "the GDI fallback was not started";
  EXPECT_TRUE(gdi->shown_) << "the GDI fallback was not shown";
  EXPECT_TRUE(host->did_fall_back_for_test());
  EXPECT_EQ(inner->frames_, 0);
}

TEST(CameraOverlayHost, ParkNotifyThenPublishSwapsOnlyOnce) {
  auto inner = std::make_shared<FakePresenter>();
  auto gdi = std::make_shared<FakePresenter>();
  auto host = MakeHost(inner, gdi);
  host->Show();
  inner->FirePark();
  host->PublishBgra(kPixel, 1, 1);
  host->PublishBgra(kPixel, 1, 1);
  // The one-shot latch has to hold ACROSS the two entry points, not just
  // within each.
  EXPECT_FALSE(gdi->stopped_) << "the GDI presenter was swapped out again";
  EXPECT_EQ(gdi->frames_, 2);
}

TEST(CameraOverlayHost, PublishThenParkNotifyIsAlsoOneShot) {
  auto inner = std::make_shared<FakePresenter>();
  auto gdi = std::make_shared<FakePresenter>();
  auto host = MakeHost(inner, gdi);
  host->Show();
  inner->fallback_.store(true);
  host->PublishBgra(kPixel, 1, 1);  // swap via the frame path
  ASSERT_TRUE(gdi->started_);
  if (inner->park_observer_) inner->park_observer_();  // stale notification
  EXPECT_FALSE(gdi->stopped_);
}

TEST(CameraOverlayHost, ParkNotifyAfterStopIsSafe) {
  auto inner = std::make_shared<FakePresenter>();
  auto gdi = std::make_shared<FakePresenter>();
  auto host = MakeHost(inner, gdi);
  host->Show();
  auto observer = inner->park_observer_;  // captured before teardown
  host->Stop();
  inner->fallback_.store(true);
  if (observer) observer();  // must not start a GDI bubble or crash
  EXPECT_FALSE(gdi->started_)
      << "a park notification after Stop() resurrected the fallback";
}

TEST(CameraOverlayHost, ParkNotifyNeverShowsUnexcludedGdi) {
  // The never-show-an-unexcluded-bubble invariant must hold on the new path
  // too, or a device loss would burn the camera into the recording.
  auto inner = std::make_shared<FakePresenter>();
  auto gdi = std::make_shared<FakePresenter>();
  gdi->wda_ = false;
  auto host = MakeHost(inner, gdi);
  host->Show();
  inner->FirePark();
  EXPECT_TRUE(gdi->started_);
  EXPECT_FALSE(gdi->shown_);
}

TEST(CameraOverlayHost, ParkNotifyWhileHiddenDoesNotShow) {
  auto inner = std::make_shared<FakePresenter>();
  auto gdi = std::make_shared<FakePresenter>();
  auto host = MakeHost(inner, gdi);
  host->Hide();
  inner->FirePark();
  EXPECT_TRUE(gdi->started_);
  EXPECT_FALSE(gdi->shown_);
}

TEST(CameraOverlayHost, AlreadyParkedInnerIsSwappedWithoutWaitingForAFrame) {
  // The push alone is edge-triggered and would miss a park that landed before
  // the host could install its observer — the presenter is started and ticking
  // first, so that window is real. The post-install poll closes it. Together
  // they are level-triggered; neither is on its own.
  //
  // (The poll happens while the host holds mutex_, which is why installing must
  // not fire the observer synchronously: that path re-locked the same
  // non-recursive mutex and threw "resource deadlock would occur".)
  auto inner = std::make_shared<FakePresenter>();
  auto gdi = std::make_shared<FakePresenter>();
  inner->fallback_.store(true);  // parked BEFORE the host ever sees it
  auto host = MakeHost(inner, gdi);  // no PublishBgra, no FirePark
  EXPECT_TRUE(inner->stopped_);
  EXPECT_TRUE(gdi->started_);
  EXPECT_TRUE(host->did_fall_back_for_test());
}

TEST(CameraOverlayHost, InstallingTheObserverDoesNotFireItSynchronously) {
  // Pins the contract that keeps the above deadlock-free: an owner installing
  // under its own lock must not be re-entered.
  auto inner = std::make_shared<FakePresenter>();
  auto gdi = std::make_shared<FakePresenter>();
  auto host = MakeHost(inner, gdi);
  ASSERT_TRUE(inner->has_park_observer());
  EXPECT_FALSE(gdi->started_)
      << "installing the park observer performed a swap on its own";
}

}  // namespace
}  // namespace clingfy::capture
