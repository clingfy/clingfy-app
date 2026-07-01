#include "Capture/Zoom/zoom_hysteresis.h"

#include "preview/zoom_easing_constants.h"

namespace clingfy::capture {

bool ZoomHysteresis::Update(double time, bool raw_zoom_wanted) {
  // Mirrors ZoomHysteresis.swift exactly.
  if (raw_zoom_wanted != last_raw_) {
    raw_changed_at_ = time;
    last_raw_ = raw_zoom_wanted;
  }

  if (stable_zoom_active_ != raw_zoom_wanted) {
    const double delay = raw_zoom_wanted
                             ? clingfy::preview::kZoomInDelaySeconds
                             : clingfy::preview::kZoomOutDelaySeconds;
    if ((time - raw_changed_at_) >= delay) {
      if (!raw_zoom_wanted) {
        // Turning OFF — only after the minimum-on duration has elapsed.
        if ((time - zoom_turned_on_at_) >=
            clingfy::preview::kZoomMinOnSeconds) {
          stable_zoom_active_ = false;
        }
      } else {
        // Turning ON.
        stable_zoom_active_ = true;
        zoom_turned_on_at_ = time;
      }
    }
  }
  return stable_zoom_active_;
}

void ZoomHysteresis::Reset() {
  stable_zoom_active_ = false;
  last_raw_ = false;
  raw_changed_at_ = 0.0;
  zoom_turned_on_at_ = 0.0;
}

}  // namespace clingfy::capture
