// Headless pixel tests for the camera bubble border stroke (DComp presenter
// flicker investigation).
//
// The on-screen probe (camera_dcomp_overlay_poc_test.cpp, BorderFlickerProbe)
// showed the geometry-stroked border (circle/roundedRect/squircle →
// DrawGeometry) absent at the bubble edge while the square border
// (DrawRectangle) is rock solid. These tests reproduce the painter's exact
// static draw path OFFSCREEN — no windows, no DComp, nothing on screen — to
// discriminate painter-level geometry-stroke faults from
// presentation/DWM-level ones:
//
//   1. painter squircle+shadow+border on a plain texture target (pure painter)
//   2. painter square control on the same target (DrawRectangle path)
//   3. painter squircle on a REAL premultiplied composition swapchain buffer,
//      30 frames with Present rotation (the presenter's exact target)
//   4. raw D2D: PushLayer(mask geometry) then DrawGeometry with the SAME
//      geometry object (the painter's reuse pattern) vs a fresh geometry
//
// Honors CLINGFY_REQUIRE_PIXEL_TESTS=1 (skips become failures on the
// known-good environment).

#include "Capture/Camera/camera_bubble_painter.h"
#include "Capture/Camera/camera_overlay_glow_renderer.h"

#include <d2d1_1.h>
#include <d2d1helper.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <wrl/client.h>

