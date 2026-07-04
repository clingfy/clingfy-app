#include "Capture/Export/color_grade.h"

#include <cmath>

namespace clingfy::capture::export_::color {

namespace {

using Mat3 = std::array<std::array<double, 3>, 3>;
using Vec3 = std::array<double, 3>;

// Linear sRGB ↔ CIE XYZ (D65), IEC 61966-2-1 reference matrices.
constexpr Mat3 kXyzFromRgb = {{
    {0.4124564, 0.3575761, 0.1804375},
    {0.2126729, 0.7151522, 0.0721750},
    {0.0193339, 0.1191920, 0.9503041},
}};
constexpr Mat3 kRgbFromXyz = {{
    {3.2404542, -1.5371385, -0.4985314},
    {-0.9692660, 1.8760108, 0.0415560},
    {0.0556434, -0.2040259, 1.0572252},
}};

// Bradford cone-response matrices (the CAT Core Image documents for its
// chromatic-adaptation workflows).
constexpr Mat3 kBradford = {{
    {0.8951, 0.2664, -0.1614},
    {-0.7502, 1.7135, 0.0367},
    {0.0389, -0.0685, 1.0296},
}};
constexpr Mat3 kBradfordInv = {{
    {0.9869929, -0.1470543, 0.1599627},
    {0.4323053, 0.5183603, 0.0492912},
    {-0.0085287, 0.0400428, 0.9684867},
}};

Vec3 Mul(const Mat3& m, const Vec3& v) {
  return {
      m[0][0] * v[0] + m[0][1] * v[1] + m[0][2] * v[2],
      m[1][0] * v[0] + m[1][1] * v[1] + m[1][2] * v[2],
      m[2][0] * v[0] + m[2][1] * v[1] + m[2][2] * v[2],
  };
}

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

// CCT → CIE 1931 xy chromaticity.
//
// CALIBRATED: Core Image's method is undocumented. We use the CIE daylight
// locus for T ≥ 4000K (its published validity range) and the Kim et al.
// Planckian-locus cubic approximation below (the grade's floor is 3500K at
// temperature = -1). The regime seam at 4000K is a known approximation —
// tune against the golden fixture if the low-temperature cases disagree.
void CctToXy(double kelvin, double* x_out, double* y_out) {
  const double t = kelvin;
  const double t2 = t * t;
  const double t3 = t2 * t;
  double x;
  double y;
  if (t >= 4000.0) {
    // CIE daylight locus (4000K–25000K).
    if (t <= 7000.0) {
      x = -4.6070e9 / t3 + 2.9678e6 / t2 + 0.09911e3 / t + 0.244063;
    } else {
      x = -2.0064e9 / t3 + 1.9018e6 / t2 + 0.24748e3 / t + 0.237040;
    }
    y = -3.000 * x * x + 2.870 * x - 0.275;
  } else {
    // Kim et al. Planckian approximation (2222K–4000K branch).
    x = -0.2661239e9 / t3 - 0.2343589e6 / t2 + 0.8776956e3 / t + 0.179910;
    const double x2 = x * x;
    const double x3 = x2 * x;
    y = -0.9549476 * x3 - 1.37418593 * x2 + 2.09137015 * x - 0.16748867;
  }
  *x_out = x;
  *y_out = y;
}

// (temperature kelvin, tint units) → CIE XYZ white point (Y = 1).
//
// Tint is a perpendicular offset from the locus in CIE 1960 uv space —
// positive tint pushes toward magenta (below the locus), matching the macOS
// comment "positive tint = magenta". The normal direction is derived from
// the local locus tangent so the offset stays perpendicular everywhere.
Vec3 WhitePointXyz(double kelvin, double tint_units) {
  double x;
  double y;
  CctToXy(kelvin, &x, &y);

  if (tint_units != 0.0) {
    // xy → CIE 1960 uv.
    auto to_uv = [](double xx, double yy, double* u, double* v) {
      const double d = -2.0 * xx + 12.0 * yy + 3.0;
      *u = 4.0 * xx / d;
      *v = 6.0 * yy / d;
    };
    double u;
    double v;
    to_uv(x, y, &u, &v);

    // Local locus tangent via a small CCT step; normal = tangent rotated 90°.
    const double dk = 10.0;
    double xa, ya, xb, yb;
    CctToXy(kelvin - dk, &xa, &ya);
    CctToXy(kelvin + dk, &xb, &yb);
    double ua, va, ub, vb;
    to_uv(xa, ya, &ua, &va);
    to_uv(xb, yb, &ub, &vb);
    double tan_u = ub - ua;
    double tan_v = vb - va;
    const double len = std::sqrt(tan_u * tan_u + tan_v * tan_v);
    if (len > 0.0) {
      tan_u /= len;
      tan_v /= len;
      // Rotate tangent +90° → (−tan_v, tan_u) points ABOVE the locus
      // (green); positive tint goes magenta (below), hence the minus.
      const double duv = tint_units * kTintUnitsToDuv;
      u -= -tan_v * duv;
      v -= tan_u * duv;
    }

    // uv → xy.
    const double d = 2.0 * u - 8.0 * v + 4.0;
    x = 3.0 * u / d;
    y = 2.0 * v / d;
  }

  return {x / y, 1.0, (1.0 - x - y) / y};
}

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

  // Both white points run through the same locus math, so t=0/n=0 yields an
  // exact identity (source == destination) by construction.
  const Vec3 neutral_wp = WhitePointXyz(kTemperatureNeutralK, 0.0);
  const Vec3 target_wp = WhitePointXyz(
      kTemperatureNeutralK + kTemperatureSpanK * temperature,
      kTintSpan * tint);

  // Bradford CAT adapting FROM the target white TO the neutral white: an
  // image lit by the (bluer) target renders neutral, so a neutral input
  // comes out warmer — matching "raising the target neutral temperature
  // warms the image" in the macOS renderer.
  const Vec3 cone_src = Mul(kBradford, target_wp);
  const Vec3 cone_dst = Mul(kBradford, neutral_wp);
  Mat3 scale{};
  scale[0][0] = cone_dst[0] / cone_src[0];
  scale[1][1] = cone_dst[1] / cone_src[1];
  scale[2][2] = cone_dst[2] / cone_src[2];

  const Mat3 cat = Mul(kBradfordInv, Mul(scale, kBradford));
  const Mat3 rgb = Mul(kRgbFromXyz, Mul(cat, kXyzFromRgb));
  return FromLinear(rgb);
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
