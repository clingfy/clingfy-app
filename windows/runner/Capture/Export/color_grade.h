// Editing-features port (color) — pure color-grade math.
//
// C++ counterpart of the macOS color grade (`ColorGrade` +
// `ColorGradeRenderer` in macos/Runner/Capture/Export/CompositionBuilder.swift).
// macOS applies a Core Image filter chain; Windows collapses the same chain
// into ONE affine color matrix applied to LINEAR RGB, because every leg of
// the chain is linear algebra:
//
//   Dart slider value            macOS filter            linear-RGB algebra
//   ─────────────────            ────────────            ──────────────────
//   exposure    e ∈ [-1,1]  →  CIExposureAdjust        gain  g = 2^(1.5·e)
//   contrast    c ∈ [-1,1]  →  CIColorControls         v' = (v−P)·k + P,
//                                                        k = 1 + 0.5·c
//   saturation  s ∈ [-1,1]  →  CIColorControls         v' = luma + (1+s)·(v−luma)
//   temperature t ∈ [-1,1]  →  CITemperatureAndTint    von-Kries diagonal in a
//   tint        n ∈ [-1,1]  →  (same filter)             fixture-calibrated cone
//                                                         basis (see .cpp)
//
// Order is load-bearing and matches macOS: exposure → contrast+saturation →
// temperature/tint. The composed matrix operates on linear RGB; callers
// convert sRGB-encoded pixels to linear before applying and re-encode after
// (in D2D: a ColorManagement/custom-shader linearization with
// D2D1_BUFFER_PRECISION_16BPC_FLOAT — Direct2D has no piecewise-sRGB
// primitive and 8bpc intermediates band in the shadows).
//
// PARITY CONTRACT: Apple does not document the exact internals of
// CIColorControls / CITemperatureAndTint (contrast pivot, saturation luma
// weights, temperature/tint transform). The constants marked "CALIBRATED"
// below and the temperature/tint model in the .cpp are therefore derived
// from — and validated against — golden fixtures captured from the real
// macOS renderer:
//   windows/runner_tests/fixtures/color_grade_golden.json
//   (regenerate with macos RunnerTests/ColorGradeGoldenDumpTests, then rerun
//    tools/fit_color_grade_temperature_tint.py to re-derive the .cpp
//    constants; both belong in the same PR as any ColorGradeRenderer change).
//
// DIRECTION NOTE: the goldens prove the real render direction — positive
// temperature makes the image COOLER (bluer), positive tint GREENER. The
// Swift comments say "warmer"/"magenta"; they describe intent, not the
// render. Windows matches the render (see the .cpp direction note).
//
// IsIdentity is NUMBERS-ONLY: `auto_enabled` is deliberately ignored, matching
// the Swift `ColorGrade.isIdentity` (auto-enhance with all-zero values must
// behave as identity — macOS test
// `testIsIdentityIgnoresAutoFlagWhenNumbersAreNeutral`). Values are NOT
// clamped: macOS does not clamp, and the Dart controller already bounds the
// sliders — clamping here would diverge for out-of-range wire values.
//
// Everything here is pure (no Win32, no Direct2D, no Flutter headers).
// Parsing the Dart `colorGrade` wire map lives with the routers
// (Bridge/Routers/color_grade_args.h), matching the clip_playback_planner
// precedent.
//
// Keep this in sync with the Swift renderer: behavior changes land on both
// platforms in the same change or not at all.

#ifndef RUNNER_CAPTURE_EXPORT_COLOR_GRADE_H_
#define RUNNER_CAPTURE_EXPORT_COLOR_GRADE_H_

#include <array>

namespace clingfy::capture::export_::color {

// Mirrors the Dart ColorGrade (lib/core/timeline/model/color_grade.dart) and
// the Swift struct. All numeric fields nominally [-1, 1]; not clamped.
struct ColorGrade {
  bool auto_enabled = false;
  double exposure = 0.0;
  double contrast = 0.0;
  double saturation = 0.0;
  double temperature = 0.0;
  double tint = 0.0;

