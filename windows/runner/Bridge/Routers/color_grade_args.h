// Editing-features port (color) — the ONE wire parser for the Dart
// `ColorGrade.toMap()` payload.
//
// Both routers consume this: export_router (the `colorGrade` key inside the
// `exportVideo` arguments map, PR-2a) and preview_router (the
// `previewSetColorGrade` method's `colorGrade` argument, PR-2b). It exists as
// a shared helper because the camera-composition payload was parsed twice —
// once per router — and the drift hid a missing-chroma bug (9.7 review, see
// TODOS.md "Camera-composition arg-parsing dedupe"). One wire shape, one
// parser.
//
// Semantics mirror the macOS `ColorGrade.fromFlutter` exactly:
//   * missing / null / non-map payload → identity grade
//   * numeric coercion: double or int → double, anything else → 0
//   * `autoEnabled` → bool, default false
//   * values are NOT clamped (macOS doesn't clamp; Dart bounds the sliders)
//
// The pure color math deliberately knows nothing about Flutter
// (Capture/Export/color_grade.h, matching the clip_playback_planner
// precedent) — this file is the only place the wire shape and the math meet.
//
// Keep this in sync with `ColorGrade.toMap()` in
// lib/core/timeline/model/color_grade.dart and the Swift `fromFlutter`.

#ifndef RUNNER_BRIDGE_ROUTERS_COLOR_GRADE_ARGS_H_
#define RUNNER_BRIDGE_ROUTERS_COLOR_GRADE_ARGS_H_

#include <flutter/encodable_value.h>

#include "Capture/Export/color_grade.h"

namespace clingfy::bridge {

// Parses the VALUE of a `colorGrade` entry (a Dart `ColorGrade.toMap()`
// map). nullptr or a non-map value yields the identity grade.
capture::export_::color::ColorGrade ParseColorGrade(
    const flutter::EncodableValue* value);

// Convenience: looks up `args["colorGrade"]` and parses it. Missing key →
// identity grade.
capture::export_::color::ColorGrade ReadColorGradeArg(
    const flutter::EncodableMap& args);

}  // namespace clingfy::bridge

#endif  // RUNNER_BRIDGE_ROUTERS_COLOR_GRADE_ARGS_H_