#include <gtest/gtest.h>

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace clingfy::capture {
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

#define SKIP_OR_FAIL(msg)                       \
  do {                                          \
    if (PixelTestsRequired()) {                 \
      FAIL() << "CANARY: " << (msg);            \
    } else {                                    \
      GTEST_SKIP() << (msg);                    \
    }                                           \
  } while (false)

// Matches the on-screen probe's config: 220px square bubble, 8px opaque red
// border, magenta 64x64 camera frame.
constexpr int kSide = 220;
constexpr UINT kCamSize = 64;
constexpr std::uint32_t kMagenta = 0xFFFF00FFu;

int Chan(std::uint32_t px, int shift) {
  return static_cast<int>((px >> shift) & 0xFFu);
}

bool LooksRed(std::uint32_t px) {
  const int r = Chan(px, 16), g = Chan(px, 8), b = Chan(px, 0);
  return r > 90 && r > 2 * g && r > 2 * b;
}

bool LooksMagenta(std::uint32_t px) {
  const int r = Chan(px, 16), g = Chan(px, 8), b = Chan(px, 0);
  return r > 150 && b > 150 && g < 80;
}

std::string DumpPx(std::uint32_t px) {
  return "(a=" + std::to_string(Chan(px, 24)) +
         " r=" + std::to_string(Chan(px, 16)) +
         " g=" + std::to_string(Chan(px, 8)) +
         " b=" + std::to_string(Chan(px, 0)) + ")";
}

// GPU rig mirroring CameraDcompOverlay::BuildGpuStack minus the window/DComp
// pieces: same device flags, same factory threading, same DPI, same swapchain
// desc when the swapchain target is requested.
struct HeadlessRig {
  ComPtr<ID3D11Device> d3d;
  ComPtr<ID3D11DeviceContext> d3d_ctx;
  ComPtr<ID2D1Factory1> factory;
  ComPtr<ID2D1Device> d2d_device;
  ComPtr<ID2D1DeviceContext> ctx;
  ComPtr<IDXGISwapChain1> swapchain;      // only when UseSwapchainTarget
  ComPtr<ID3D11Texture2D> plain_target;   // only when !UseSwapchainTarget
  ComPtr<ID2D1Bitmap1> target_bitmap;
  ComPtr<ID2D1Bitmap1> camera_bitmap;

  std::string Create(bool use_swapchain_target) {
    const UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    HRESULT hr = ::D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE,
                                     nullptr, flags, nullptr, 0,
                                     D3D11_SDK_VERSION, d3d.GetAddressOf(),
                                     nullptr, d3d_ctx.GetAddressOf());
    if (FAILED(hr)) {
      hr = ::D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, flags,
                               nullptr, 0, D3D11_SDK_VERSION,
                               d3d.GetAddressOf(), nullptr,
                               d3d_ctx.GetAddressOf());
    }
    if (FAILED(hr)) return "no usable D3D11 device";

    if (FAILED(::D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,
                                   __uuidof(ID2D1Factory1), nullptr,
                                   reinterpret_cast<void**>(
                                       factory.GetAddressOf())))) {
      return "D2D1CreateFactory failed";
    }
    ComPtr<IDXGIDevice> dxgi_device;
    if (FAILED(d3d.As(&dxgi_device))) return "no IDXGIDevice";
    if (FAILED(factory->CreateDevice(dxgi_device.Get(),
                                     d2d_device.GetAddressOf()))) {
      return "ID2D1Factory1::CreateDevice failed";
    }
    if (FAILED(d2d_device->CreateDeviceContext(
            D2D1_DEVICE_CONTEXT_OPTIONS_NONE, ctx.GetAddressOf()))) {
      return "CreateDeviceContext failed";
    }
    ctx->SetDpi(96.0f, 96.0f);  // presenter parity: 1 DIP == 1 physical px

    if (use_swapchain_target) {
      ComPtr<IDXGIAdapter> adapter;
      if (FAILED(dxgi_device->GetAdapter(adapter.GetAddressOf()))) {
        return "no adapter";
      }
      ComPtr<IDXGIFactory2> dxgi_factory;
      if (FAILED(adapter->GetParent(
              IID_PPV_ARGS(dxgi_factory.GetAddressOf())))) {
        return "no IDXGIFactory2";
      }
      // Byte-for-byte the presenter's swapchain desc. No window, no DComp
      // visual: composition swapchains are created windowless and display
      // nothing unless bound, so this stays silent.
      DXGI_SWAP_CHAIN_DESC1 desc{};
      desc.Width = kSide;
      desc.Height = kSide;
      desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
      desc.SampleDesc.Count = 1;
      desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
      desc.BufferCount = 2;
      desc.Scaling = DXGI_SCALING_STRETCH;
      desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
      desc.AlphaMode = DXGI_ALPHA_MODE_PREMULTIPLIED;
      if (FAILED(dxgi_factory->CreateSwapChainForComposition(
              d3d.Get(), &desc, nullptr, swapchain.GetAddressOf()))) {
        return "CreateSwapChainForComposition failed";
      }
      ComPtr<IDXGISurface> surface;
      if (FAILED(swapchain->GetBuffer(
              0, IID_PPV_ARGS(surface.GetAddressOf())))) {
        return "GetBuffer(0) failed";
      }
      const D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
          D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
          D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                            D2D1_ALPHA_MODE_PREMULTIPLIED),
          96.0f, 96.0f);
      if (FAILED(ctx->CreateBitmapFromDxgiSurface(
              surface.Get(), props, target_bitmap.GetAddressOf()))) {
        return "CreateBitmapFromDxgiSurface(swapchain) failed";
      }
    } else {
      D3D11_TEXTURE2D_DESC desc{};
      desc.Width = kSide;
      desc.Height = kSide;
      desc.MipLevels = 1;
      desc.ArraySize = 1;
      desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
      desc.SampleDesc.Count = 1;
      desc.Usage = D3D11_USAGE_DEFAULT;
      // SHADER_RESOURCE required: without CANNOT_DRAW, a D2D target bitmap
      // must also be drawable, which needs the SRV bind.
      desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
      if (FAILED(d3d->CreateTexture2D(&desc, nullptr,
                                      plain_target.GetAddressOf()))) {
        return "target CreateTexture2D failed";
      }
      ComPtr<IDXGISurface> surface;
      if (FAILED(plain_target.As(&surface))) return "target has no surface";
      const D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
          D2D1_BITMAP_OPTIONS_TARGET,
          D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                            D2D1_ALPHA_MODE_PREMULTIPLIED),
          96.0f, 96.0f);
      if (FAILED(ctx->CreateBitmapFromDxgiSurface(
              surface.Get(), props, target_bitmap.GetAddressOf()))) {
        return "CreateBitmapFromDxgiSurface(texture) failed";
      }
    }
    ctx->SetTarget(target_bitmap.Get());

    // Camera source bitmap exactly as the presenter builds it: BGRA,
    // ALPHA_MODE_IGNORE, filled via CopyFromMemory.
    const D2D1_BITMAP_PROPERTIES1 cam_props = D2D1::BitmapProperties1(
        D2D1_BITMAP_OPTIONS_NONE,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                          D2D1_ALPHA_MODE_IGNORE));
    if (FAILED(ctx->CreateBitmap(D2D1::SizeU(kCamSize, kCamSize), nullptr, 0,
                                 cam_props, camera_bitmap.GetAddressOf()))) {
      return "camera CreateBitmap failed";
    }
    std::vector<std::uint32_t> cam(static_cast<size_t>(kCamSize) * kCamSize,
                                   kMagenta);
    if (FAILED(camera_bitmap->CopyFromMemory(nullptr, cam.data(),
                                             kCamSize * 4u))) {
      return "camera CopyFromMemory failed";
    }
    return "";
  }

  // Reads the CURRENT drawable buffer back through a staging texture. For the
  // swapchain rig call this BEFORE Present so it samples exactly the frame
  // about to be shown.
  bool ReadTarget(std::vector<std::uint32_t>* out) {
    ComPtr<ID3D11Texture2D> src = plain_target;
    if (src == nullptr && swapchain != nullptr) {
      if (FAILED(swapchain->GetBuffer(0, IID_PPV_ARGS(src.GetAddressOf())))) {
        return false;
      }
    }
    if (src == nullptr) return false;
    D3D11_TEXTURE2D_DESC desc{};
    desc.Width = kSide;
    desc.Height = kSide;
    desc.MipLevels = 1;
    desc.ArraySize = 1;
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.Usage = D3D11_USAGE_STAGING;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ComPtr<ID3D11Texture2D> staging;
    if (FAILED(d3d->CreateTexture2D(&desc, nullptr, &staging))) return false;
    d3d_ctx->CopyResource(staging.Get(), src.Get());
    D3D11_MAPPED_SUBRESOURCE mapped{};
    if (FAILED(d3d_ctx->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped))) {
      return false;
    }
    out->resize(static_cast<size_t>(kSide) * kSide);
    for (int row = 0; row < kSide; ++row) {
      std::memcpy(out->data() + static_cast<size_t>(row) * kSide,
                  static_cast<const std::uint8_t*>(mapped.pData) +
                      static_cast<size_t>(row) * mapped.RowPitch,
                  static_cast<size_t>(kSide) * 4u);
    }
    d3d_ctx->Unmap(staging.Get(), 0);
    return true;
  }
};

