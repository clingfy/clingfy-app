#ifndef RUNNER_CAPTURE_ZOOM_ZOOM_HYSTERESIS_H_
#define RUNNER_CAPTURE_ZOOM_ZOOM_HYSTERESIS_H_

// Phase 8.3 — 1:1 port of macOS `ZoomHysteresis.swift`.
//
// Debounces a per-step "zoom wanted" boolean into a stable active/inactive
// state: flips ON only after `wanted` has been continuously true for
// kZoomInDelaySeconds, flips OFF only after continuously false for
// kZoomOutDelaySeconds, and once ON must stay ON at least kZoomMinOnSeconds.
// Pure (no platform deps) → unit-tested against the same thresholds the
// constants header pins. Times are seconds.
namespace clingfy::capture {

class ZoomHysteresis {
 public:
  // Returns the stable active state after folding in `raw_zoom_wanted` at `time`.
  bool Update(double time, bool raw_zoom_wanted);
  void Reset();

  bool stable_zoom_active() const { return stable_zoom_active_; }

 private:
  bool stable_zoom_active_ = false;
  bool last_raw_ = false;
  double raw_changed_at_ = 0.0;
  double zoom_turned_on_at_ = 0.0;
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_ZOOM_ZOOM_HYSTERESIS_H_
