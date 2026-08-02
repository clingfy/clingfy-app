#include "Capture/Background/canvas_preset_renderer.h"

#include <d2d1_1.h>
#include <d3d11.h>
#include <roapi.h>
#include <wrl/client.h>

#include <gtest/gtest.h>

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "Capture/Background/background_preset_catalog.h"
#include "Graphics/d3d_device.h"

namespace clingfy::capture::background {
namespace {

using Microsoft::WRL::ComPtr;

bool PixelTestsRequired() {
  char* required = nullptr;
  size_t len = 0;
  _dupenv_s(&required, &len, "CLINGFY_REQUIRE_PIXEL_TESTS");
  const bool require = required != nullptr && std::string(required) == "1";
  free(required);
  return require;
}

// Same canary discipline as preview_compositor_color_test: a silent skip on a
// machine that DOES support pixels would erase this coverage while reading
// green.
#define SKIP_OR_FAIL(msg)                       \
  do {                                          \
    if (PixelTestsRequired()) {                 \
      FAIL() << "CANARY: " << (msg);            \
    } else {                                    \
      GTEST_SKIP() << (msg);                    \
    }                                           \
  } while (false)

constexpr UINT kW = 160;
constexpr UINT kH = 90;

struct HeadlessD2D {
  clingfy::graphics::D3DDevice device;
  ComPtr<ID2D1Factory1> factory;
  ComPtr<ID2D1Device> d2d_device;
  ComPtr<ID2D1DeviceContext> ctx;

  std::string Create() {
    RoInitialize(RO_INIT_MULTITHREADED);
    if (device.Create()) return "no usable D3D11 device";
    if (FAILED(D2D1CreateFactory(
            D2D1_FACTORY_TYPE_MULTI_THREADED, __uuidof(ID2D1Factory1), nullptr,
            reinterpret_cast<void**>(factory.GetAddressOf())))) {
      return "D2D1CreateFactory failed";
    }
    ComPtr<IDXGIDevice> dxgi;
    if (FAILED(device.device()->QueryInterface(
            IID_PPV_ARGS(dxgi.GetAddressOf())))) {
      return "no IDXGIDevice";
    }
    if (FAILED(factory->CreateDevice(dxgi.Get(), &d2d_device))) {
      return "CreateDevice failed";
    }
    if (FAILED(d2d_device->CreateDeviceContext(
            D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &ctx))) {
      return "CreateDeviceContext failed";
    }
    return "";
  }

  // Copies a rendered D2D bitmap back to the CPU so the test can inspect pixels.
  bool ReadBack(ID2D1Bitmap1* src, UINT w, UINT h,
                std::vector<std::uint32_t>* out) {
    const D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
        D2D1_BITMAP_OPTIONS_CPU_READ | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                          D2D1_ALPHA_MODE_PREMULTIPLIED));
    ComPtr<ID2D1Bitmap1> readable;
    if (FAILED(ctx->CreateBitmap(D2D1::SizeU(w, h), nullptr, 0, &props,
                                 &readable))) {
      return false;
    }
    const D2D1_POINT_2U dest = D2D1::Point2U(0, 0);
    const D2D1_RECT_U rect = D2D1::RectU(0, 0, w, h);
    if (FAILED(readable->CopyFromBitmap(&dest, src, &rect))) return false;

    D2D1_MAPPED_RECT mapped{};
    if (FAILED(readable->Map(D2D1_MAP_OPTIONS_READ, &mapped))) return false;
    out->resize(static_cast<size_t>(w) * h);
    for (UINT row = 0; row < h; ++row) {
      std::memcpy(out->data() + static_cast<size_t>(row) * w,
                  mapped.bits + static_cast<size_t>(row) * mapped.pitch,
                  static_cast<size_t>(w) * 4u);
    }
    readable->Unmap();
    return true;
  }
};

int Chan(std::uint32_t px, int shift) {
  return static_cast<int>((px >> shift) & 0xFFu);
}
int A(std::uint32_t px) { return Chan(px, 24); }
int R(std::uint32_t px) { return Chan(px, 16); }
int G(std::uint32_t px) { return Chan(px, 8); }
int B(std::uint32_t px) { return Chan(px, 0); }

