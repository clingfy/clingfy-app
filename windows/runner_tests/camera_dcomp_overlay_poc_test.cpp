// Renderer redesign P3 — the DirectComposition presenter's GO/NO-GO gate on
// this machine (docs/decisions/windows-camera-bubble-renderer-architecture.md).
//
// Three layers:
//  1. Pure geometry: ComputeSquareFloatingRect unit tests (always run).
//  2. Hidden lifecycle: the real presenter Starts (window + D3D + composition
//     swapchain + D2D + DComp all build) and Stops cleanly, without ever
//     becoming visible (always runs; skips only if the session can't create
//     windows).
//  3. On-screen probes (gated behind CLINGFY_REQUIRE_PIXEL_TESTS=1, the repo's
//     pixel-canary convention, because they briefly SHOW a window on the
//     desktop and read the screen):
//       a. RENDER: a presenter WITHOUT capture exclusion, fed a solid magenta
//          frame, must actually put magenta on screen (BitBlt sees it) — the
//          hybrid-GPU "alpha window renders nothing" scar is exactly what this
//          catches.
//       b. EXCLUSION: the default presenter (WDA applied) must be ABSENT from
//          the same BitBlt screen capture. Every capture API respects the
//          exclusion, which is why the render probe needs the no-WDA window.

#include <windows.h>

#include <chrono>
#include <cstdlib>
#include <thread>
#include <vector>

#include <gtest/gtest.h>

#include "Capture/Camera/camera_dcomp_overlay.h"
#include "Capture/Camera/camera_overlay_geometry_store.h"
#include "Capture/Camera/camera_overlay_style_store.h"