std::uint32_t At(const std::vector<std::uint32_t>& px, int x, int y) {
  return px[static_cast<size_t>(y) * kSide + x];
}

// The probe's failing style: squircle (roundness 0 → painter forces 0.3),
// medium shadow, 8px opaque red border — or the square control.
CameraBubblePainter::Style ProbeStyle() {
  CameraBubblePainter::Style style;
  style.opacity = 1.0;
  style.border_width = 8.0;
  style.has_border_color = true;
  style.border_argb = 0xFFFF0000u;
  style.shadow_preset = 2;
  return style;
}

bool PreparePainter(HeadlessRig& rig, CameraBubblePainter& painter,
                    const std::string& shape) {
  CameraBubbleRect bubble;
  bubble.x = 0.0;
  bubble.y = 0.0;
  bubble.width = static_cast<double>(kSide);
  bubble.height = static_cast<double>(kSide);
  const bool ok =
      painter.Prepare(rig.factory.Get(), rig.ctx.Get(), bubble, shape,
                      /*corner_radius=*/0.0, "fill", ProbeStyle(), kCamSize,
                      kCamSize);
  // Prepare's shadow bake leaves the target null (presenter contract).
  rig.ctx->SetTarget(rig.target_bitmap.Get());
  return ok;
}

bool RenderOneFrame(HeadlessRig& rig, CameraBubblePainter& painter,
                    HRESULT* end_draw_hr) {
  rig.ctx->BeginDraw();
  rig.ctx->Clear(D2D1::ColorF(0.0f, 0.0f, 0.0f, 0.0f));
  painter.Draw(rig.ctx.Get(), rig.camera_bitmap.Get(),
               CameraBubblePainter::Frame{});
  const HRESULT hr = rig.ctx->EndDraw();
  if (end_draw_hr != nullptr) *end_draw_hr = hr;
  rig.d3d_ctx->Flush();
  return SUCCEEDED(hr);
}

