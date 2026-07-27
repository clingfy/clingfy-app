// Direct2D renderer for procedural canvas backgrounds.
//
// This is THE renderer for presets on Windows. The live preview, the export,
// and the preset thumbnail all call it — one implementation, so they cannot
// drift from each other. Its output is a bitmap that callers treat as a CACHE:
// the preset data is the source of truth, the pixels are regenerable.
//
// Mirrors macOS `AbstractWavesBackgroundRenderer.swift` pass for pass:
//
//   1. tilted linear base gradient over the palette stops
//   2. four wave ribbons, back to front
//   3. two radial white highlights
//   4. optional Gaussian softening
//
// Geometry comes from `abstract_waves_params.h`, which reproduces macOS's seeded
// stream exactly — so both platforms place the same waves. Only rasterization
// differs here (D2D antialiasing / gradient interpolation / blur kernel vs Core
// Graphics), which is the accepted tradeoff: renders are visually equivalent
// across machines, and identical on any one machine because preview and export
// share this code.
//
// COORDINATE FLIP
//
// The params are expressed in macOS's bottom-left origin space (y up), matching
// the Swift they mirror. Direct2D is top-left origin (y down). The flip happens
// HERE, in one place, rather than being smeared through the maths:
//
//     y_d2d = height - y_macos

#ifndef RUNNER_CAPTURE_BACKGROUND_CANVAS_PRESET_RENDERER_H_
#define RUNNER_CAPTURE_BACKGROUND_CANVAS_PRESET_RENDERER_H_

#include <windows.h>
#include <d2d1_1.h>
#include <wrl/client.h>

#include <cstdint>
#include <string>

namespace clingfy::capture::background {

// A preset exactly as it travels on the wire: data, never pixels.
struct CanvasPresetSpec {
  std::string preset_id;   // e.g. "abstractWaves"; unknown ids render waves
  std::string palette_id;  // resolved via BackgroundPaletteFor
  double intensity = 0.5;  // 0..1, clamped
  double blur = 0.0;       // 0..1, clamped; below the sigma floor = no pass
  std::int64_t seed = 0;
};

// Render `spec` into a fresh offscreen bitmap of `width` x `height`.
//
// Returns null when the size is degenerate or a D2D resource cannot be created;
// callers fall back to the flat background colour, which is what a project with
// no preset already shows.
//
// THREADING / DRAW STATE: this creates its own render target and runs its own
// BeginDraw/EndDraw, and it temporarily retargets `ctx`. It therefore must NOT
// be called between the caller's own BeginDraw and EndDraw — the same rule the
// camera painter's shadow bake follows. The caller's target is restored before
// returning.
Microsoft::WRL::ComPtr<ID2D1Bitmap1> RenderCanvasPreset(
    ID2D1DeviceContext* ctx, UINT width, UINT height,
    const CanvasPresetSpec& spec);

// Stable cache key for a rendered preset: identical specs at identical sizes
// produce identical keys, and any change to the preset OR the renderer version
// produces a different one. Callers use it to avoid re-rendering, and to
// invalidate automatically when this renderer changes.
std::string CanvasPresetCacheKey(const CanvasPresetSpec& spec, UINT width,
                                 UINT height);

// Bumped whenever a change here alters output pixels. Part of the cache key, so
// stale caches regenerate instead of showing pre-change art.
inline constexpr int kCanvasPresetRendererVersion = 1;

}  // namespace clingfy::capture::background

#endif  // RUNNER_CAPTURE_BACKGROUND_CANVAS_PRESET_RENDERER_H_
