#include "Capture/windows_selection_state.h"

namespace clingfy::capture {

WindowsSelectionState& WindowsSelectionState::Instance() {
  static WindowsSelectionState instance;
  return instance;
}

void WindowsSelectionState::SetDisplayId(std::optional<std::int64_t> id) {
  std::lock_guard<std::mutex> lock(mutex_);
  display_id_ = id;
}

std::optional<std::int64_t> WindowsSelectionState::DisplayId() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return display_id_;
}

void WindowsSelectionState::SetTargetMode(DisplayTargetMode mode) {
  std::lock_guard<std::mutex> lock(mutex_);
  target_mode_ = mode;
}

DisplayTargetMode WindowsSelectionState::TargetMode() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return target_mode_;
}

void WindowsSelectionState::SetAppWindowId(std::optional<std::int64_t> id) {
  std::lock_guard<std::mutex> lock(mutex_);
  app_window_id_ = id;
}

std::optional<std::int64_t> WindowsSelectionState::AppWindowId() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return app_window_id_;
}

void WindowsSelectionState::SetAreaRegion(std::optional<AreaRegion> region) {
  std::lock_guard<std::mutex> lock(mutex_);
  area_region_ = region;
}

std::optional<AreaRegion> WindowsSelectionState::CurrentAreaRegion() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return area_region_;
}

void WindowsSelectionState::SetMicrophoneId(std::optional<std::string> id) {
  std::lock_guard<std::mutex> lock(mutex_);
  microphone_id_ = std::move(id);
}

std::optional<std::string> WindowsSelectionState::MicrophoneId() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return microphone_id_;
}

void WindowsSelectionState::ResetForTesting() {
  std::lock_guard<std::mutex> lock(mutex_);
  display_id_.reset();
  app_window_id_.reset();
  area_region_.reset();
  target_mode_ = DisplayTargetMode::kExplicitId;
  microphone_id_.reset();
}

DisplayTargetMode TargetModeFromInt(std::int32_t raw) {
  switch (raw) {
    case 0:
      return DisplayTargetMode::kExplicitId;
    case 1:
      return DisplayTargetMode::kAppWindow;
    case 2:
      return DisplayTargetMode::kSingleAppWindow;
    case 3:
      return DisplayTargetMode::kAreaRecording;
    case 4:
      return DisplayTargetMode::kMouseAtStart;
    case 5:
      return DisplayTargetMode::kFollowMouse;
    default:
      return DisplayTargetMode::kExplicitId;
  }
}

const char* TargetModeName(DisplayTargetMode mode) {
  switch (mode) {
    case DisplayTargetMode::kExplicitId:
      return "explicitId";
    case DisplayTargetMode::kAppWindow:
      return "appWindow";
    case DisplayTargetMode::kSingleAppWindow:
      return "singleAppWindow";
    case DisplayTargetMode::kAreaRecording:
      return "areaRecording";
    case DisplayTargetMode::kMouseAtStart:
      return "mouseAtStart";
    case DisplayTargetMode::kFollowMouse:
      return "followMouse";
  }
  return "unknown";
}

}  // namespace clingfy::capture