// Raw-value dump of the border zone so a failure carries the evidence: the
// left-edge stroke run at mid-height, the top-edge run at mid-width, and the
// corner-arc point (fully inside the target — immune to edge clipping).
std::string DumpBorderZone(const std::vector<std::uint32_t>& px) {
  std::string s = "mid-left y=" + std::to_string(kSide / 2) + ":";
  for (int x = 0; x < 14; ++x) s += " x" + std::to_string(x) + DumpPx(At(px, x, kSide / 2));
  s += "\nmid-top x=" + std::to_string(kSide / 2) + ":";
  for (int y = 0; y < 14; ++y) s += " y" + std::to_string(y) + DumpPx(At(px, kSide / 2, y));
  // Squircle corner arc: radius 0.3*side = 66 centered (66,66); 45° outline
  // point ≈ (19.3, 19.3).
  s += "\ncorner45:";
  for (int d = 14; d <= 26; d += 2) s += " d" + std::to_string(d) + DumpPx(At(px, d, d));
  return s;
}

// Is the stroke present on the straight left edge (visible half: x in [0,4))
// and, for the squircle, on the corner arc?
bool StrokeOnLeftEdge(const std::vector<std::uint32_t>& px) {
  for (int x = 0; x < 4; ++x) {
    if (LooksRed(At(px, x, kSide / 2))) return true;
  }
  return false;
}

bool StrokeOnCornerArc(const std::vector<std::uint32_t>& px) {
  // Sample along the 45° diagonal through the arc (stroke spans ~[16.4, 22.1]
  // on the diagonal for radius 66, width 8).
  for (int d = 14; d <= 26; ++d) {
    if (LooksRed(At(px, d, d))) return true;
  }
  return false;
}

TEST(CameraBubbleBorderPixelTest, SquircleBorderRendersOnPlainTarget) {
  HeadlessRig rig;
  const std::string err = rig.Create(/*use_swapchain_target=*/false);
  if (!err.empty()) SKIP_OR_FAIL(err);

  CameraBubblePainter painter;
  ASSERT_TRUE(PreparePainter(rig, painter, "squircle"));

  HRESULT hr = S_OK;
  ASSERT_TRUE(RenderOneFrame(rig, painter, &hr))
      << "EndDraw hr=0x" << std::hex << hr;
  std::vector<std::uint32_t> px;
  ASSERT_TRUE(rig.ReadTarget(&px));

  EXPECT_TRUE(LooksMagenta(At(px, kSide / 2, kSide / 2)))
      << "camera content missing: " << DumpPx(At(px, kSide / 2, kSide / 2));
  EXPECT_TRUE(StrokeOnLeftEdge(px))
      << "squircle border missing on the straight left edge\n"
      << DumpBorderZone(px);
  EXPECT_TRUE(StrokeOnCornerArc(px))
      << "squircle border missing on the corner arc\n" << DumpBorderZone(px);
}

