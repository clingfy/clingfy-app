#include "Capture/Export/export_geometry.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <optional>

namespace clingfy::capture::export_ {

namespace {

// Lower-case a copy of `value` using the C locale. The Dart side already
// sends canonical lower-case enum names, but the macOS `fitMode` parsing
// is case-insensitive (its test feeds "MOV" through exportFormatInfo), so
// we match that tolerance here rather than assume canonical input.
std::string ToLowerAscii(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](unsigned char c) {
                   return static_cast<char>(std::tolower(c));
                 });
  return value;
}

}  // namespace

FitMode ParseFitMode(const std::string& fit) {
  return ToLowerAscii(fit) == "fill" ? FitMode::kFill : FitMode::kFit;
}

SizeF ResolveTargetSize(SizeF source, const std::string& layout,
                        const std::string& resolution) {
  // 1. Aspect ratio from the layout preset (macOS step 1). Unknown
  //    layouts fall through to the source aspect, matching the Swift
  //    `default:` arm.
  const double safe_source_height = std::max(source.height, 1.0);
  const double source_aspect = source.width / safe_source_height;
  double aspect;
  if (layout == "classic43") {
    aspect = 4.0 / 3.0;
  } else if (layout == "square11") {
    aspect = 1.0;
  } else if (layout == "youtube169") {
    aspect = 16.0 / 9.0;
  } else if (layout == "reel916") {
    aspect = 9.0 / 16.0;
  } else {
    aspect = source_aspect;
  }

  // 2. Short-side pixels from the resolution preset (macOS step 2). The
  //    "auto" arm preserves source pixels but honors the chosen aspect.
  double short_side;
  if (resolution == "p1080") {
    short_side = 1080.0;
  } else if (resolution == "p1440") {
    short_side = 1440.0;
  } else if (resolution == "p2160") {
    short_side = 2160.0;
  } else if (resolution == "p4320") {
    short_side = 4320.0;
  } else {
    // Auto resolution: with an "auto" layout (or a degenerate source) the
    // target is just the source. Otherwise expand the source along one
    // axis to satisfy the chosen aspect. Mirrors the Swift `guard`.
    if (layout == "auto" || source.width <= 0.0 || source.height <= 0.0) {
      return source;
    }
    if (aspect >= source_aspect) {
      return SizeF{source.height * aspect, source.height};
    }
    return SizeF{source.width, source.width / aspect};
  }

  // 3. Final size: the short side is the height for horizontal/square
  //    aspects and the width for vertical aspects (macOS step 3).
  if (aspect >= 1.0) {
    return SizeF{short_side * aspect, short_side};
  }
  return SizeF{short_side, short_side / aspect};
}

PixelSize ToEvenPixelSize(SizeF size) {
  const auto round_even = [](double value) -> std::uint32_t {
    long long rounded = std::llround(value);
    if (rounded < 2) {
      rounded = 2;
    }
    if ((rounded % 2) != 0) {
      // Round the odd value up so the encoded frame never drops a column
      // or row of the fitted content.
      rounded += 1;
    }
    return static_cast<std::uint32_t>(rounded);
  };
  return PixelSize{round_even(size.width), round_even(size.height)};
}

RectF ComputeContentRect(SizeF target, SizeF source, FitMode fit,
                         double padding) {
  // Available canvas after symmetric padding (macOS clamps each axis to a
  // >= 1 floor before dividing).
  const double available_w = std::max(1.0, target.width - 2.0 * padding);
  const double available_h = std::max(1.0, target.height - 2.0 * padding);

  const double scale_w = available_w / std::max(source.width, 1.0);
  const double scale_h = available_h / std::max(source.height, 1.0);
  const double scale =
      (fit == FitMode::kFill) ? std::max(scale_w, scale_h)
                              : std::min(scale_w, scale_h);

  const double content_w = source.width * scale;
  const double content_h = source.height * scale;
  const double tx = (target.width - content_w) / 2.0;
  const double ty = (target.height - content_h) / 2.0;
  return RectF{tx, ty, content_w, content_h};
}

RgbaColor ResolveBackgroundColor(std::optional<std::int64_t> argb_opt) {
  // Dart sends null when the user never picked a color; macOS resolves that
  // (and a bare 0x000000) to opaque black.
  if (!argb_opt.has_value()) {
    return RgbaColor{0.0, 0.0, 0.0, 1.0};
  }
  // Mask to 32 bits so a sign-extended int32 (Flutter may encode an ARGB
  // with the alpha high bit set as a negative int32) still reads as the
  // intended 0xAARRGGBB.
  const std::uint32_t argb =
      static_cast<std::uint32_t>(*argb_opt & 0xFFFFFFFFLL);
  const double r = static_cast<double>((argb >> 16) & 0xFFu) / 255.0;
  const double g = static_cast<double>((argb >> 8) & 0xFFu) / 255.0;
  const double b = static_cast<double>(argb & 0xFFu) / 255.0;
  // Match VideoColorPipeline: only honor an alpha byte when the value
  // carries one (> 0x00FFFFFF); otherwise treat it as fully opaque.
  const double a = (argb > 0x00FFFFFFu)
                       ? static_cast<double>((argb >> 24) & 0xFFu) / 255.0
                       : 1.0;
  return RgbaColor{r, g, b, a};
}

double ResolveCornerRadiusPx(double requested, RectF content) {
  if (requested <= 0.0) {
    return 0.0;
  }
  const double max_radius = std::min(content.width, content.height) / 2.0;
  if (max_radius <= 0.0) {
    return 0.0;
  }
  return std::min(requested, max_radius);
}

bool IsIdentityTransform(const std::string& layout,
                         const std::string& resolution) {
  const bool layout_auto = layout.empty() || layout == "auto";
  const bool resolution_auto = resolution.empty() || resolution == "auto";
  return layout_auto && resolution_auto;
}

}  // namespace clingfy::capture::export_