CanvasPresetSpec Spec(const char* palette = "bluePurple", double intensity = 0.6,
                      double blur = 0.0, std::int64_t seed = 7) {
  CanvasPresetSpec s;
  s.preset_id = "abstractWaves";
  s.palette_id = palette;
  s.intensity = intensity;
  s.blur = blur;
  s.seed = seed;
  return s;
}

// The renderer must actually paint: every pixel opaque, nothing left cleared.
// A transparent or empty result would show as a black canvas in the preview and
// look like "presets do not work" rather than a rendering bug.
TEST(AbstractWavesRendererTest, FillsTheWholeCanvasOpaquely) {
  HeadlessD2D gpu;
  const std::string err = gpu.Create();
  if (!err.empty()) SKIP_OR_FAIL(err);

  auto bitmap = RenderCanvasPreset(gpu.ctx.Get(), kW, kH, Spec());
  ASSERT_NE(bitmap, nullptr) << "renderer returned no bitmap";

  std::vector<std::uint32_t> px;
  ASSERT_TRUE(gpu.ReadBack(bitmap.Get(), kW, kH, &px));
  ASSERT_EQ(px.size(), static_cast<size_t>(kW) * kH);

  for (size_t i = 0; i < px.size(); ++i) {
    ASSERT_GE(A(px[i]), 250) << "transparent pixel at index " << i;
  }
}

// The base gradient runs dark -> light across the palette. Sampling the two
// gradient ends must differ, or the gradient collapsed to a flat fill.
TEST(AbstractWavesRendererTest, DrawsAGradientNotAFlatFill) {
  HeadlessD2D gpu;
  const std::string err = gpu.Create();
  if (!err.empty()) SKIP_OR_FAIL(err);

  auto bitmap = RenderCanvasPreset(gpu.ctx.Get(), kW, kH, Spec());
  ASSERT_NE(bitmap, nullptr);
  std::vector<std::uint32_t> px;
  ASSERT_TRUE(gpu.ReadBack(bitmap.Get(), kW, kH, &px));

  const std::uint32_t top_left = px[0];
  const std::uint32_t top_right = px[kW - 1];
  const int delta = std::abs(R(top_left) - R(top_right)) +
                    std::abs(G(top_left) - G(top_right)) +
                    std::abs(B(top_left) - B(top_right));
  EXPECT_GT(delta, 12) << "gradient ends are nearly identical — flat fill?";
}

// Same seed must produce identical pixels. This is what lets the result be
// cached and regenerated on demand instead of stored as source of truth.
TEST(AbstractWavesRendererTest, IsDeterministicForTheSameSeed) {
  HeadlessD2D gpu;
  const std::string err = gpu.Create();
  if (!err.empty()) SKIP_OR_FAIL(err);

  auto a = RenderCanvasPreset(gpu.ctx.Get(), kW, kH, Spec("aurora", 0.5, 0.0, 42));
  auto b = RenderCanvasPreset(gpu.ctx.Get(), kW, kH, Spec("aurora", 0.5, 0.0, 42));
  ASSERT_NE(a, nullptr);
  ASSERT_NE(b, nullptr);

  std::vector<std::uint32_t> pa, pb;
  ASSERT_TRUE(gpu.ReadBack(a.Get(), kW, kH, &pa));
  ASSERT_TRUE(gpu.ReadBack(b.Get(), kW, kH, &pb));
  EXPECT_EQ(pa, pb) << "identical specs must render identical pixels";
}

TEST(AbstractWavesRendererTest, DifferentSeedsProduceDifferentArt) {
  HeadlessD2D gpu;
  const std::string err = gpu.Create();
  if (!err.empty()) SKIP_OR_FAIL(err);

  auto a = RenderCanvasPreset(gpu.ctx.Get(), kW, kH, Spec("aurora", 0.5, 0.0, 1));
  auto b = RenderCanvasPreset(gpu.ctx.Get(), kW, kH, Spec("aurora", 0.5, 0.0, 2));
  ASSERT_NE(a, nullptr);
  ASSERT_NE(b, nullptr);

  std::vector<std::uint32_t> pa, pb;
  ASSERT_TRUE(gpu.ReadBack(a.Get(), kW, kH, &pa));
  ASSERT_TRUE(gpu.ReadBack(b.Get(), kW, kH, &pb));
  EXPECT_NE(pa, pb);
}

