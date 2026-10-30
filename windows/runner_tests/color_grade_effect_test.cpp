// GPU parity for the colour grade: the REAL Direct2D effect chain
// (ColorGradeEffectChain, the one both the export and the preview draw
// through) against the CPU matrix math that ColorGradeGoldenTest pins to the
// macOS goldens (worst |diff| 0.0017 against Core Image).
//
// The golden test only proves the matrix. This proves Direct2D applies it the
// same way: its sRGB → scRGB linearisation, the 5x4 ColorMatrix in FP16, and
// the re-encode. Together they make the Windows grade match macOS end to end,
// which is what the CI exclusion of ColorGradeGoldenTest was waiting for.
//
// Inputs are 8-bit, as the decoded video is; the target is FP16 so the
// comparison is not dominated by output quantisation. Both sides are clamped
// to [0, 1], as the 8-bit export and preview surfaces clamp them.

#include "Graphics/color_grade_effect.h"

#include <d2d1_1.h>
#include <d3d11.h>
#include <wrl/client.h>

#include <gtest/gtest.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

#include "Capture/Export/color_grade.h"
#include "Graphics/d3d_device.h"

namespace clingfy::graphics {
namespace {

using capture::export_::color::BuildColorMatrix;
using capture::export_::color::ColorGrade;
using capture::export_::color::LinearToSrgb;
using capture::export_::color::SrgbToLinear;
using Microsoft::WRL::ComPtr;

float HalfToFloat(std::uint16_t h) {
  const std::uint32_t sign = (h & 0x8000u) << 16;
  const std::uint32_t exp = (h >> 10) & 0x1Fu;
  const std::uint32_t mant = h & 0x3FFu;
  float value;
  if (exp == 0) {
    value = std::ldexp(static_cast<float>(mant), -24);
  } else if (exp == 31) {
    value = mant == 0 ? INFINITY : NAN;
  } else {
    value = std::ldexp(static_cast<float>(mant | 0x400u),
                       static_cast<int>(exp) - 25);
  }
  return sign ? -value : value;
}

double Clamp01(double v) { return std::min(1.0, std::max(0.0, v)); }

struct Gpu {
  D3DDevice device;
  ComPtr<ID2D1Factory1> factory;
  ComPtr<ID2D1Device> d2d_device;
  ComPtr<ID2D1DeviceContext> ctx;

  std::string Create() {
    if (device.Create()) return "no usable D3D11 device";
    if (FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,
                                 __uuidof(ID2D1Factory1), nullptr,
                                 reinterpret_cast<void**>(
                                     factory.GetAddressOf())))) {
      return "D2D1CreateFactory failed";
    }
    ComPtr<IDXGIDevice> dxgi;
    if (FAILED(device.device()->QueryInterface(IID_PPV_ARGS(&dxgi)))) {
      return "no IDXGIDevice";
    }
    if (FAILED(factory->CreateDevice(dxgi.Get(), &d2d_device)) ||
        FAILED(d2d_device->CreateDeviceContext(
            D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &ctx))) {
      return "D2D device context creation failed";
    }
    return "";
  }
};

// The 8-bit sRGB levels each channel is sampled at: 6^3 = 216 colours,
// covering black, white, the primaries, secondaries and greys.
constexpr int kLevels[] = {0, 32, 80, 128, 192, 255};

std::vector<std::uint32_t> InputColors() {
  std::vector<std::uint32_t> colors;
  for (int r : kLevels) {
    for (int g : kLevels) {
      for (int b : kLevels) {
        colors.push_back(0xFF000000u | (static_cast<std::uint32_t>(r) << 16) |
                         (static_cast<std::uint32_t>(g) << 8) |
                         static_cast<std::uint32_t>(b));
      }
    }
  }
  return colors;
}