namespace clingfy::capture {
namespace {

constexpr int kL = 0, kT = 0, kR = 1920, kB = 1080;

CameraOverlayGeometry Preset(double size, int position) {
  CameraOverlayGeometry g;
  g.size = size;
  g.position = position;
  g.use_custom = false;
  return g;
}

TEST(ComputeSquareFloatingRect, SideCarriesSizeAndIsSquare) {
  const FloatingRect r =
      ComputeSquareFloatingRect(kL, kT, kR, kB, 1.0, Preset(220.0, 3));
  EXPECT_EQ(r.width, 220);
  EXPECT_EQ(r.height, 220);
}

TEST(ComputeSquareFloatingRect, DpiScales) {
  const FloatingRect r =
      ComputeSquareFloatingRect(kL, kT, kR, kB, 1.5, Preset(220.0, 3));
  EXPECT_EQ(r.width, 330);
  EXPECT_EQ(r.height, 330);
}

TEST(ComputeSquareFloatingRect, CornersUseSameMarginAsWideVariant) {
  const int margin = 1920 * 3 / 100;
  const FloatingRect tl =
      ComputeSquareFloatingRect(kL, kT, kR, kB, 1.0, Preset(220.0, 0));
  EXPECT_EQ(tl.x, margin);
  EXPECT_EQ(tl.y, margin);
  const FloatingRect br =
      ComputeSquareFloatingRect(kL, kT, kR, kB, 1.0, Preset(220.0, 3));
  EXPECT_EQ(br.x, 1920 - 220 - margin);
  EXPECT_EQ(br.y, 1080 - 220 - margin);
}

TEST(ComputeSquareFloatingRect, CustomCentersAndClamps) {
  CameraOverlayGeometry g;
  g.size = 220.0;
  g.use_custom = true;
  g.normalized_x = 0.5;
  g.normalized_y = 0.5;
  const FloatingRect c = ComputeSquareFloatingRect(kL, kT, kR, kB, 1.0, g);
  EXPECT_NEAR(c.x + c.width / 2.0, 960.0, 1.0);
  EXPECT_NEAR(c.y + c.height / 2.0, 540.0, 1.0);
  g.normalized_x = 1.0;
  g.normalized_y = 1.0;
  const FloatingRect e = ComputeSquareFloatingRect(kL, kT, kR, kB, 1.0, g);
  EXPECT_LE(e.x + e.width, 1920);
  EXPECT_LE(e.y + e.height, 1080);
}

TEST(ComputeSquareFloatingRect, ShrinksToTinyWorkArea) {
  const FloatingRect r =
      ComputeSquareFloatingRect(0, 0, 200, 150, 1.0, Preset(400.0, 3));
  EXPECT_LE(r.width, 150);
  EXPECT_EQ(r.width, r.height);
  EXPECT_GE(r.x, 0);
  EXPECT_LE(r.y + r.height, 150);
}

// ---- lifecycle (always runs; never visible) ---------------------------------

TEST(CameraDcompOverlayPoc, HiddenLifecycleBuildsTheGpuStack) {
  CameraOverlayGeometryStore::Instance().SetSize(220.0);
  CameraOverlayGeometryStore::Instance().SetPosition(3);

  CameraDcompOverlay overlay;
  FloatingPlacement place;
  place.x = 100;
  place.y = 100;
  place.width = 220;
  place.height = 220;
  if (!overlay.Start(place)) {
    // Window creation can fail in exotic sessions; a GPU-stack failure on THIS
    // box is a NO-GO signal we want loudly, so only skip when even a plain
    // window can't exist (no desktop).
    if (::GetDesktopWindow() == nullptr) {
      GTEST_SKIP() << "no desktop in this session";
    }
    FAIL() << "DComp presenter failed to start on this machine (GPU stack or "
              "window) — POC NO-GO";
  }
  EXPECT_TRUE(overlay.running());
  EXPECT_TRUE(overlay.gpu_ready());
  overlay.Stop();
  EXPECT_FALSE(overlay.running());
}

// ---- on-screen probes (pixel-canary gated) ----------------------------------

bool PixelProbesArmed() {
  char buffer[8]{};
  size_t required = 0;
  if (getenv_s(&required, buffer, sizeof(buffer),
               "CLINGFY_REQUIRE_PIXEL_TESTS") != 0) {
    return required > 1;
  }
  return required > 1;
}

// Solid-color BGRA frame (magenta): B=255 G=0 R=255.
std::vector<std::uint8_t> MagentaFrame(int w, int h) {
  std::vector<std::uint8_t> f(static_cast<size_t>(w) * h * 4);
  for (size_t i = 0; i < f.size(); i += 4) {
    f[i + 0] = 255;  // B
    f[i + 1] = 0;    // G
    f[i + 2] = 255;  // R
    f[i + 3] = 255;  // A
  }
  return f;
}

// BitBlt the screen region and report whether any sampled pixel is ~magenta.
bool ScreenRegionHasMagenta(const RECT& rc) {
  const int w = rc.right - rc.left;
  const int h = rc.bottom - rc.top;
  if (w <= 0 || h <= 0) return false;
  HDC screen = ::GetDC(nullptr);
  HDC mem = ::CreateCompatibleDC(screen);
  HBITMAP bmp = ::CreateCompatibleBitmap(screen, w, h);
  HGDIOBJ old = ::SelectObject(mem, bmp);
  ::BitBlt(mem, 0, 0, w, h, screen, rc.left, rc.top, SRCCOPY | CAPTUREBLT);
  BITMAPINFO bmi{};
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = w;
  bmi.bmiHeader.biHeight = -h;
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;
  std::vector<std::uint8_t> px(static_cast<size_t>(w) * h * 4);
  ::GetDIBits(mem, bmp, 0, h, px.data(), &bmi, DIB_RGB_COLORS);
  ::SelectObject(mem, old);
  ::DeleteObject(bmp);
  ::DeleteDC(mem);
  ::ReleaseDC(nullptr, screen);
  // Sample a coarse grid — enough to find a solid fill, cheap enough to poll.
  bool found = false;
  for (int y = 0; y < h && !found; y += 8) {
    for (int x = 0; x < w && !found; x += 8) {
      const std::uint8_t* p = &px[(static_cast<size_t>(y) * w + x) * 4];
      const int b = p[0], g = p[1], r = p[2];
      if (b > 200 && r > 200 && g < 60) found = true;
    }
  }
  return found;
}

// Common driver for both probes: start a presenter (with or without capture
// exclusion), show it centered, feed magenta, and poll the screen for it.
bool RunMagentaProbe(bool apply_exclusion, bool* wda_ok) {
  auto& geometry = CameraOverlayGeometryStore::Instance();
  auto& style = CameraOverlayStyleStore::Instance();
  geometry.SetSize(220.0);
  geometry.SetCustomPosition(0.5, 0.5);
  style.SetShape(2);      // square — the whole window is bubble content.
  style.SetRoundness(0.0);
  style.SetOpacity(1.0);
  style.SetShadow(0);
  style.SetBorder(0);
  style.SetChromaEnabled(false);
  style.SetMirror(false);

  CameraDcompOverlay::Options options;
  options.apply_capture_exclusion = apply_exclusion;
  CameraDcompOverlay overlay(options);
  FloatingPlacement place;
  place.x = 200;
  place.y = 200;
  place.width = 220;
  place.height = 220;
  bool magenta_seen = false;
  if (overlay.Start(place)) {
    if (wda_ok != nullptr) {
      *wda_ok = overlay.wda_excluded();
    }
    const std::vector<std::uint8_t> frame = MagentaFrame(64, 64);
    overlay.PublishBgra(frame.data(), 64, 64);
    overlay.Show();
    // 8s absorbs first-use cold starts (driver/shader-cache warm-up on the
    // very first DComp+D3D touch after boot was observed to exceed 3s once).
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(8);
    HWND hwnd = ::FindWindowW(L"ClingfyCameraDcompOverlay", nullptr);
    while (std::chrono::steady_clock::now() < deadline) {
      overlay.PublishBgra(frame.data(), 64, 64);  // keep the mailbox dirty.
      RECT rc{};
      if (hwnd != nullptr && ::GetWindowRect(hwnd, &rc) != 0 &&
          ScreenRegionHasMagenta(rc)) {
        magenta_seen = true;
        break;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(60));
    }
    overlay.Hide();
    overlay.Stop();
  }
  // Restore defaults for later tests.
  geometry.SetSize(220.0);
  geometry.SetPosition(3);
  style.SetShape(5);
  return magenta_seen;
}

TEST(CameraDcompOverlayPoc, RendersOnScreen_NoExclusionProbe) {
  if (!PixelProbesArmed()) {
    GTEST_SKIP() << "set CLINGFY_REQUIRE_PIXEL_TESTS=1 to run the on-screen "
                    "probe (briefly shows a window)";
  }
  EXPECT_TRUE(RunMagentaProbe(/*apply_exclusion=*/false, nullptr))
      << "the premultiplied DComp window rendered NOTHING on screen — the "
         "hybrid-GPU scar. POC NO-GO.";
}

TEST(CameraDcompOverlayPoc, ExcludedFromScreenCapture) {
  if (!PixelProbesArmed()) {
    GTEST_SKIP() << "set CLINGFY_REQUIRE_PIXEL_TESTS=1 to run the on-screen "
                    "probe (briefly shows a window)";
  }
  bool wda_ok = false;
  const bool magenta_seen = RunMagentaProbe(/*apply_exclusion=*/true, &wda_ok);
  ASSERT_TRUE(wda_ok)
      << "SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE) FAILED on the "
         "DComp window (the documented Win11 defect?) — factory falls back "
         "to GDI on this machine. POC NO-GO for DComp here.";
  EXPECT_FALSE(magenta_seen)
      << "the capture-excluded DComp window LEAKED into a screen capture — "
         "POC NO-GO.";
}

}  // namespace
}  // namespace clingfy::capture
