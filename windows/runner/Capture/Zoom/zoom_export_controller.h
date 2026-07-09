#ifndef RUNNER_CAPTURE_ZOOM_ZOOM_EXPORT_CONTROLLER_H_
#define RUNNER_CAPTURE_ZOOM_ZOOM_EXPORT_CONTROLLER_H_

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "Capture/Cursor/cursor_sidecar_reader.h"
#include "Capture/Zoom/zoom_timeline_builder.h"

// Phase 8.3 — orchestrates smart zoom for the export composite. Builds auto-zoom
// segments from the sidecar (clicks + cursor), assigns each a focus mode via the
// ported heuristic, and produces a per-frame smoothed zoom transform (level +
// center) using the exponential follow-smoother. Pure (no D2D / no Win32 beyond
// reading the file) so the segment + focus + convergence logic is unit-testable;
// the pipeline turns each frame's {zoom,center} into a Direct2D matrix.
namespace clingfy::capture {

enum class ZoomFocusMode { kFollowCursor, kFixedTarget };

struct ZoomFocus {
  ZoomFocusMode mode = ZoomFocusMode::kFixedTarget;
  double fixed_x = 0.5;  // normalized [0,1], used only for kFixedTarget.
  double fixed_y = 0.5;
};

// Port of `chooseZoomFocusModeForRange` (Dart), adapted for export (no playhead):
// no visible in-range samples OR movement <= kZoomCursorMotionThresholdPx →
// fixedTarget at the FIRST in-range sample (≈ the triggering click point), else
// center; otherwise → followCursor. Pure + testable.
ZoomFocus ResolveZoomFocus(const std::vector<CursorSidecarSample>& samples,
                           std::int64_t start_ms, std::int64_t end_ms,
                           std::int32_t width, std::int32_t height);

class ZoomExportController {
 public:
  // Build from the sidecar file. Returns nullptr (→ no zoom, export proceeds)
  // when: the file is missing/malformed, zoom_factor <= 1, or no segments are
  // generated. `duration_ms` is the recording length (0 → derived).
  static std::unique_ptr<ZoomExportController> Create(
      const std::wstring& sidecar_path, std::int64_t duration_ms,
      double zoom_factor);
  // Same, from already-parsed data (test seam / shared parse).
  static std::unique_ptr<ZoomExportController> CreateFromData(
      CursorSidecarData data, std::int64_t duration_ms, double zoom_factor);

  // Per-frame transform for the frame presented at `frame_ms`, advancing the
  // smoother by `dt_seconds`. `center_*` are normalized [0,1] and already clamped
  // so the zoom window stays inside the content (no background reveal).
  struct Frame {
    bool active = false;  // true when zoom > ~1.0 (apply the transform).
    double zoom = 1.0;
    double center_x = 0.5;
    double center_y = 0.5;
  };
  Frame Advance(std::int64_t frame_ms, double dt_seconds);

  // Snap the exponential smoother back to its neutral rest state (no zoom,
  // centered). Editing port (clips, 3b-2, §5.4): call at a reorder range
  // boundary where the source clock jumps BACKWARD — otherwise the next
  // Advance eases across the discontinuity from the previous (later) frame's
  // zoom, sweeping the frame instead of resolving the new range fresh.
  void ResetSmoothing();

  std::size_t segment_count() const { return segments_.size(); }

 private:
  struct ResolvedSegment {
    std::int64_t start_ms = 0;
    std::int64_t end_ms = 0;
    ZoomFocus focus;
  };

  CursorSidecarData data_;
  double zoom_factor_ = 1.0;
  std::vector<ResolvedSegment> segments_;

  double cur_zoom_ = 1.0;
  double cur_cx_ = 0.5;
  double cur_cy_ = 0.5;
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_ZOOM_ZOOM_EXPORT_CONTROLLER_H_