// Grade `colors` (BGRA-in-uint32, opaque) through the real chain and return
// RGB triples read back from an FP16 target. Empty on any D2D failure.
std::vector<double> GradeOnGpu(Gpu& gpu, const ColorGrade& grade,
                               const std::vector<std::uint32_t>& colors) {
  const UINT n = static_cast<UINT>(colors.size());
  ComPtr<ID2D1Bitmap1> input;
  if (FAILED(gpu.ctx->CreateBitmap(
          D2D1::SizeU(n, 1), colors.data(), n * 4u,
          D2D1::BitmapProperties1(
              D2D1_BITMAP_OPTIONS_NONE,
              D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                                D2D1_ALPHA_MODE_PREMULTIPLIED)),
          &input))) {
    return {};
  }
  const D2D1_PIXEL_FORMAT fp16 = D2D1::PixelFormat(
      DXGI_FORMAT_R16G16B16A16_FLOAT, D2D1_ALPHA_MODE_PREMULTIPLIED);
  ComPtr<ID2D1Bitmap1> target;
  ComPtr<ID2D1Bitmap1> readback;
  if (FAILED(gpu.ctx->CreateBitmap(
          D2D1::SizeU(n, 1), nullptr, 0,
          D2D1::BitmapProperties1(D2D1_BITMAP_OPTIONS_TARGET, fp16),
          &target)) ||
      FAILED(gpu.ctx->CreateBitmap(
          D2D1::SizeU(n, 1), nullptr, 0,
          D2D1::BitmapProperties1(
              D2D1_BITMAP_OPTIONS_CPU_READ | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
              fp16),
          &readback))) {
    return {};
  }

  ColorGradeEffectChain chain;
  if (FAILED(chain.Build(gpu.ctx.Get(), grade))) {
    return {};
  }
  chain.SetInput(input.Get());
  gpu.ctx->SetTarget(target.Get());
  gpu.ctx->BeginDraw();
  gpu.ctx->Clear(D2D1::ColorF(0, 0, 0, 0));
  gpu.ctx->DrawImage(chain.Output());
  const HRESULT hr = gpu.ctx->EndDraw();
  gpu.ctx->SetTarget(nullptr);
  if (FAILED(hr) || FAILED(readback->CopyFromBitmap(nullptr, target.Get(),
                                                    nullptr))) {
    return {};
  }
  D2D1_MAPPED_RECT mapped{};
  if (FAILED(readback->Map(D2D1_MAP_OPTIONS_READ, &mapped))) {
    return {};
  }
  std::vector<double> rgb;
  const auto* px = reinterpret_cast<const std::uint16_t*>(mapped.bits);
  for (UINT i = 0; i < n; ++i) {
    rgb.push_back(HalfToFloat(px[i * 4 + 0]));
    rgb.push_back(HalfToFloat(px[i * 4 + 1]));
    rgb.push_back(HalfToFloat(px[i * 4 + 2]));
  }
  readback->Unmap();
  return rgb;
}

ColorGrade Grade(double e, double c, double s, double t, double n) {
  ColorGrade g;
  g.exposure = e;
  g.contrast = c;
  g.saturation = s;
  g.temperature = t;
  g.tint = n;
  return g;
}

TEST(ColorGradeEffectGpuTest, TheDirect2DChainMatchesTheGoldenPinnedMatrix) {
  Gpu gpu;
  const std::string err = gpu.Create();
  if (!err.empty()) {
    GTEST_SKIP() << err;
  }
  const std::vector<std::uint32_t> colors = InputColors();
  // Every axis alone at both ends and half way, plus the composites the CI
  // note called out (e=c=s=t=n=1 was the worst case before #275).
  std::vector<ColorGrade> grades;
  for (const double v : {-1.0, -0.5, 0.5, 1.0}) {
    grades.push_back(Grade(v, 0, 0, 0, 0));
    grades.push_back(Grade(0, v, 0, 0, 0));
    grades.push_back(Grade(0, 0, v, 0, 0));
    grades.push_back(Grade(0, 0, 0, v, 0));
    grades.push_back(Grade(0, 0, 0, 0, v));
    grades.push_back(Grade(v, v, v, v, v));
  }
  grades.push_back(Grade(0.5, -0.5, 1.0, -1.0, 0.25));

  // One 8-bit step. The FP16 chain itself is far tighter (see the printed
  // worst), so this only absorbs D2D's own sRGB-curve evaluation.
  constexpr double kTolerance = 1.0 / 255.0;
  double worst = 0.0;
  for (const ColorGrade& grade : grades) {
    const std::vector<double> gpu_rgb = GradeOnGpu(gpu, grade, colors);
    ASSERT_EQ(gpu_rgb.size(), colors.size() * 3) << "D2D chain failed";
    const auto matrix = BuildColorMatrix(grade);
    for (std::size_t i = 0; i < colors.size(); ++i) {
      const double in[3] = {((colors[i] >> 16) & 0xFF) / 255.0,
                            ((colors[i] >> 8) & 0xFF) / 255.0,
                            (colors[i] & 0xFF) / 255.0};
      const auto lin = matrix.Apply(SrgbToLinear(in[0]), SrgbToLinear(in[1]),
                                    SrgbToLinear(in[2]));
      for (int ch = 0; ch < 3; ++ch) {
        const double expect = Clamp01(LinearToSrgb(lin[ch]));
        const double got = Clamp01(gpu_rgb[i * 3 + ch]);
        worst = std::max(worst, std::abs(got - expect));
        EXPECT_NEAR(got, expect, kTolerance)
            << "grade{e=" << grade.exposure << ",c=" << grade.contrast
            << ",s=" << grade.saturation << ",t=" << grade.temperature
            << ",n=" << grade.tint << "} sRGB(" << in[0] << "," << in[1]
            << "," << in[2] << ") ch" << ch;
      }
    }
  }
  std::cout << "[gpu] worst |D2D - matrix| = " << worst << " over "
            << grades.size() * colors.size() * 3 << " channels\n";
}

}  // namespace
}  // namespace clingfy::graphics
