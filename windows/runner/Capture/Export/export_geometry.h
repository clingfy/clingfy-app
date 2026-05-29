// Slice 2 of Phase 6 (export) — pure resolution / layout / fit geometry.
//
// This unit holds the math that turns the Dart-side `layoutPreset` /
// `resolutionPreset` / `fitMode` choices into concrete output pixel
// dimensions and a source-frame placement rectangle. It is a faithful
// C++ port of the macOS engine so a recording exported on either
// platform frames identically:
//
//   * `ResolveTargetSize`   mirrors ScreenRecorderFacade.resolveTargetSize
//                           (macos/Runner/Capture/Export/ExportPrep.swift).
//   * `ComputeContentRect`  mirrors the fit/fill scale + centering block
//                           in CompositionBuilder.swift (the
//                           `availableSize` / `min`-vs-`max` scale / `tx`
//                           / `ty` computation).
//
// Everything here is pure (no Win32, no Direct2D, no Media Foundation) so
// the math can be pinned by `export_geometry_test.cpp` against the exact
// vectors from `macos/RunnerTests/ExportPrepTests.swift` without standing
// up a GPU device or decoding a frame. The actual decode → composite →
// re-encode pipeline that consumes these values lives in
// `export_passthrough.cpp`.
//
// Windows-specific wrinkle vs macOS: H.264 requires even frame
// dimensions. macOS rides on AVFoundation which tolerates fractional
// CGFloat render sizes; the Media Foundation H.264 MFT does not. So the
// faithful `ResolveTargetSize` returns doubles (for vector parity with
// the Swift tests) and `ToEvenPixelSize` does the round-to-even clamp
// that the encoder config actually receives.

#ifndef RUNNER_CAPTURE_EXPORT_EXPORT_GEOMETRY_H_
#define RUNNER_CAPTURE_EXPORT_EXPORT_GEOMETRY_H_

#include <cstdint>
#include <string>

namespace clingfy::capture::export_ {

// Floating-point size, matching the precision the macOS math runs at so
// the ported vectors compare exactly before any pixel rounding.
struct SizeF {
  double width = 0.0;
  double height = 0.0;
};

// Source-frame placement on the output canvas, in output pixel
// coordinates. `x` / `y` may be negative when `fill` crops the source
// (the rendered content is larger than the canvas and gets clipped to
// the canvas bounds at draw time).
struct RectF {
  double x = 0.0;
  double y = 0.0;
  double width = 0.0;
  double height = 0.0;
};

// Final, encoder-ready output dimensions: integer and even.
struct PixelSize {
  std::uint32_t width = 0;
  std::uint32_t height = 0;
};

enum class FitMode {
  // Scale the source down until it fits inside the canvas; letterbox /
  // pillarbox bars fill the remainder. This is the macOS default when the
  // arg is missing or unrecognized.
  kFit,
  // Scale the source up until it covers the canvas; overflow is cropped.
  kFill,
};

// Parse the Dart-side `fitMode` arg ("fit" / "fill", case-insensitive).
// Anything else (including empty) maps to kFit, matching the macOS
// `params.fitMode ?? "fit"` fallback.
FitMode ParseFitMode(const std::string& fit);

// Faithful port of macOS `resolveTargetSize`. `layout` is one of
// {auto, classic43, square11, youtube169, reel916} and `resolution` is
// one of {auto, p1080, p1440, p2160, p4320}; unrecognized values fall
// through to the same "auto" branches the Swift `default:` cases take.
// Returns the exact (possibly fractional) target size; callers feed the
// result through `ToEvenPixelSize` before handing it to the encoder.
SizeF ResolveTargetSize(SizeF source, const std::string& layout,
                        const std::string& resolution);

// Round a target size to the nearest integer, force both axes even
// (H.264 requirement), and clamp to a >= 2 floor so a degenerate input
// never produces a 0-pixel encoder config.
PixelSize ToEvenPixelSize(SizeF size);

// Faithful port of the CompositionBuilder fit/fill block: compute where
// the source frame lands inside `target`, given the fit mode and an
// optional symmetric `padding` (Slice 2 always passes 0 — padding is
// Slice 3 — but the parameter is here so Slice 3 extends rather than
// rewrites this function).
RectF ComputeContentRect(SizeF target, SizeF source, FitMode fit,
                         double padding = 0.0);

// True when the export needs no reframing at all: `layout` and
// `resolution` are both "auto" (or empty), so the output is pixel-for-
// pixel the source. The router uses this to take the Slice 1 copy
// fast-path — lossless and instant — instead of running a full
// decode → composite → re-encode pass that would only re-encode the
// recording into an identical frame at a generation-loss cost.
bool IsIdentityTransform(const std::string& layout,
                         const std::string& resolution);

}  // namespace clingfy::capture::export_

#endif  // RUNNER_CAPTURE_EXPORT_EXPORT_GEOMETRY_H_
