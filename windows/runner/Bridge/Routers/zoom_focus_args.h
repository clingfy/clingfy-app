// Fixed-target zoom — the ONE wire parser for a zoom segment's focus.
//
// Dart sends the same two keys on both paths that carry a segment:
// `saveManualZoomSegments` (ZoomSegment.toMap, into the export router) and
// `previewSetZoomSegments` (into the preview router):
//
//   "focusMode":   "followCursor" | "fixedTarget"   (missing on old payloads)
//   "fixedTarget": {"dx": 0.3, "dy": 0.6}           (only with fixedTarget)
//
// Both routers parse through here so the preview and the saved file can never
// disagree on what a pinned segment is, the drift color_grade_args.h exists to
// prevent for the grade.
//
// Keep this in sync with ZoomSegment.toMap / previewSetZoomSegments in
// lib/core/models/app_models.dart and lib/core/bridges/native_bridge.dart.

#ifndef RUNNER_BRIDGE_ROUTERS_ZOOM_FOCUS_ARGS_H_
#define RUNNER_BRIDGE_ROUTERS_ZOOM_FOCUS_ARGS_H_

#include <flutter/encodable_value.h>

#include <string>

namespace clingfy::bridge {

struct ZoomFocusArgs {
  std::string focus_mode;  // verbatim; empty when the key is missing
  bool has_point = false;  // true only when both dx and dy are numbers
  double x = 0.5;          // clamped to [0,1]
  double y = 0.5;

  // Pinned: the fixedTarget mode WITH a point to pin on.
  bool fixed_target() const {
    return focus_mode == "fixedTarget" && has_point;
  }
};

// Reads `focusMode` / `fixedTarget` from one segment map.
ZoomFocusArgs ReadZoomFocusArgs(const flutter::EncodableMap& segment);

}  // namespace clingfy::bridge

#endif  // RUNNER_BRIDGE_ROUTERS_ZOOM_FOCUS_ARGS_H_