// Different palettes must actually change the colours, or the palette id is
// being ignored somewhere between the wire and the brush.
TEST(AbstractWavesRendererTest, PaletteChangesTheColours) {
  HeadlessD2D gpu;
  const std::string err = gpu.Create();
  if (!err.empty()) SKIP_OR_FAIL(err);

  auto blue = RenderCanvasPreset(gpu.ctx.Get(), kW, kH, Spec("bluePurple"));
  auto forest = RenderCanvasPreset(gpu.ctx.Get(), kW, kH, Spec("forest"));
  ASSERT_NE(blue, nullptr);
  ASSERT_NE(forest, nullptr);

  std::vector<std::uint32_t> pb, pf;
  ASSERT_TRUE(gpu.ReadBack(blue.Get(), kW, kH, &pb));
  ASSERT_TRUE(gpu.ReadBack(forest.Get(), kW, kH, &pf));
  EXPECT_NE(pb, pf);

  // bluePurple should read bluer than forest across the canvas; forest greener.
  long long blue_b = 0, forest_b = 0, blue_g = 0, forest_g = 0;
  for (size_t i = 0; i < pb.size(); ++i) {
    blue_b += B(pb[i]);
    forest_b += B(pf[i]);
    blue_g += G(pb[i]);
    forest_g += G(pf[i]);
  }
  EXPECT_GT(blue_b, forest_b) << "bluePurple must be bluer than forest";
  EXPECT_GT(forest_g, blue_g) << "forest must be greener than bluePurple";
}

// Blur must visibly soften. Measured as reduced local contrast between
// horizontally adjacent pixels — a blurred image has smaller neighbour deltas.
TEST(AbstractWavesRendererTest, BlurSoftensTheResult) {
  HeadlessD2D gpu;
  const std::string err = gpu.Create();
  if (!err.empty()) SKIP_OR_FAIL(err);

  auto sharp = RenderCanvasPreset(gpu.ctx.Get(), kW, kH, Spec("sunset", 0.9, 0.0, 5));
  auto soft = RenderCanvasPreset(gpu.ctx.Get(), kW, kH, Spec("sunset", 0.9, 1.0, 5));
  ASSERT_NE(sharp, nullptr);
  ASSERT_NE(soft, nullptr);

  std::vector<std::uint32_t> ps, pf;
  ASSERT_TRUE(gpu.ReadBack(sharp.Get(), kW, kH, &ps));
  ASSERT_TRUE(gpu.ReadBack(soft.Get(), kW, kH, &pf));

  auto contrast = [](const std::vector<std::uint32_t>& p) {
    long long total = 0;
    for (UINT y = 0; y < kH; ++y) {
      for (UINT x = 1; x < kW; ++x) {
        const size_t i = static_cast<size_t>(y) * kW + x;
        total += std::abs(R(p[i]) - R(p[i - 1]));
      }
    }
    return total;
  };
  EXPECT_LT(contrast(pf), contrast(ps))
      << "a blurred render must have lower local contrast than a sharp one";
}

// Degenerate sizes must return null rather than crash or hand back a zero-sized
// bitmap the compositor would then try to draw.
TEST(AbstractWavesRendererTest, DegenerateSizeReturnsNull) {
  HeadlessD2D gpu;
  const std::string err = gpu.Create();
  if (!err.empty()) SKIP_OR_FAIL(err);

  EXPECT_EQ(RenderCanvasPreset(gpu.ctx.Get(), 0, kH, Spec()), nullptr);
  EXPECT_EQ(RenderCanvasPreset(gpu.ctx.Get(), kW, 0, Spec()), nullptr);
  EXPECT_EQ(RenderCanvasPreset(nullptr, kW, kH, Spec()), nullptr);
}

