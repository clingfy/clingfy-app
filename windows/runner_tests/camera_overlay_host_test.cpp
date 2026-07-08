// Unit tests for CameraOverlayHost — the mid-session GDI fallback owner
// (renderer redesign P4c-c3). Uses fake presenters so the swap logic is
// exercised with no window/GPU; the real DComp->GDI swap on parked hardware is
// covered by the integration test in camera_dcomp_overlay_poc_test.cpp.

#include "Capture/Camera/camera_overlay_host.h"

#include <atomic>
#include <memory>

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

  // Controls.
  bool start_ok_ = true;
  bool wda_ = true;
  std::atomic<bool> fallback_{false};
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

TEST(CameraOverlayHost, StopForwardsAndClears) {
  auto inner = std::make_shared<FakePresenter>();
  auto host = MakeHost(inner, std::make_shared<FakePresenter>());
  host->Show();
  host->Stop();
  EXPECT_TRUE(inner->stopped_);
  EXPECT_FALSE(host->running());
}

}  // namespace
}  // namespace clingfy::capture
