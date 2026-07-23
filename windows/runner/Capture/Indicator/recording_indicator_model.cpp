#include "Capture/Indicator/recording_indicator_model.h"

#include <algorithm>
#include <cmath>
#include <cstdio>

namespace clingfy::capture {

IndicatorVisualState IndicatorStateFor(RecordingState state) {
  switch (state) {
    case RecordingState::kRecording:
    case RecordingState::kResuming:
      return IndicatorVisualState::kRecording;
    case RecordingState::kPausing:
    case RecordingState::kPaused:
      return IndicatorVisualState::kPaused;
    case RecordingState::kStopping:
      return IndicatorVisualState::kStopping;
    case RecordingState::kIdle:
    case RecordingState::kStarting:
    case RecordingState::kStopped:
    case RecordingState::kFailed:
      return IndicatorVisualState::kHidden;
  }
  return IndicatorVisualState::kHidden;
}

std::string FormatIndicatorElapsed(std::uint64_t seconds) {
  const std::uint64_t hours = seconds / 3600;
  const std::uint64_t minutes = (seconds % 3600) / 60;
  const std::uint64_t secs = seconds % 60;
  char buf[32];
  std::snprintf(buf, sizeof(buf), "%02llu:%02llu:%02llu",
                static_cast<unsigned long long>(hours),
                static_cast<unsigned long long>(minutes),
                static_cast<unsigned long long>(secs));
  return std::string(buf);
}

IndicatorRect ComputeIndicatorRect(int work_left, int work_top, int work_right,
                                   int work_bottom, double scale,
                                   int base_width, int base_height) {
  if (scale <= 0.0) {
    scale = 1.0;
  }
  const int width = std::max(1, static_cast<int>(std::lround(base_width * scale)));
  const int height =
      std::max(1, static_cast<int>(std::lround(base_height * scale)));
  // Insets mirror the macOS pill: tucked under the top edge, off the right.
  const int right_inset = static_cast<int>(std::lround(24.0 * scale));
  const int top_inset = static_cast<int>(std::lround(36.0 * scale));

  int x = work_right - width - right_inset;
  int y = work_top + top_inset;

  // Clamp inside the work area. When the area is narrower/shorter than the pill
  // + insets, pin to the top-left corner rather than spilling off-screen.
  const int max_x = work_right - width;
  const int max_y = work_bottom - height;
  x = std::clamp(x, work_left, std::max(work_left, max_x));
  y = std::clamp(y, work_top, std::max(work_top, max_y));

  return IndicatorRect{x, y, width, height};
}

IndicatorButtonLayout ComputeIndicatorButtons(int client_width,
                                              int client_height,
                                              IndicatorVisualState state,
                                              bool can_pause_resume) {
  IndicatorButtonLayout out{};
  // Only the live states carry controls. Hidden isn't shown; stopping shows a
  // spinner (no controls).
  const bool active = state == IndicatorVisualState::kRecording ||
                      state == IndicatorVisualState::kPaused;
  if (!active || client_width <= 0 || client_height <= 0) {
    return out;
  }

  const int pad = std::max(4, client_height / 8);
  const int side = std::max(1, client_height - 2 * pad);
  const int gap = pad;
  const int top = pad;
  const int bottom = top + side;

  // Stop always shows for active states, pinned to the right edge.
  int right = client_width - pad;
  out.stop = IndicatorButtonRect{right - side, top, right, bottom, true};

  // Primary (pause/resume) sits to the LEFT of stop, only when offered.
  if (can_pause_resume) {
    right = out.stop.left - gap;
    out.primary = IndicatorButtonRect{right - side, top, right, bottom, true};
  }

  return out;
}

IndicatorButton HitTestIndicatorButton(const IndicatorButtonLayout& layout,
                                       int x, int y) {
  if (layout.primary.Contains(x, y)) {
    return IndicatorButton::kPrimary;
  }
  if (layout.stop.Contains(x, y)) {
    return IndicatorButton::kStop;
  }
  return IndicatorButton::kNone;
}

}  // namespace clingfy::capture
