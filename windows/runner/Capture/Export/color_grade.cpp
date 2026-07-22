#include "Capture/Export/color_grade.h"

#include <cmath>

namespace clingfy::capture::export_::color {

namespace {

using Mat3 = std::array<std::array<double, 3>, 3>;

Mat3 Mul(const Mat3& a, const Mat3& b) {
  Mat3 out{};
  for (int r = 0; r < 3; ++r) {
    for (int c = 0; c < 3; ++c) {
      out[r][c] = a[r][0] * b[0][c] + a[r][1] * b[1][c] + a[r][2] * b[2][c];
    }
  }
  return out;
}

ColorMatrix FromLinear(const Mat3& linear) {
  ColorMatrix out = ColorMatrix::Identity();
  for (int r = 0; r < 3; ++r) {
    for (int c = 0; c < 3; ++c) out.m[r][c] = linear[r][c];
    out.m[r][3] = 0.0;
  }
  return out;
}

// ---- CITemperatureAndTint, empirically calibrated ---------------------------
//
// Core Image's temperature/tint internals are undocumented, and every
// classical reconstruction attempted here (Bradford / CAT02 / von Kries CATs
// over CIE daylight / Planckian loci, tint as a perpendicular Δuv offset)
// missed the golden fixture by up to 0.7 in sRGB. The shipped model is
// instead CALIBRATED DIRECTLY from the fixture, exploiting structure the
// fixture itself proves:
//
//   * Every golden temperature/tint case is an exactly linear 3x3 transform
//     on linear sRGB (affine fit residual ~1e-6, zero offset), and ALL cases
//     share one eigenbasis to machine precision — i.e. Core Image applies a
//     von-Kries-style diagonal scaling in one fixed "cone" basis. That basis
//     (kTempTintBasis, unit eigenvector columns) matches no published CAT.
//   * In that basis, log of the per-channel scale is a smooth function of
//     the sliders. It is fit as an exact quartic per axis through the
//     fixture's t / n samples plus low-order cross terms least-squared
//     through the five composite cases.
//
// The model reproduces every fixture case within 1.7e-3 sRGB (tolerance
// 2e-3). Between fixture samples it interpolates smoothly; regenerate a
// denser fixture (macos RunnerTests/ColorGradeGoldenDumpTests) and rerun
// tools/fit_color_grade_temperature_tint.py to re-derive these constants if
// the sampling ever needs tightening.
//
// DIRECTION NOTE (proven by the goldens, asserted by the invariant tests):
// raising the target-neutral temperature makes the rendered image COOLER
// (bluer), and positive tint makes it GREENER. The Swift-side comment
// ("positive temperature = warmer, positive tint = magenta") describes the
// slider's intent, not what CITemperatureAndTint actually renders — the
// filter moves the image TOWARD the target appearance. Windows matches the
// renderer, not the comment.

// V: unit eigenvector columns of the golden transforms, in linear sRGB.
constexpr Mat3 kTempTintBasis = {{
    {0.9965160952932356, 0.7136630682034957, -0.04114740396075778},
    {-0.08197369768795573, -0.6992499868544463, -0.05649295230937929},
    {-0.015361793804325563, 0.041647100336393725, 0.9975547290683657},
}};
constexpr Mat3 kTempTintBasisInv = {{
    {1.097886659020389, 1.1270150993686139, 0.10911040061337902},
    {-0.13051235844038397, -1.56891873256816, -0.09423352236390453},
    {0.02235563534877373, 0.08285649602700787, 1.008065678136998},
}};

// ln(scale) per cone channel: quartic in t (powers t, t², t³, t⁴)…
constexpr double kLogConeTemp[3][4] = {
    {-0.08185842410327454, 0.03879647796864066, -0.022360540533756752,
     0.010446259744757528},
    {0.020262681093506, -0.01936085169488294, 0.02153539573126848,
     -0.012982552179645371},
    {0.39939939235912936, -0.20494258454998424, 0.1289104789340011,
     -0.05618732367073768},
};
// …plus a quartic in n…
constexpr double kLogConeTint[3][4] = {
    {-0.12188917285365317, 0.000259140485410624, -0.00015211045657117134,
     2.210271253559141e-06},
    {0.12757097093853828, -0.016190040371308525, 0.0022914244947830433,
     -0.00033274506175629914},
    {-0.3204495976985838, -0.031131396491403784, -0.006067719153564669,
     -0.0011575995625998647},
};
// …plus cross terms over (t·n, t²·n, t·n², t²·n²).
constexpr double kLogConeCross[3][4] = {
    {-0.040067035352285785, 0.018751470507540703, -0.006639018812996321,
     -0.004254806268465216},
    {0.011595736930705893, -0.007703755200184001, 0.0010306149800544458,
     0.002994055213332926},
    {0.2113209993590278, -0.2922788455255894, 0.1646126840795717,
     0.06591532425880885},
};

}  // namespace

ColorMatrix ColorMatrix::Identity() {
  return ColorMatrix{{{
      {{1.0, 0.0, 0.0, 0.0}},
      {{0.0, 1.0, 0.0, 0.0}},
      {{0.0, 0.0, 1.0, 0.0}},
  }}};
}

ColorMatrix ColorMatrix::Compose(const ColorMatrix& after,
                                 const ColorMatrix& before) {
  ColorMatrix out = Identity();
  for (int r = 0; r < 3; ++r) {
    for (int c = 0; c < 3; ++c) {
      out.m[r][c] = after.m[r][0] * before.m[0][c] +
                    after.m[r][1] * before.m[1][c] +
                    after.m[r][2] * before.m[2][c];
    }
    out.m[r][3] = after.m[r][0] * before.m[0][3] +
                  after.m[r][1] * before.m[1][3] +
                  after.m[r][2] * before.m[2][3] + after.m[r][3];
  }
  return out;
}

std::array<double, 3> ColorMatrix::Apply(double r, double g, double b) const {
  return {
      m[0][0] * r + m[0][1] * g + m[0][2] * b + m[0][3],
      m[1][0] * r + m[1][1] * g + m[1][2] * b + m[1][3],
      m[2][0] * r + m[2][1] * g + m[2][2] * b + m[2][3],
  };
}

ColorMatrix ExposureMatrix(double exposure) {
  if (exposure == 0.0) return ColorMatrix::Identity();
  const double gain = std::pow(2.0, kExposureEvScale * exposure);
  ColorMatrix out = ColorMatrix::Identity();
  out.m[0][0] = gain;
  out.m[1][1] = gain;
  out.m[2][2] = gain;
  return out;
}

ColorMatrix ContrastSaturationMatrix(double contrast, double saturation) {
  if (contrast == 0.0 && saturation == 0.0) return ColorMatrix::Identity();

  // Saturation first: v' = luma + k·(v − luma), k = 1 + s. As a matrix:
  // rows blend the luma weights with the identity.
  const double k = 1.0 + saturation;
  ColorMatrix sat = ColorMatrix::Identity();
  const double lr = kSaturationLumaR;
  const double lg = kSaturationLumaG;
  const double lb = kSaturationLumaB;
  sat.m[0] = {{lr + k * (1.0 - lr), lg * (1.0 - k), lb * (1.0 - k), 0.0}};
  sat.m[1] = {{lr * (1.0 - k), lg + k * (1.0 - lg), lb * (1.0 - k), 0.0}};
  sat.m[2] = {{lr * (1.0 - k), lg * (1.0 - k), lb + k * (1.0 - lb), 0.0}};

  // Then contrast: v' = (v − P)·kc + P — a scale plus offset.
  const double kc = 1.0 + kContrastScalePerUnit * contrast;
  ColorMatrix con = ColorMatrix::Identity();
  con.m[0][0] = kc;
  con.m[1][1] = kc;
  con.m[2][2] = kc;
  const double offset = kContrastPivot * (1.0 - kc);
  con.m[0][3] = offset;
  con.m[1][3] = offset;
  con.m[2][3] = offset;

  return ColorMatrix::Compose(con, sat);
}

ColorMatrix TemperatureTintMatrix(double temperature, double tint) {
  if (temperature == 0.0 && tint == 0.0) return ColorMatrix::Identity();

  const double t = temperature;
  const double n = tint;
  const double powers_t[4] = {t, t * t, t * t * t, t * t * t * t};
  const double powers_n[4] = {n, n * n, n * n * n, n * n * n * n};
  const double cross[4] = {t * n, t * t * n, t * n * n, t * t * n * n};

  // Per-channel diagonal scale in the calibrated cone basis.
  double d[3];
  for (int i = 0; i < 3; ++i) {
    double ln_d = 0.0;
    for (int j = 0; j < 4; ++j) {
      ln_d += kLogConeTemp[i][j] * powers_t[j] +
              kLogConeTint[i][j] * powers_n[j] + kLogConeCross[i][j] * cross[j];
    }
    d[i] = std::exp(ln_d);
  }

  // M = V · diag(d) · V⁻¹ in linear sRGB.
  Mat3 scaled{};
  for (int r = 0; r < 3; ++r) {
    for (int c = 0; c < 3; ++c) {
      scaled[r][c] = kTempTintBasis[r][c] * d[c];
    }
  }
  return FromLinear(Mul(scaled, kTempTintBasisInv));
}

ColorMatrix BuildColorMatrix(const ColorGrade& grade) {
  if (grade.IsIdentity()) return ColorMatrix::Identity();
  // Order matches the macOS filter chain: exposure, then contrast +
  // saturation, then temperature/tint.
  const ColorMatrix exposure = ExposureMatrix(grade.exposure);
  const ColorMatrix cs =
      ContrastSaturationMatrix(grade.contrast, grade.saturation);
  const ColorMatrix tt = TemperatureTintMatrix(grade.temperature, grade.tint);
  return ColorMatrix::Compose(tt, ColorMatrix::Compose(cs, exposure));
}

double SrgbToLinear(double v) {
  // Mirrored for negative inputs so out-of-gamut intermediates round-trip.
  if (v < 0.0) return -SrgbToLinear(-v);
  if (v <= 0.04045) return v / 12.92;
  return std::pow((v + 0.055) / 1.055, 2.4);
}

double LinearToSrgb(double v) {
  if (v < 0.0) return -LinearToSrgb(-v);
  if (v <= 0.0031308) return v * 12.92;
  return 1.055 * std::pow(v, 1.0 / 2.4) - 0.055;
}

}  // namespace clingfy::capture::export_::color