TEST(CameraBubbleBorderPixelTest, SquareBorderRendersOnPlainTarget) {
  HeadlessRig rig;
  const std::string err = rig.Create(/*use_swapchain_target=*/false);
  if (!err.empty()) SKIP_OR_FAIL(err);

  CameraBubblePainter painter;
  ASSERT_TRUE(PreparePainter(rig, painter, "square"));

  HRESULT hr = S_OK;
  ASSERT_TRUE(RenderOneFrame(rig, painter, &hr))
      << "EndDraw hr=0x" << std::hex << hr;
  std::vector<std::uint32_t> px;
  ASSERT_TRUE(rig.ReadTarget(&px));

  EXPECT_TRUE(LooksMagenta(At(px, kSide / 2, kSide / 2)))
      << "camera content missing: " << DumpPx(At(px, kSide / 2, kSide / 2));
  EXPECT_TRUE(StrokeOnLeftEdge(px))
      << "square border missing on the left edge\n" << DumpBorderZone(px);
}

TEST(CameraBubbleBorderPixelTest,
     SquircleBorderStableAcrossSwapchainPresents) {
  HeadlessRig rig;
  const std::string err = rig.Create(/*use_swapchain_target=*/true);
  if (!err.empty()) SKIP_OR_FAIL(err);

  CameraBubblePainter painter;
  ASSERT_TRUE(PreparePainter(rig, painter, "squircle"));

  int edge_misses = 0;
  int arc_misses = 0;
  int cam_misses = 0;
  std::string first_miss;
  constexpr int kFrames = 30;
  for (int i = 0; i < kFrames; ++i) {
    HRESULT hr = S_OK;
    ASSERT_TRUE(RenderOneFrame(rig, painter, &hr))
        << "frame " << i << " EndDraw hr=0x" << std::hex << hr;
    std::vector<std::uint32_t> px;
    ASSERT_TRUE(rig.ReadTarget(&px)) << "frame " << i;
    const bool edge = StrokeOnLeftEdge(px);
    const bool arc = StrokeOnCornerArc(px);
    const bool cam = LooksMagenta(At(px, kSide / 2, kSide / 2));
    if (!edge) ++edge_misses;
    if (!arc) ++arc_misses;
    if (!cam) ++cam_misses;
    if ((!edge || !arc || !cam) && first_miss.empty()) {
      first_miss = "frame " + std::to_string(i) + ":\n" + DumpBorderZone(px);
    }
    // Present AFTER the readback — the readback samples exactly the frame
    // being handed to composition; Present rotates the flip-model buffers so
    // frame i+1 exercises the other physical buffer through the wrap-once
    // D2D binding, the presenter's per-tick reality.
    const HRESULT present_hr = rig.swapchain->Present(0, 0);
    ASSERT_TRUE(SUCCEEDED(present_hr))
        << "frame " << i << " Present hr=0x" << std::hex << present_hr;
  }
  EXPECT_EQ(edge_misses, 0) << "border missing on the straight edge in "
                            << edge_misses << "/" << kFrames << " frames\n"
                            << first_miss;
  EXPECT_EQ(arc_misses, 0) << "border missing on the corner arc in "
                           << arc_misses << "/" << kFrames << " frames\n"
                           << first_miss;
  EXPECT_EQ(cam_misses, 0) << "camera content missing in " << cam_misses
                           << "/" << kFrames << " frames\n" << first_miss;
}

