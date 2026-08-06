// The ONE wire parser for the Dart `CameraCompositionState.toMap()` payload.
//
// Three call sites spread that map into their arguments and all three feed the
// SAME live preview composition:
//   * `processVideo`                (export_router) — preview open + every
//                                    layout/styling change in the editor.
//   * `previewSetCameraPlacement`   (preview_router) — placement drags.
// Until this file existed they were two hand-duplicated parse blocks, and the
// drift was not theoretical: it hid a missing-chroma bug in the 9.7 review, and
// again left intro/outro animations parsed on the export path only, so the
// inline preview never animated. `bridge_contract_coverage_test` checks method
// NAMES only and cannot see a field parsed on one path and not the other, so
// nothing in CI caught either. One wire shape, one parser — this is the
// `color_grade_args` precedent applied to the payload that motivated it
// (TODOS.md "Camera-composition arg-parsing dedupe").
//
// Defaults deliberately DIFFER from the CameraEditorSeed defaults: an absent
// animation key parses to kNone / 0 ms (a static bubble), matching what the
// export request parser does. Seeding fade/220 here instead would make a legacy
// or partial payload animate in the preview but NOT in the export — inverting
// the very bug this parser exists to prevent.
//
// Keep in sync with `CameraCompositionState.toMap()` in
// lib/core/models/app_models.dart.

#ifndef RUNNER_BRIDGE_ROUTERS_CAMERA_COMPOSITION_ARGS_H_
#define RUNNER_BRIDGE_ROUTERS_CAMERA_COMPOSITION_ARGS_H_

#include <flutter/encodable_value.h>

#include "Capture/Export/export_passthrough.h"
#include "preview/preview_camera_renderer.h"

namespace clingfy::bridge {

// Parse a `camera*` arg map into the live preview composition. Missing keys
// take the documented per-field fallbacks; an unknown animation preset name
// soft-fails to "no animation" rather than erroring.
preview::PreviewCameraComposition ReadCameraComposition(
    const flutter::EncodableMap& args);

// Copy a parsed composition into the export request's flat `camera_*` fields.
//
// `exportVideo` was the THIRD parse of this payload — a hand-written copy of
// the same 21 keys with its own default literals. It read the same values as
// the shared parser, but only by coincidence of two people writing the same
// list twice, and that coincidence had already failed twice (chroma in the 9.7
// review, then the four intro/outro keys). Routing the export through
// ReadCameraComposition + this mapper leaves ONE parser for all three call
// sites.
//
// Every field must be carried. `ExportCameraFieldsAreComplete` in the tests
// sets a distinctive non-default on every composition field and fails if any
// export field comes out at its default — so adding a field to
// PreviewCameraComposition without extending this mapper breaks the build's
// tests rather than silently dropping the value on the export path only, which
// is exactly how the intro/outro bug shipped.
void ApplyCameraCompositionToExport(
    const preview::PreviewCameraComposition& composition,
    capture::export_::PassthroughInput& input);

}  // namespace clingfy::bridge

#endif  // RUNNER_BRIDGE_ROUTERS_CAMERA_COMPOSITION_ARGS_H_