  // Numbers-only, matching Swift (auto_enabled deliberately excluded).
  bool IsIdentity() const {
    return exposure == 0.0 && contrast == 0.0 && saturation == 0.0 &&
           temperature == 0.0 && tint == 0.0;
  }

  friend bool operator==(const ColorGrade& a, const ColorGrade& b) {
    return a.auto_enabled == b.auto_enabled && a.exposure == b.exposure &&
           a.contrast == b.contrast && a.saturation == b.saturation &&
           a.temperature == b.temperature && a.tint == b.tint;
  }
  friend bool operator!=(const ColorGrade& a, const ColorGrade& b) {
    return !(a == b);
  }
};

// Row-major 3x4 affine transform on linear RGB:
//   out.r = m[0][0]·r + m[0][1]·g + m[0][2]·b + m[0][3]
//   (rows 1, 2 likewise for g, b)
// The layout maps 1:1 onto the upper-left of a Direct2D color-matrix effect's
// 5x4 matrix (alpha row identity, offsets in the translation row).
struct ColorMatrix {
  std::array<std::array<double, 4>, 3> m;

  static ColorMatrix Identity();

  // Composes `after ∘ before` (apply `before` first). Affine-aware.
  static ColorMatrix Compose(const ColorMatrix& after,
                             const ColorMatrix& before);

  // Applies the affine transform to one linear-RGB triple. Test/CPU helper —
  // the production path uploads the matrix to a D2D color-matrix effect.
  std::array<double, 3> Apply(double r, double g, double b) const;

  friend bool operator==(const ColorMatrix& a, const ColorMatrix& b) {
    return a.m == b.m;
  }
};

// --- Mapping constants (from Clingfy's own Swift code — exact, not tuned) ---
inline constexpr double kExposureEvScale = 1.5;     // e → EV stops
inline constexpr double kContrastScalePerUnit = 0.5;  // c → slope 1 + 0.5c

// --- CALIBRATED constants (CI internals undocumented; derived from the
// --- golden fixture — rerun tools/fit_color_grade_temperature_tint.py after
// --- regenerating the fixture) ---------------------------------------------
// Contrast pivot in linear RGB (CIColorControls pivots mid-gray).
inline constexpr double kContrastPivot = 0.5;
// Saturation luma weights, calibrated from the fixture's pure-saturation
// cases and renormalized to sum EXACTLY 1 so gray stays a fixed point
// (Rec.709-shaped but not exactly Rec.709 — the calibrated values take the
// s = ±1 golden error from 1.0e-3 to 1e-6).
inline constexpr double kSaturationLumaR = 0.21250004500713318;
inline constexpr double kSaturationLumaG = 0.7153998170249231;
inline constexpr double kSaturationLumaB = 0.07210013796794383;
// The temperature/tint model constants (cone basis + log-scale polynomials)
// live in color_grade.cpp — they are implementation detail of
// TemperatureTintMatrix, not part of the header contract.

// Builds the single composed matrix for a grade. Identity grade returns
// ColorMatrix::Identity() exactly (callers use IsIdentity() to skip the whole
// pass; this is belt-and-braces).
ColorMatrix BuildColorMatrix(const ColorGrade& grade);

// Individual legs, exposed for composition-order tests. Each returns the
// affine transform for that leg alone (identity when the value is 0).
ColorMatrix ExposureMatrix(double exposure);
ColorMatrix ContrastSaturationMatrix(double contrast, double saturation);
ColorMatrix TemperatureTintMatrix(double temperature, double tint);

// sRGB transfer functions (piecewise IEC 61966-2-1, mirrored for negative
// inputs so out-of-gamut intermediates round-trip). Test/CPU helpers — the
// production path linearizes on the GPU.
double SrgbToLinear(double v);
double LinearToSrgb(double v);

}  // namespace clingfy::capture::export_::color

#endif  // RUNNER_CAPTURE_EXPORT_COLOR_GRADE_H_