// Renderer redesign P4a: the DComp presenter offsets the content square into a
// padded window so the baked shadow lands in the halo instead of being clipped
// at the swapchain edge. This pins the painter half of that contract: given a
// bubble at (pad, pad, pad+side, pad+side) inside a larger target, shadow
// pixels MUST appear below the content (the preset's +y offset) and the far
// halo corner stays transparent.
TEST(CameraBubbleBorderPixelTest, ShadowRendersIntoEffectPaddingHalo) {
  HeadlessRig rig;
  const std::string err = rig.Create(/*use_swapchain_target=*/false);
  if (!err.empty()) SKIP_OR_FAIL(err);

  constexpr int kPad = 40;
  constexpr int kContent = kSide - 2 * kPad;  // 140
  CameraBubblePainter::Style style;
  style.opacity = 1.0;
  style.shadow_preset = 2;  // blur 16 -> bake extent ~30 px < kPad
  CameraBubbleRect bubble;
  bubble.x = static_cast<double>(kPad);
  bubble.y = static_cast<double>(kPad);
  bubble.width = static_cast<double>(kContent);
  bubble.height = static_cast<double>(kContent);
  CameraBubblePainter painter;
  ASSERT_TRUE(painter.Prepare(rig.factory.Get(), rig.ctx.Get(), bubble,
                              "squircle", /*corner_radius=*/0.0, "fill", style,
                              kCamSize, kCamSize));
  rig.ctx->SetTarget(rig.target_bitmap.Get());

  HRESULT hr = S_OK;
  ASSERT_TRUE(RenderOneFrame(rig, painter, &hr))
      << "EndDraw hr=0x" << std::hex << hr;
  std::vector<std::uint32_t> px;
  ASSERT_TRUE(rig.ReadTarget(&px));

  EXPECT_TRUE(LooksMagenta(At(px, kSide / 2, kSide / 2)))
      << "camera content missing: " << DumpPx(At(px, kSide / 2, kSide / 2));

  // Shadow in the halo BELOW the content (preset 2 offsets +4 y): any sample
  // in the band just under the content edge must carry alpha.
  bool shadow_in_halo = false;
  std::string band;
  for (int y = kPad + kContent + 4; y <= kPad + kContent + 24; y += 4) {
    const std::uint32_t p = At(px, kSide / 2, y);
    band += " y" + std::to_string(y) + DumpPx(p);
    if (Chan(p, 24) > 10) shadow_in_halo = true;
  }
  EXPECT_TRUE(shadow_in_halo)
      << "no shadow alpha in the halo below the content —" << band;

  // The far top-left halo corner is ~38 px from the content, past the bake
  // extent: it must stay (near-)transparent, proving the halo isn't smeared.
  EXPECT_LT(Chan(At(px, 2, 2), 24), 10)
      << "unexpected coverage at the halo corner: " << DumpPx(At(px, 2, 2));
}

// Renderer redesign P4b: the glow bake (BakeCameraGlowBitmap) must produce a
// hollow red ring hugging the inside of the content outline with a blurred
// halo spilling into the effect padding — and must NOT tint the bubble
// interior (the camera stays clean; only the pulse opacity modulates the
// baked bitmap at draw time).
TEST(CameraBubbleBorderPixelTest, GlowBakeRendersRingAndHaloNotInterior) {
  HeadlessRig rig;
  const std::string err = rig.Create(/*use_swapchain_target=*/false);
  if (!err.empty()) SKIP_OR_FAIL(err);

  constexpr int kPad = 40;
  constexpr int kContent = kSide - 2 * kPad;  // 140
  // strength 1.0: lineWidth 10 (ring spans the 10 px inside the content
  // edge), halo radius 26 (blur stddev 13 -> visible well past the edge).
  const ComPtr<ID2D1Bitmap1> glow = clingfy::capture::BakeCameraGlowBitmap(
      rig.factory.Get(), rig.ctx.Get(), "squircle", /*corner_radius=*/0.0,
      kContent, kPad, /*strength=*/1.0);
  rig.ctx->SetTarget(rig.target_bitmap.Get());
  ASSERT_NE(glow, nullptr) << "glow bake soft-failed on a working device";

  rig.ctx->BeginDraw();
  rig.ctx->Clear(D2D1::ColorF(0.0f, 0.0f, 0.0f, 0.0f));
  rig.ctx->DrawBitmap(glow.Get(),
                      D2D1::RectF(0.0f, 0.0f, static_cast<float>(kSide),
                                  static_cast<float>(kSide)),
                      1.0f, D2D1_BITMAP_INTERPOLATION_MODE_LINEAR, nullptr);
  ASSERT_HRESULT_SUCCEEDED(rig.ctx->EndDraw());
  rig.d3d_ctx->Flush();
  std::vector<std::uint32_t> px;
  ASSERT_TRUE(rig.ReadTarget(&px));

  // Ring stroke: mid-height, centered lw/2=5 px inside the content edge —
  // systemRed (255,59,48) at full alpha.
  const std::uint32_t ring = At(px, kPad + 5, kSide / 2);
  EXPECT_TRUE(LooksRed(ring)) << "ring stroke missing: " << DumpPx(ring);

  // Halo: reddish alpha OUTSIDE the content, in the effect padding.
  const std::uint32_t halo = At(px, kPad - 12, kSide / 2);
  EXPECT_GT(Chan(halo, 24), 10) << "no halo in the padding: " << DumpPx(halo);

  // Interior: the bubble center must stay clean (the ring is hollow and the
  // blur has decayed) so the glow never tints the camera image.
  const std::uint32_t center = At(px, kSide / 2, kSide / 2);
  EXPECT_LT(Chan(center, 24), 10)
      << "glow tints the bubble interior: " << DumpPx(center);
}

