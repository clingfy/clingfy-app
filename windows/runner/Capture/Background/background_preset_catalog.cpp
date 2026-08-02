#include "Capture/Background/background_preset_catalog.h"

#include <algorithm>

namespace clingfy::capture::background {

const char* const kDefaultPaletteId = "bluePurple";

const std::vector<BackgroundPalette>& AllBackgroundPalettes() {
  // Verbatim from macOS BackgroundPresetCatalog.swift. Order matters only for
  // the picker; lookup is by id.
  static const std::vector<BackgroundPalette> kPalettes = {
      {"bluePurple",
       {0xFF1B1E3D, 0xFF3B2E78, 0xFF6C4AB6, 0xFF8D72E1, 0xFFB9A7F2}},
      {"sunset",
       {0xFF2A1633, 0xFF7A2E5D, 0xFFC94B6B, 0xFFF2785C, 0xFFF7B267}},
      {"aurora",
       {0xFF06243B, 0xFF0E5C63, 0xFF1E9E8A, 0xFF4FD1A5, 0xFFA7F0BA}},
      {"forest",
       {0xFF10241C, 0xFF1F4D3A, 0xFF2F7D5B, 0xFF5DA47C, 0xFF9CC9A8}},
      {"mono",
       {0xFF15171A, 0xFF272B30, 0xFF3C424A, 0xFF5A626C, 0xFF7E8893}},
  };
  return kPalettes;
}

const BackgroundPalette& BackgroundPaletteFor(const std::string& id) {
  const auto& all = AllBackgroundPalettes();
  const auto match =
      std::find_if(all.begin(), all.end(),
                   [&](const BackgroundPalette& p) { return p.id == id; });
  if (match != all.end()) return *match;

  const auto fallback =
      std::find_if(all.begin(), all.end(), [](const BackgroundPalette& p) {
        return p.id == kDefaultPaletteId;
      });
  // The catalog is a compile-time constant with the default present, so the
  // second lookup cannot miss; front() keeps this total regardless.
  return fallback != all.end() ? *fallback : all.front();
}

bool IsKnownPresetId(const std::string& id) {
  return id == "abstractWaves" || id == "graphicMesh" || id == "radialGlow";
}

}  // namespace clingfy::capture::background
