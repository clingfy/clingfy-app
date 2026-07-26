// Canvas background preset palettes, ported from macOS
// `BackgroundPresetCatalog.swift`.
//
// These are DATA, not rendering. The preset on the wire carries a palette id;
// both platforms look it up here (or in the Swift catalog) and get the same
// ARGB stops, which is half of what makes a preset render the same on either
// machine — the other half is the seeded geometry in abstract_waves_params.h.
//
// Adding a palette means adding it to BOTH catalogs. A palette that exists on
// one platform and not the other renders as the default there rather than
// failing, so the divergence is silent — hence the parity test that pins the
// exact stop values against the Swift source.

#ifndef RUNNER_CAPTURE_BACKGROUND_BACKGROUND_PRESET_CATALOG_H_
#define RUNNER_CAPTURE_BACKGROUND_BACKGROUND_PRESET_CATALOG_H_

#include <cstdint>
#include <string>
#include <vector>

namespace clingfy::capture::background {

struct BackgroundPalette {
  std::string id;
  // Packed 0xAARRGGBB, dark -> light, used as evenly spaced gradient stops.
  std::vector<std::uint32_t> colors_argb;
};

// The default palette id, matching macOS `defaultPaletteId`.
extern const char* const kDefaultPaletteId;

// Every palette, in the same order as the Swift catalog.
const std::vector<BackgroundPalette>& AllBackgroundPalettes();

// The palette with `id`, or the default when unknown/empty — never fails, so a
// project carrying a palette this build does not know still renders.
const BackgroundPalette& BackgroundPaletteFor(const std::string& id);

// Preset ids the renderer dispatch recognizes, matching macOS `presetIds`.
// Only "abstractWaves" is implemented on Windows today; the others fall back to
// it rather than rendering nothing.
bool IsKnownPresetId(const std::string& id);

}  // namespace clingfy::capture::background

#endif  // RUNNER_CAPTURE_BACKGROUND_BACKGROUND_PRESET_CATALOG_H_