// Pins that the parity table's stroke_alpha vs halo_alpha are applied to the
// RIGHT elements — at strength 1.0 they are 1.0 vs 0.90 and boolean predicates
// can't tell a swap apart. At strength 0.10 they are 0.64 (stroke) vs 0.342
// (halo), widely separated: the ring stroke's premultiplied red core reads
// ~163 correct but ~87 if the halo alpha were applied to it (below the LooksRed
// floor), and the halo stays well under the stroke.
TEST(CameraBubbleBorderPixelTest, GlowBakeAppliesStrokeAndHaloAlphasNotSwapped) {
  HeadlessRig rig;
  const std::string err = rig.Create(/*use_swapchain_target=*/false);
  if (!err.empty()) SKIP_OR_FAIL(err);

  constexpr int kPad = 40;
  constexpr int kContent = kSide - 2 * kPad;  // 140
  // strength 0.10: lineWidth 3.7, stroke alpha 0.64, halo radius 8 (stddev 4),
  // halo alpha 0.342.
  const ComPtr<ID2D1Bitmap1> glow = clingfy::capture::BakeCameraGlowBitmap(
      rig.factory.Get(), rig.ctx.Get(), "square", /*corner_radius=*/0.0,
      kContent, kPad, /*strength=*/0.10);
  rig.ctx->SetTarget(rig.target_bitmap.Get());
  ASSERT_NE(glow, nullptr) << "glow bake soft-failed on a working device";

  rig.ctx->BeginDraw();
  rig.ctx->Clear(D2D1::ColorF(0.0f, 0.0f, 0.0f, 0.0f));
  rig.ctx->DrawBitmap(glow.Get(),
                      D2D1::RectF(0.0f, 0.0f, static_cast<float>(kSide),
                                  static_cast<float>(kSide)),
                      1.0f, D2D1_BITMAP_INTERPOLATION_MODE_LINEAR, nullptr);
  ASSERT_HRESULT_SUCCEEDED(rig.ctx->EndDraw());
  rig.d3d_ctx->Flush();
  std::vector<std::uint32_t> px;
  ASSERT_TRUE(rig.ReadTarget(&px));

  // Stroke core: scan across the 3.7 px stroke band at the content's left edge
  // (square shape -> straight vertical stroke at mid-height) for its reddest
  // pixel. Correct stroke alpha 0.64 -> premultiplied r ~163; a swap to 0.342
  // -> ~87.
  int ring_r = 0;
  for (int x = kPad - 1; x <= kPad + 5; ++x) {
    ring_r = (std::max)(ring_r, Chan(At(px, x, kSide / 2), 16));
  }
  EXPECT_GT(ring_r, 120)
      << "ring stroke too dim for stroke_alpha 0.64 — halo alpha applied to "
         "the stroke? (r=" << ring_r << ")";
  EXPECT_LT(ring_r, 210)
      << "ring stroke brighter than stroke_alpha 0.64 allows (r=" << ring_r
      << ")";

  // Halo peak just outside the content: driven by halo_alpha 0.342 on the
  // blurred stroke, it must stay clearly below the stroke core.
  int halo_r = 0;
  for (int x = kPad - 8; x <= kPad - 3; ++x) {
    halo_r = (std::max)(halo_r, Chan(At(px, x, kSide / 2), 16));
  }
  EXPECT_LT(halo_r, ring_r - 20)
      << "halo is not dimmer than the stroke — alphas may be swapped (halo_r="
      << halo_r << " ring_r=" << ring_r << ")";
}