// The caller's render target must survive: this renderer retargets the context
// internally, and leaking that would silently redirect the next frame the
// compositor draws.
TEST(AbstractWavesRendererTest, RestoresTheCallersRenderTarget) {
  HeadlessD2D gpu;
  const std::string err = gpu.Create();
  if (!err.empty()) SKIP_OR_FAIL(err);

  const D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
      D2D1_BITMAP_OPTIONS_TARGET,
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                        D2D1_ALPHA_MODE_PREMULTIPLIED));
  ComPtr<ID2D1Bitmap1> callers_target;
  ASSERT_EQ(gpu.ctx->CreateBitmap(D2D1::SizeU(32, 32), nullptr, 0, &props,
                                  &callers_target),
            S_OK);
  gpu.ctx->SetTarget(callers_target.Get());

  auto bitmap = RenderCanvasPreset(gpu.ctx.Get(), kW, kH, Spec());
  ASSERT_NE(bitmap, nullptr);

  ComPtr<ID2D1Image> after;
  gpu.ctx->GetTarget(&after);
  EXPECT_EQ(after.Get(), static_cast<ID2D1Image*>(callers_target.Get()))
      << "renderer left the context pointed at its own scratch bitmap";
}

// An unknown palette must fall back rather than render nothing — a project
// carrying a palette this build does not know still has to open.
TEST(AbstractWavesRendererTest, UnknownPaletteFallsBackToDefault) {
  HeadlessD2D gpu;
  const std::string err = gpu.Create();
  if (!err.empty()) SKIP_OR_FAIL(err);

  auto unknown =
      RenderCanvasPreset(gpu.ctx.Get(), kW, kH, Spec("no_such_palette"));
  auto fallback =
      RenderCanvasPreset(gpu.ctx.Get(), kW, kH, Spec(kDefaultPaletteId));
  ASSERT_NE(unknown, nullptr);
  ASSERT_NE(fallback, nullptr);

  std::vector<std::uint32_t> pu, pf;
  ASSERT_TRUE(gpu.ReadBack(unknown.Get(), kW, kH, &pu));
  ASSERT_TRUE(gpu.ReadBack(fallback.Get(), kW, kH, &pf));
  EXPECT_EQ(pu, pf);
}

// The cache key is what makes "bitmaps are caches" safe: it must change when
// anything that affects pixels changes, and stay stable when nothing does.
TEST(CanvasPresetCacheKeyTest, ChangesWithEveryPixelAffectingInput) {
  const auto base = Spec("aurora", 0.5, 0.2, 9);
  const std::string k = CanvasPresetCacheKey(base, 320, 180);

  EXPECT_EQ(k, CanvasPresetCacheKey(base, 320, 180)) << "must be stable";

  auto palette = base;  palette.palette_id = "sunset";
  auto intensity = base; intensity.intensity = 0.51;
  auto blur = base;      blur.blur = 0.21;
  auto seed = base;      seed.seed = 10;

  EXPECT_NE(k, CanvasPresetCacheKey(palette, 320, 180));
  EXPECT_NE(k, CanvasPresetCacheKey(intensity, 320, 180));
  EXPECT_NE(k, CanvasPresetCacheKey(blur, 320, 180));
  EXPECT_NE(k, CanvasPresetCacheKey(seed, 320, 180));
  EXPECT_NE(k, CanvasPresetCacheKey(base, 321, 180)) << "size must matter";
  EXPECT_NE(k, CanvasPresetCacheKey(base, 320, 181));
}

TEST(CanvasPresetCacheKeyTest, EmbedsTheRendererVersion) {
  const std::string k = CanvasPresetCacheKey(Spec(), 320, 180);
  EXPECT_NE(k.find("v" + std::to_string(kCanvasPresetRendererVersion)),
            std::string::npos)
      << "renderer version must be in the key so a renderer change invalidates "
         "every cached bitmap";
}


// ---------------------------------------------------------------------------
// Preset dispatch. THE regression these exist for: RenderCanvasPreset ignored
// spec.preset_id and always drew abstract waves, so picking "Graphic Mesh" or
// "Radial Glow" silently gave you waves — in the preview AND the export, while
// macOS rendered three distinct backgrounds.
// ---------------------------------------------------------------------------

CanvasPresetSpec SpecFor(const char* preset_id) {
  CanvasPresetSpec s = Spec();
  s.preset_id = preset_id;
  return s;
}

