// Headless pixel tests for the preview color grade (editing port, PR-2b).
//
// PreviewCompositor::ComposeFrame takes an injected ID2D1DeviceContext, so
// the riskiest PR-2b code — the D2D effect chain + the transform'd DrawImage
// replacing the video DrawBitmap — is testable without a MediaPlayer or a
// window: build a headless D3D/D2D device, fill the compositor's video
// texture with a known color, compose onto an offscreen target, read the
// pixels back. Mirrors the export pipeline's pixel-test approach; honors
// CLINGFY_REQUIRE_PIXEL_TESTS=1 (skips become failures on the known-good
// environment).

#include "preview/preview_compositor.h"

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

#include "Graphics/d3d_device.h"

namespace clingfy::preview {
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

// Skip on unsupported environments — unless the environment promises pixel
// support, in which case a silent skip would erase the coverage while
// reading green (the export canary rationale).
#define SKIP_OR_FAIL(msg)                       \
  do {                                          \
    if (PixelTestsRequired()) {                 \
      FAIL() << "CANARY: " << (msg);            \
    } else {                                    \
      GTEST_SKIP() << (msg);                    \
    }                                           \
  } while (false)

struct HeadlessD2D {
  clingfy::graphics::D3DDevice device;
  ComPtr<ID2D1Factory1> factory;
  ComPtr<ID2D1Device> d2d_device;
  ComPtr<ID2D1DeviceContext> ctx;
  ComPtr<ID3D11Texture2D> target_texture;
  ComPtr<ID2D1Bitmap1> target_bitmap;

  // Returns an error string, or empty on success.
  std::string Create(UINT target_w, UINT target_h) {
    // The WinRT surface interop inside EnsureResources needs COM initialized.
    // RO_INIT_MULTITHREADED matches the frame-server threading; an already-
    // initialized apartment (RPC_E_CHANGED_MODE) is fine too.
    const HRESULT ro = RoInitialize(RO_INIT_MULTITHREADED);
    (void)ro;

    if (device.Create()) return "no usable D3D11 device";
    if (FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_MULTI_THREADED,
                                 __uuidof(ID2D1Factory1), nullptr,
                                 reinterpret_cast<void**>(
                                     factory.GetAddressOf())))) {
      return "D2D1CreateFactory failed";
    }
    ComPtr<IDXGIDevice> dxgi;
    if (FAILED(device.device()->QueryInterface(
            IID_PPV_ARGS(dxgi.GetAddressOf())))) {
      return "no IDXGIDevice";
    }
    if (FAILED(factory->CreateDevice(dxgi.Get(), &d2d_device))) {
      return "ID2D1Factory1::CreateDevice failed";
    }
    if (FAILED(d2d_device->CreateDeviceContext(
            D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &ctx))) {
      return "CreateDeviceContext failed";
    }

    D3D11_TEXTURE2D_DESC desc{};
    desc.Width = target_w;
    desc.Height = target_h;
    desc.MipLevels = 1;
    desc.ArraySize = 1;
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.Usage = D3D11_USAGE_DEFAULT;
    desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    if (FAILED(device.device()->CreateTexture2D(&desc, nullptr,
                                                &target_texture))) {
      return "target CreateTexture2D failed";
    }
    ComPtr<IDXGISurface> surface;
    if (FAILED(target_texture.As(&surface))) return "target has no surface";
    const D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
        D2D1_BITMAP_OPTIONS_TARGET,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                          D2D1_ALPHA_MODE_PREMULTIPLIED));
    if (FAILED(ctx->CreateBitmapFromDxgiSurface(surface.Get(), &props,
                                                &target_bitmap))) {
      return "CreateBitmapFromDxgiSurface failed";
    }
    ctx->SetTarget(target_bitmap.Get());
    return "";
  }

  // Fills a texture with a solid BGRA color via UpdateSubresource.
  void FillTexture(ID3D11Texture2D* texture, UINT w, UINT h,
                   std::uint32_t bgra) {
    std::vector<std::uint32_t> pixels(static_cast<size_t>(w) * h, bgra);
    device.context()->UpdateSubresource(texture, 0, nullptr, pixels.data(),
                                        w * 4u, 0);
  }

  // Reads the target back through a staging texture.
  bool ReadTarget(UINT w, UINT h, std::vector<std::uint32_t>* out) {
    D3D11_TEXTURE2D_DESC desc{};
    desc.Width = w;
    desc.Height = h;
    desc.MipLevels = 1;
    desc.ArraySize = 1;
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.Usage = D3D11_USAGE_STAGING;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ComPtr<ID3D11Texture2D> staging;
    if (FAILED(device.device()->CreateTexture2D(&desc, nullptr, &staging))) {
      return false;
    }
    device.context()->CopyResource(staging.Get(), target_texture.Get());
    D3D11_MAPPED_SUBRESOURCE mapped{};
    if (FAILED(device.context()->Map(staging.Get(), 0, D3D11_MAP_READ, 0,
                                     &mapped))) {
      return false;
    }
    out->resize(static_cast<size_t>(w) * h);
    for (UINT row = 0; row < h; ++row) {
      std::memcpy(out->data() + static_cast<size_t>(row) * w,
                  static_cast<const std::uint8_t*>(mapped.pData) +
                      static_cast<size_t>(row) * mapped.RowPitch,
                  static_cast<size_t>(w) * 4u);
    }
    device.context()->Unmap(staging.Get(), 0);
    return true;
  }
};

