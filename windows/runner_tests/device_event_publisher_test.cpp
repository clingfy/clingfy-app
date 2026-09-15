#include "Bridge/device_event_publisher.h"

#include <gtest/gtest.h>

#include <chrono>
#include <thread>

// The debouncer is the part of device hot-plug that can go wrong quietly. A
// single dock connect or monitor wake fires a BURST of OS notifications, and
// forwarding each one makes Dart re-enumerate audio endpoints several times in
// a few milliseconds — which looks fine on a dev box and behaves badly on a
// machine with a dozen endpoints.
//
// These use a short interval through the test seam so the real 250 ms (chosen
// to match macOS's TrailingDebouncer) does not have to be slept per case.
namespace clingfy::bridge {
namespace {

constexpr auto kInterval = std::chrono::milliseconds(30);

// Comfortably past the deadline, with room for scheduler jitter on a loaded
// CI agent — the assertions are about COALESCING, not about latency.
void WaitForFlush() { std::this_thread::sleep_for(kInterval * 6); }

class DeviceEventPublisherTest : public ::testing::Test {
 protected:
  void SetUp() override {
    DeviceEventPublisher::Instance().SetDebounceForTesting(kInterval);
    DeviceEventPublisher::Instance().ClearObservers();
    WaitForFlush();  // drain anything a previous case left pending
    baseline_audio_ =
        DeviceEventPublisher::Instance().EmitCountForTesting(
            "audioSourcesChanged");
    baseline_video_ =
        DeviceEventPublisher::Instance().EmitCountForTesting(
            "videoSourcesChanged");
  }

  int AudioEmits() const {
    return DeviceEventPublisher::Instance().EmitCountForTesting(
               "audioSourcesChanged") -
           baseline_audio_;
  }
  int VideoEmits() const {
    return DeviceEventPublisher::Instance().EmitCountForTesting(
               "videoSourcesChanged") -
           baseline_video_;
  }

  int baseline_audio_ = 0;
  int baseline_video_ = 0;
};

TEST_F(DeviceEventPublisherTest, ABurstCollapsesToASingleEmit) {
  // THE property. Ten notifications arriving inside the debounce window — one
  // dock connect — must reach Dart once, not ten times.
  for (int i = 0; i < 10; ++i) {
    DeviceEventPublisher::Instance().EmitAudioSourcesChanged();
  }
  WaitForFlush();
  EXPECT_EQ(AudioEmits(), 1);
}

TEST_F(DeviceEventPublisherTest, ItIsTrailingNotLeading) {
  // A leading debounce would fire immediately and swallow the rest, reporting
  // the state at the START of the burst. Device lists have to reflect the END
  // of it — after the dock has finished enumerating, not before.
  DeviceEventPublisher::Instance().EmitAudioSourcesChanged();
  EXPECT_EQ(AudioEmits(), 0) << "fired before the quiet period elapsed";
  WaitForFlush();
  EXPECT_EQ(AudioEmits(), 1);
}

TEST_F(DeviceEventPublisherTest, EachTypeIsDebouncedIndependently) {
  // An audio burst must not swallow a display or camera change that happens
  // during it — they are different lists with different consumers.
  DeviceEventPublisher::Instance().EmitAudioSourcesChanged();
  DeviceEventPublisher::Instance().EmitVideoSourcesChanged();
  WaitForFlush();
  EXPECT_EQ(AudioEmits(), 1);
  EXPECT_EQ(VideoEmits(), 1);
}

TEST_F(DeviceEventPublisherTest, SeparateBurstsEmitSeparately) {
  // Coalescing must not become swallowing: two genuine hot-plugs a second
  // apart are two events, or the second device never appears.
  DeviceEventPublisher::Instance().EmitAudioSourcesChanged();
  WaitForFlush();
  DeviceEventPublisher::Instance().EmitAudioSourcesChanged();
  WaitForFlush();
  EXPECT_EQ(AudioEmits(), 2);
}

TEST_F(DeviceEventPublisherTest, ObserversSeeTheDebouncedType) {
  // The native pre-recording bar refreshes an open popover through this
  // fan-out, because the Flutter sink is single-assignment and already spoken
  // for. It must receive the same coalesced stream Dart does.
  std::vector<std::string> seen;
  std::mutex seen_mutex;
  DeviceEventPublisher::Instance().AddObserver(
      [&](const std::string& type) {
        std::lock_guard<std::mutex> lock(seen_mutex);
        seen.push_back(type);
      });
  for (int i = 0; i < 5; ++i) {
    DeviceEventPublisher::Instance().EmitVideoSourcesChanged();
  }
  WaitForFlush();
  DeviceEventPublisher::Instance().ClearObservers();

  std::lock_guard<std::mutex> lock(seen_mutex);
  ASSERT_EQ(seen.size(), 1u);
  EXPECT_EQ(seen[0], "videoSourcesChanged");
}

TEST_F(DeviceEventPublisherTest, EmittingWithNoSinkIsHarmless) {
  // The OS listeners can fire before Dart subscribes and after it cancels;
  // neither may crash, and both must leave the debouncer usable.
  DeviceEventPublisher::Instance().ClearSink();
  EXPECT_FALSE(DeviceEventPublisher::Instance().has_sink());
  DeviceEventPublisher::Instance().EmitDisplaysChanged();
  WaitForFlush();
  EXPECT_EQ(DeviceEventPublisher::Instance().EmitCountForTesting(
                "displaysChanged") > 0,
            true);
}

}  // namespace
}  // namespace clingfy::bridge