// Renders the preset and returns its pixels, or an empty vector on GPU trouble.
std::vector<std::uint32_t> RenderPixels(HeadlessD2D* gpu, const char* id) {
  auto bitmap = RenderCanvasPreset(gpu->ctx.Get(), kW, kH, SpecFor(id));
  std::vector<std::uint32_t> px;
  if (bitmap == nullptr) return px;
  if (!gpu->ReadBack(bitmap.Get(), kW, kH, &px)) px.clear();
  return px;
}

// Counts differing pixels, so "different" means visibly different rather than
// one stray blend-rounding pixel.
size_t DifferingPixels(const std::vector<std::uint32_t>& a,
                       const std::vector<std::uint32_t>& b) {
  size_t n = 0;
  for (size_t i = 0; i < a.size() && i < b.size(); ++i) {
    if (a[i] != b[i]) ++n;
  }
  return n;
}

TEST(CanvasPresetDispatchTest, EachPresetIdRendersADifferentBackground) {
  HeadlessD2D gpu;
  const std::string err = gpu.Create();
  if (!err.empty()) SKIP_OR_FAIL(err);

  const auto waves = RenderPixels(&gpu, "abstractWaves");
  const auto mesh = RenderPixels(&gpu, "graphicMesh");
  const auto glow = RenderPixels(&gpu, "radialGlow");
  ASSERT_FALSE(waves.empty());
  ASSERT_FALSE(mesh.empty());
  ASSERT_FALSE(glow.empty());

  // A tenth of the canvas is a low bar that a genuinely different composition
  // clears easily and an identical render cannot clear at all.
  const size_t threshold = (static_cast<size_t>(kW) * kH) / 10;
  EXPECT_GT(DifferingPixels(waves, mesh), threshold)
      << "graphicMesh renders as abstractWaves";
  EXPECT_GT(DifferingPixels(waves, glow), threshold)
      << "radialGlow renders as abstractWaves";
  EXPECT_GT(DifferingPixels(mesh, glow), threshold)
      << "graphicMesh and radialGlow render identically";
}

// Every preset must paint the full canvas. A transparent result reads as a
// black rectangle and looks like "presets are broken" rather than a bug in one.
TEST(CanvasPresetDispatchTest, EveryPresetFillsTheCanvasOpaquely) {
  HeadlessD2D gpu;
  const std::string err = gpu.Create();
  if (!err.empty()) SKIP_OR_FAIL(err);

  for (const char* id : {"abstractWaves", "graphicMesh", "radialGlow"}) {
    const auto px = RenderPixels(&gpu, id);
    ASSERT_FALSE(px.empty()) << id;
    for (size_t i = 0; i < px.size(); ++i) {
      ASSERT_GE(A(px[i]), 250) << id << " transparent at index " << i;
    }
  }
}

// An id from a newer build (or a typo) must still produce a background. macOS
// falls back to abstract waves; anything else would render an empty canvas for
// a project that opens fine on the other platform.
TEST(CanvasPresetDispatchTest, UnknownPresetIdFallsBackToAbstractWaves) {
  HeadlessD2D gpu;
  const std::string err = gpu.Create();
  if (!err.empty()) SKIP_OR_FAIL(err);

  const auto waves = RenderPixels(&gpu, "abstractWaves");
  const auto unknown = RenderPixels(&gpu, "notARealPreset");
  ASSERT_FALSE(waves.empty());
  ASSERT_FALSE(unknown.empty());
  EXPECT_EQ(DifferingPixels(waves, unknown), 0u);
}

// The cache key folds in the preset id, so switching preset must invalidate.
// Without this the first preset rendered would be shown for all three.
TEST(CanvasPresetDispatchTest, CacheKeyDistinguishesThePresets) {
  const std::string waves = CanvasPresetCacheKey(SpecFor("abstractWaves"), kW, kH);
  const std::string mesh = CanvasPresetCacheKey(SpecFor("graphicMesh"), kW, kH);
  const std::string glow = CanvasPresetCacheKey(SpecFor("radialGlow"), kW, kH);
  EXPECT_NE(waves, mesh);
  EXPECT_NE(waves, glow);
  EXPECT_NE(mesh, glow);
}

}  // namespace
}  // namespace clingfy::capture::background
