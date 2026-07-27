// CanvasComposition — the one description of the canvas framing, shared by the
// two things that draw it: the export pipeline and the live preview.
//
// WHY THIS TYPE EXISTS (the bug it prevents)
//
// Dart sends `padding` and `cornerRadius` as raw EXPORT-OUTPUT pixels
// (see `Capture/Export/export_pipeline.h`: "symmetric inset in output pixels").
// The export renders at the user's chosen resolution — up to 3840x2160. The
// preview renders into a texture capped at 1280x720 (`preview/preview_engine.cpp`).
//
// Handing the same pixel number to both surfaces therefore does NOT produce the
// same picture:
//
//     padding = 100
//       export  3840 wide  ->  100/3840  =  2.6% of width   (thin border)
//       preview 1280 wide  ->  100/1280  =  7.8% of width   (thick border)
//
// The preview would show roughly 3x the padding the exported file has, and the
// error GROWS with export resolution — correct-looking at 720p, visibly wrong at
// 4K. That is the exact "what you see is not what you get" failure the live-render
// preview exists to eliminate.
//
// So the contract carries FRACTIONS, not pixels. Each consumer converts to its own
// surface on the way in. Fractions are taken against the canvas's SHORTER side,
// which keeps a symmetric inset symmetric on both axes (export applies the same
// absolute inset to width and height) and matches how the corner radius is already
// clamped ("half the shorter content side").
//
//   ┌──────────────── canvas (target) ────────────────┐
//   │            ↕ padding                            │
//   │      ┌───────────────────────────────────┐      │
//   │ ←──→ │            content rect           │ ←──→ │
//   │      │        (video is fit here)        │      │
//   │      └───────────────────────────────────┘      │
//   │            ↕ padding            ╰─ corner radius │
//   └─────────────────────────────────────────────────┘
//     padding_fraction = padding_px / min(canvas.w, canvas.h)
//
// Round-trip property, which `canvas_composition_test.cpp` pins:
//   Denormalize(Normalize(px, A), A) == px       (within rounding)
//   and the RATIO is preserved across surfaces of the same aspect, so the preview
//   and the export show proportionally identical framing.

#ifndef RUNNER_CORE_CANVAS_COMPOSITION_H_
#define RUNNER_CORE_CANVAS_COMPOSITION_H_

#include <cstdint>
#include <optional>
#include <string>

#include "Capture/Background/abstract_waves_renderer.h"

namespace clingfy::core {

// The canvas args exactly as Dart sends them: padding and corner radius in
// EXPORT-OUTPUT pixels, plus the presets needed to work out what canvas those
// pixels were measured against.
//
// Dart deliberately does NOT compute the export target itself. `ResolveTargetSize`
// lives in C++ (Capture/Export/export_geometry.h) and is the single source of
// truth for canvas sizing; duplicating it in Dart would be a second
// implementation to keep in sync, which is the drift this whole contract exists
// to prevent.
struct CanvasFramingArgs {
  double padding_px = 0.0;
  double corner_radius_px = 0.0;
  std::optional<std::int64_t> background_argb;
  // Absolute path to the background image, or empty for a colour background.
  // Dart bundles the chosen image INTO the .clingfyproj and sends the bundled
  // copy's path, so the reference cannot break when the original is moved,
  // deleted, or the project is opened on the other platform.
  std::wstring background_image_path;
  // Procedural preset, when the user picked one instead of a colour or image.
  // Empty `preset_id` means "no preset". Carried as DATA: the bitmap is
  // rendered on demand by the platform compositor and cached, never stored.
  capture::background::CanvasPresetSpec preset;
  bool has_preset = false;
  std::string layout_preset;
  std::string resolution_preset;
};

// Resolution-independent canvas framing. Both the export and the preview build
// one of these from the Dart payload, then denormalize against their own surface.
struct CanvasComposition {
  // Symmetric inset, as a fraction of the canvas's shorter side. 0 = no padding.
  double padding_fraction = 0.0;
  // Corner radius of the content rect, as a fraction of the canvas's shorter
  // side. 0 = square corners.
  double corner_radius_fraction = 0.0;
  // Packed 0xAARRGGBB fill behind and around the content. nullopt (the Dart
  // default) means opaque black, matching `ResolveBackgroundColor`.
  std::optional<std::int64_t> background_argb;
  // Absolute path to a bundled background image, or empty for a colour
  // background. When set it is drawn scaled-to-cover over the fill; the fill
  // still paints first so a missing or undecodable image degrades to the colour
  // rather than to nothing.
  std::wstring background_image_path;
  // Procedural preset. Rendered by the one platform compositor and cached by
  // `CanvasPresetCacheKey`, so preview, export and thumbnails share both the
  // renderer and the cache. `has_preset` false means colour/image background.
  capture::background::CanvasPresetSpec preset;
  bool has_preset = false;
};

// Convert a pixel value measured against a surface whose shorter side is
// `reference_short_side` into a resolution-independent fraction.
//
// A non-positive reference (a degenerate or not-yet-known surface) yields 0
// rather than a division by zero — the caller renders an unpadded canvas, which
// is the same thing today's Windows preview shows.
double NormalizeToShortSide(double pixels, double reference_short_side);

// Inverse of NormalizeToShortSide: resolve a fraction back to pixels on a surface
// whose shorter side is `target_short_side`. Negative results are clamped to 0.
double DenormalizeFromShortSide(double fraction, double target_short_side);

// Build the contract from the raw Dart payload values, which are expressed in
// EXPORT-OUTPUT pixels against a canvas whose shorter side is
// `export_short_side`. This is the single place raw pixels enter the system.
CanvasComposition MakeCanvasComposition(
    double padding_px, double corner_radius_px, double export_short_side,
    std::optional<std::int64_t> background_argb,
    std::wstring background_image_path = {});

}  // namespace clingfy::core

#endif  // RUNNER_CORE_CANVAS_COMPOSITION_H_