// The painter uses ONE ID2D1Geometry both as the PushLayer mask and as the
// DrawGeometry stroke source in the same frame. Geometries are immutable and
// this is documented-legal; this micro-case pins it independently of the
// painter so a driver/runtime quirk with the reuse pattern would show up
// here with no painter code in the loop.
TEST(CameraBubbleBorderPixelTest, MaskLayerThenStrokeSameGeometryObject) {
  HeadlessRig rig;
  const std::string err = rig.Create(/*use_swapchain_target=*/false);
  if (!err.empty()) SKIP_OR_FAIL(err);

  const D2D1_RECT_F rect =
      D2D1::RectF(0.0f, 0.0f, static_cast<float>(kSide),
                  static_cast<float>(kSide));
  ComPtr<ID2D1RoundedRectangleGeometry> rrect;
  ASSERT_HRESULT_SUCCEEDED(rig.factory->CreateRoundedRectangleGeometry(
      D2D1::RoundedRect(rect, 66.0f, 66.0f), rrect.GetAddressOf()));
  ComPtr<ID2D1Layer> layer;
  ASSERT_HRESULT_SUCCEEDED(rig.ctx->CreateLayer(nullptr,
                                                layer.GetAddressOf()));
  ComPtr<ID2D1SolidColorBrush> red;
  ASSERT_HRESULT_SUCCEEDED(rig.ctx->CreateSolidColorBrush(
      D2D1::ColorF(1.0f, 0.0f, 0.0f, 1.0f), red.GetAddressOf()));

  rig.ctx->BeginDraw();
  rig.ctx->Clear(D2D1::ColorF(0.0f, 0.0f, 0.0f, 0.0f));
  rig.ctx->PushLayer(
      D2D1::LayerParameters1(D2D1::InfiniteRect(), rrect.Get(),
                             D2D1_ANTIALIAS_MODE_PER_PRIMITIVE),
      layer.Get());
  rig.ctx->DrawBitmap(rig.camera_bitmap.Get(), rect, 1.0f,
                      D2D1_BITMAP_INTERPOLATION_MODE_LINEAR, nullptr);
  rig.ctx->PopLayer();
  rig.ctx->DrawGeometry(rrect.Get(), red.Get(), 8.0f);
  ASSERT_HRESULT_SUCCEEDED(rig.ctx->EndDraw());
  rig.d3d_ctx->Flush();

  std::vector<std::uint32_t> px;
  ASSERT_TRUE(rig.ReadTarget(&px));
  EXPECT_TRUE(StrokeOnLeftEdge(px))
      << "same-object stroke missing on the straight edge\n"
      << DumpBorderZone(px);
  EXPECT_TRUE(StrokeOnCornerArc(px))
      << "same-object stroke missing on the corner arc\n"
      << DumpBorderZone(px);
}

}  // namespace
}  // namespace clingfy::capture