constexpr UINT kTargetSize = 128;
constexpr UINT kVideoSize = 64;
// BGRA-in-uint32 reads as 0xAARRGGBB.
constexpr std::uint32_t kOpaqueRed = 0xFFFF0000u;

int Chan(std::uint32_t px, int shift) {
  return static_cast<int>((px >> shift) & 0xFFu);
}

// Composes one frame (no cursor events → no zoom, no halo) and returns the
// target center pixel.
bool ComposeAndSample(HeadlessD2D& gpu, PreviewCompositor& compositor,
                      std::uint32_t* center) {
  ZoomState zoom;
  gpu.ctx->BeginDraw();
  compositor.ComposeFrame(
      gpu.ctx.Get(),
      D2D1::RectF(0.0f, 0.0f, static_cast<float>(kTargetSize),
                  static_cast<float>(kTargetSize)),
      {}, {}, /*playback_us=*/0, /*now_seconds=*/0.0, zoom);
  if (FAILED(gpu.ctx->EndDraw())) return false;
  gpu.device.context()->Flush();
  std::vector<std::uint32_t> pixels;
  if (!gpu.ReadTarget(kTargetSize, kTargetSize, &pixels)) return false;
  *center = pixels[(kTargetSize / 2) * kTargetSize + (kTargetSize / 2)];
  return true;
}

TEST(PreviewCompositorColorTest, SaturationGradeDesaturatesLivePreview) {
  HeadlessD2D gpu;
  const std::string err = gpu.Create(kTargetSize, kTargetSize);
  if (!err.empty()) SKIP_OR_FAIL(err);

  PreviewCompositor compositor;
  if (FAILED(compositor.EnsureResources(gpu.device.device(), gpu.ctx.Get(),
                                        kVideoSize, kVideoSize))) {
    SKIP_OR_FAIL("PreviewCompositor::EnsureResources failed headless");
  }
  gpu.FillTexture(compositor.video_texture(), kVideoSize, kVideoSize,
                  kOpaqueRed);

  capture::export_::color::ColorGrade grade;
  grade.saturation = -1.0;
  compositor.SetColorGrade(grade);

  std::uint32_t center = 0;
  ASSERT_TRUE(ComposeAndSample(gpu, compositor, &center));
  const int r = Chan(center, 16);
  const int g = Chan(center, 8);
  const int b = Chan(center, 0);
  // Pure red fully desaturated (Rec.709 luma in linear space) lands near
  // 127 gray after re-encode. 12/255 absorbs effect + 8-bit rounding.
  EXPECT_LT(std::abs(r - g), 12) << "expected gray, got r=" << r
                                 << " g=" << g << " b=" << b;
  EXPECT_LT(std::abs(g - b), 12) << "expected gray, got r=" << r
                                 << " g=" << g << " b=" << b;
  EXPECT_GT(r, 90) << "desaturated red should be mid-gray, not black";
  EXPECT_LT(r, 170) << "desaturated red should be mid-gray, not white";
}

TEST(PreviewCompositorColorTest, IdentityGradeLeavesVideoUntouched) {
  HeadlessD2D gpu;
  const std::string err = gpu.Create(kTargetSize, kTargetSize);
  if (!err.empty()) SKIP_OR_FAIL(err);

  PreviewCompositor compositor;
  if (FAILED(compositor.EnsureResources(gpu.device.device(), gpu.ctx.Get(),
                                        kVideoSize, kVideoSize))) {
    SKIP_OR_FAIL("PreviewCompositor::EnsureResources failed headless");
  }
  gpu.FillTexture(compositor.video_texture(), kVideoSize, kVideoSize,
                  kOpaqueRed);

  compositor.SetColorGrade(capture::export_::color::ColorGrade{});

  std::uint32_t center = 0;
  ASSERT_TRUE(ComposeAndSample(gpu, compositor, &center));
  EXPECT_GT(Chan(center, 16), 240) << "identity grade must not change red";
  EXPECT_LT(Chan(center, 8), 12);
  EXPECT_LT(Chan(center, 0), 12);
}

TEST(PreviewCompositorColorTest, GradeChangeUpdatesNextFrame) {
  // Slider-drag semantics: consecutive ComposeFrames with different grades
  // must each reflect the latest value (the chain rebuilds the matrix in
  // place on generation change).
  HeadlessD2D gpu;
  const std::string err = gpu.Create(kTargetSize, kTargetSize);
  if (!err.empty()) SKIP_OR_FAIL(err);

  PreviewCompositor compositor;
  if (FAILED(compositor.EnsureResources(gpu.device.device(), gpu.ctx.Get(),
                                        kVideoSize, kVideoSize))) {
    SKIP_OR_FAIL("PreviewCompositor::EnsureResources failed headless");
  }
  gpu.FillTexture(compositor.video_texture(), kVideoSize, kVideoSize,
                  kOpaqueRed);

  capture::export_::color::ColorGrade grade;
  grade.saturation = -1.0;
  compositor.SetColorGrade(grade);
  std::uint32_t desaturated = 0;
  ASSERT_TRUE(ComposeAndSample(gpu, compositor, &desaturated));
  EXPECT_LT(std::abs(Chan(desaturated, 16) - Chan(desaturated, 0)), 12);

  // Back to identity: the next frame must be red again (no stale matrix).
  compositor.SetColorGrade(capture::export_::color::ColorGrade{});
  std::uint32_t restored = 0;
  ASSERT_TRUE(ComposeAndSample(gpu, compositor, &restored));
  EXPECT_GT(Chan(restored, 16), 240);
  EXPECT_LT(Chan(restored, 0), 12);
}

}  // namespace
}  // namespace clingfy::preview
