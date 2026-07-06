#ifndef RUNNER_CAPTURE_CAMERA_EDITOR_SEED_H_
#define RUNNER_CAPTURE_CAMERA_EDITOR_SEED_H_

#include <cstdint>
#include <optional>
#include <string>

// The recording-time camera composition the editor should open with — the
// Windows port of macOS's `RecordingMetadata.EditorSeed`. Persisted into
// `capture/screen.meta.json` under the `editorSeed` key at record-stop, parsed
// back by the recording project reader, and surfaced to Dart by
// `getRecordingSceneInfo` as the `camera` block so post-processing reopens the
// recording camera-on with the settings the user chose while recording (instead
// of falling back to `CameraCompositionState.hidden()` — camera off + defaults).
//
// Field names below are internal C++ names. TWO wire contracts are derived from
// them and must be kept in lockstep:
//   * On-disk JSON keys are `camera*`-prefixed (macOS `EditorSeed` CodingKeys) —
//     emitted by recording_project_writer.cpp (BuildScreenMetaJson) and parsed
//     by recording_project_reader.cpp (ParseScreenMetaJson). A Windows-written
//     block is byte-compatible with the macOS decoder (all 12 always-required
//     fields are emitted).
//   * The scene-info reply keys are UN-prefixed and rename four fields
//     (cameraShadow→shadowPreset, cameraNormalizedCenter→normalizedCanvasCenter,
//     cameraBorderColorArgb→borderColorArgb,
//     cameraChromaKeyColorArgb→chromaKeyColorArgb) — emitted by
//     preview_router.cpp and consumed by Dart CameraCompositionState.fromMap.
//
// Defaults mirror macOS `CameraCompositionParams` defaults / the `.hidden`
// baseline, so a camera-less recording (visible=false) still round-trips a sane
// block.
namespace clingfy::capture {

struct CameraEditorSeed {
  bool visible = false;                              // cameraVisible
  std::string layout_preset = "hidden";              // cameraLayoutPreset
  std::optional<double> normalized_center_x;         // cameraNormalizedCenter.x (omit when nil)
  std::optional<double> normalized_center_y;         // cameraNormalizedCenter.y (omit when nil)
  double size_factor = 0.18;                         // cameraSizeFactor
  std::string shape = "circle";                      // cameraShape
  double corner_radius = 0.0;                        // cameraCornerRadius
  double border_width = 0.0;                         // cameraBorderWidth
  std::optional<std::uint32_t> border_color_argb;    // cameraBorderColorArgb (omit when nil)
  int shadow_preset = 0;                             // cameraShadow
  double opacity = 1.0;                              // cameraOpacity
  bool mirror = true;                                // cameraMirror
  std::string content_mode = "fill";                 // cameraContentMode
  std::string zoom_behavior = "scaleWithScreenZoom"; // cameraZoomBehavior
  double zoom_scale_multiplier = 0.35;               // cameraZoomScaleMultiplier
  std::string intro_preset = "fade";                 // cameraIntroPreset
  std::string outro_preset = "shrink";               // cameraOutroPreset
  std::string zoom_emphasis_preset = "none";         // cameraZoomEmphasisPreset
  int intro_duration_ms = 220;                       // cameraIntroDurationMs
  int outro_duration_ms = 180;                       // cameraOutroDurationMs
  double zoom_emphasis_strength = 0.10;              // cameraZoomEmphasisStrength
  bool chroma_key_enabled = false;                   // cameraChromaKeyEnabled
  double chroma_key_strength = 0.4;                  // cameraChromaKeyStrength
  std::optional<std::uint32_t> chroma_key_color_argb; // cameraChromaKeyColorArgb (omit when nil)
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CAMERA_EDITOR_SEED_H_
