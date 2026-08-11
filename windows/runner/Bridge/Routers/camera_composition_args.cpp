#include "Bridge/Routers/camera_composition_args.h"

#include <cstdint>
#include <optional>
#include <string>

namespace clingfy::bridge {

namespace {

std::string StringOrEmpty(const flutter::EncodableMap& map, const char* key) {
  const auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it == map.end()) return {};
  if (const auto* s = std::get_if<std::string>(&it->second)) return *s;
  return {};
}

// The standard codec delivers an integer-valued double as int32/int64, so
// accept those too — otherwise a slider parked on a whole number would fall
// back instead of reading as 0.0.
double NumberOr(const flutter::EncodableMap& map, const char* key,
                double fallback) {
  const auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it == map.end()) return fallback;
  if (const auto* d = std::get_if<double>(&it->second)) return *d;
  if (const auto* i32 = std::get_if<std::int32_t>(&it->second)) {
    return static_cast<double>(*i32);
  }
  if (const auto* i64 = std::get_if<std::int64_t>(&it->second)) {
    return static_cast<double>(*i64);
  }
  return fallback;
}

bool BoolOr(const flutter::EncodableMap& map, const char* key, bool fallback) {
  const auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it == map.end()) return fallback;
  if (const auto* b = std::get_if<bool>(&it->second)) return *b;
  return fallback;
}

// Nullable `int?`. Absent or null yields nullopt (distinct from an explicit 0).
// An ARGB value with the alpha high bit set exceeds int32 range, so Flutter
// encodes it as int64 — accept both.
std::optional<std::int64_t> OptionalInt(const flutter::EncodableMap& map,
                                        const char* key) {
  const auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it == map.end()) return std::nullopt;
  if (const auto* i32 = std::get_if<std::int32_t>(&it->second)) {
    return static_cast<std::int64_t>(*i32);
  }
  if (const auto* i64 = std::get_if<std::int64_t>(&it->second)) return *i64;
  return std::nullopt;
}

}  // namespace

preview::PreviewCameraComposition ReadCameraComposition(
    const flutter::EncodableMap& args) {
  preview::PreviewCameraComposition c;
  c.visible = BoolOr(args, "cameraVisible", false);
  c.layout_preset = StringOrEmpty(args, "cameraLayoutPreset");
  c.size_factor = NumberOr(args, "cameraSizeFactor", 0.18);
  c.shape = StringOrEmpty(args, "cameraShape");
  c.corner_radius = NumberOr(args, "cameraCornerRadius", 0.0);
  c.content_mode = StringOrEmpty(args, "cameraContentMode");
  c.mirror = BoolOr(args, "cameraMirror", false);
  c.opacity = NumberOr(args, "cameraOpacity", 1.0);
  c.border_width = NumberOr(args, "cameraBorderWidth", 0.0);
  if (const auto argb = OptionalInt(args, "cameraBorderColorArgb")) {
    c.has_border_color = true;
    c.border_argb = static_cast<std::uint32_t>(*argb);
  }
  c.shadow_preset = static_cast<int>(NumberOr(args, "cameraShadowPreset", 0.0));
  // Phase 9.7 chroma key (previewed for WYSIWYG with the export).
  c.chroma_enabled = BoolOr(args, "cameraChromaKeyEnabled", false);
  c.chroma_strength = NumberOr(args, "cameraChromaKeyStrength", 0.4);
  if (const auto argb = OptionalInt(args, "cameraChromaKeyColorArgb")) {
    c.has_chroma_color = true;
    c.chroma_argb = static_cast<std::uint32_t>(*argb);
  }
  // Intro/outro animations. Same four keys the export request reads, with the
  // same fallbacks ("" -> kNone, 0 ms), so the preview and the export resolve
  // an identical CameraAnimationOutput from one payload.
  c.intro_preset = StringOrEmpty(args, "cameraIntroPreset");
  c.outro_preset = StringOrEmpty(args, "cameraOutroPreset");
  c.intro_duration_ms =
      static_cast<int>(NumberOr(args, "cameraIntroDurationMs", 0.0));
  c.outro_duration_ms =
      static_cast<int>(NumberOr(args, "cameraOutroDurationMs", 0.0));
  // Scale-with-screen-zoom. Same ""/0 (fixed bubble) fallbacks as the export
  // request parser, so a payload missing these renders identically on both.
  c.zoom_behavior = StringOrEmpty(args, "cameraZoomBehavior");
  c.zoom_scale_multiplier = NumberOr(args, "cameraZoomScaleMultiplier", 0.0);
  c.zoom_emphasis_preset = StringOrEmpty(args, "cameraZoomEmphasisPreset");
  c.zoom_emphasis_strength =
      NumberOr(args, "cameraZoomEmphasisStrength", 0.0);
  if (const auto it =
          args.find(flutter::EncodableValue("cameraNormalizedCenter"));
      it != args.end()) {
    if (const auto* center = std::get_if<flutter::EncodableMap>(&it->second)) {
      c.has_center = true;
      c.center_x = NumberOr(*center, "x", 0.0);
      c.center_y = NumberOr(*center, "y", 0.0);
    }
  }
  return c;
}

void ApplyCameraCompositionToExport(
    const preview::PreviewCameraComposition& c,
    capture::export_::PassthroughInput& input) {
  input.camera_visible = c.visible;
  input.camera_has_center = c.has_center;
  input.camera_center_x = c.center_x;
  input.camera_center_y = c.center_y;
  input.camera_layout_preset = c.layout_preset;
  input.camera_size_factor = c.size_factor;
  input.camera_shape = c.shape;
  input.camera_corner_radius = c.corner_radius;
  input.camera_content_mode = c.content_mode;
  input.camera_mirror = c.mirror;
  input.camera_opacity = c.opacity;
  input.camera_border_width = c.border_width;
  // The export keeps the nullable colours as optionals and only flattens them
  // when it builds the painter Style; the preview flattens at parse time. Same
  // information, two shapes — convert rather than leaving one side blank.
  input.camera_border_color_argb =
      c.has_border_color
          ? std::optional<std::int64_t>(static_cast<std::int64_t>(c.border_argb))
          : std::nullopt;
  input.camera_shadow_preset = c.shadow_preset;
  input.camera_chroma_enabled = c.chroma_enabled;
  input.camera_chroma_strength = c.chroma_strength;
  input.camera_chroma_color_argb =
      c.has_chroma_color
          ? std::optional<std::int64_t>(static_cast<std::int64_t>(c.chroma_argb))
          : std::nullopt;
  input.camera_intro_preset = c.intro_preset;
  input.camera_outro_preset = c.outro_preset;
  input.camera_intro_duration_ms = c.intro_duration_ms;
  input.camera_outro_duration_ms = c.outro_duration_ms;
  input.camera_zoom_behavior = c.zoom_behavior;
  input.camera_zoom_scale_multiplier = c.zoom_scale_multiplier;
  input.camera_zoom_emphasis_preset = c.zoom_emphasis_preset;
  input.camera_zoom_emphasis_strength = c.zoom_emphasis_strength;
}

}  // namespace clingfy::bridge
