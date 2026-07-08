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
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include <gtest/gtest.h>

#include "Capture/Camera/camera_dcomp_overlay.h"
#include "Capture/Camera/camera_floating_overlay.h"
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

TEST(ComputeSquareFloatingRect, TopRightAndBottomLeftCornersDecode) {
  // Positions 1/2 pin the right/bottom booleans against a transposition —
  // TL(0) and BR(3) alone are insensitive to swapping them.
  const int margin = 1920 * 3 / 100;
  const FloatingRect tr =
      ComputeSquareFloatingRect(kL, kT, kR, kB, 1.0, Preset(220.0, 1));
  EXPECT_EQ(tr.x, 1920 - 220 - margin);
  EXPECT_EQ(tr.y, margin);
  const FloatingRect bl =
      ComputeSquareFloatingRect(kL, kT, kR, kB, 1.0, Preset(220.0, 2));
  EXPECT_EQ(bl.x, margin);
  EXPECT_EQ(bl.y, 1080 - 220 - margin);
}

TEST(ComputeSquareFloatingRect, ClampsSizeToWireRange) {
  // The bridge setters lean on this clamp; a snapshot escaping [120,400] must
  // not produce an outsized (or sub-minimum) window.
  const FloatingRect big =
      ComputeSquareFloatingRect(kL, kT, kR, kB, 1.0, Preset(1000.0, 3));
  EXPECT_EQ(big.width, 400);
  EXPECT_EQ(big.height, 400);
  const FloatingRect tiny =
      ComputeSquareFloatingRect(kL, kT, kR, kB, 1.0, Preset(50.0, 3));
  EXPECT_EQ(tiny.width, 120);
  EXPECT_EQ(tiny.height, 120);
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

// Armed only by the EXACT value "1" — the repo's pixel-canary convention
// (export_pipeline_test.cpp, preview_compositor_color_test.cpp) — so setting
// CLINGFY_REQUIRE_PIXEL_TESTS=0 disarms these probes like every other canary.
bool PixelProbesArmed() {
  char buffer[8]{};
  size_t required = 0;
  if (getenv_s(&required, buffer, sizeof(buffer),
               "CLINGFY_REQUIRE_PIXEL_TESTS") != 0 ||
      required == 0) {
    return false;  // unset, or a value too long to be "1".
  }
  return buffer[0] == '1' && buffer[1] == '\0';
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

// Average color of a small screen patch (BitBlt + CAPTUREBLT like the magenta
// probe, but scoped to a few pixels so it can poll at high frequency).
struct AvgColor {
  int r = 0, g = 0, b = 0;
};
AvgColor ScreenPatchAvg(int x, int y, int w, int h) {
  AvgColor avg;
  if (w <= 0 || h <= 0) return avg;
  HDC screen = ::GetDC(nullptr);
  HDC mem = ::CreateCompatibleDC(screen);
  HBITMAP bmp = ::CreateCompatibleBitmap(screen, w, h);
  HGDIOBJ old = ::SelectObject(mem, bmp);
  ::BitBlt(mem, 0, 0, w, h, screen, x, y, SRCCOPY | CAPTUREBLT);
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
  long rs = 0, gs = 0, bs = 0;
  const int n = w * h;
  for (int i = 0; i < n; ++i) {
    bs += px[i * 4 + 0];
    gs += px[i * 4 + 1];
    rs += px[i * 4 + 2];
  }
  avg.r = static_cast<int>(rs / n);
  avg.g = static_cast<int>(gs / n);
  avg.b = static_cast<int>(bs / n);
  return avg;
}

char ClassifyFlickerSample(const AvgColor& c) {
  if (c.r > 150 && c.b > 150 && c.g < 80) return 'M';  // magenta camera
  // Red border: tolerant of DXGI stretch blur + capture scaling (observed as
  // washed-out red ~r=110..200 against dark backgrounds).
  if (c.r > 90 && c.r > 2 * c.g && c.r > 2 * c.b) return 'B';
  return 'O';
}

int CountTransitions(const std::string& s) {
  int t = 0;
  for (size_t i = 1; i < s.size(); ++i) {
    if (s[i] != s[i - 1]) ++t;
  }
  return t;
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
  // Positive control INSIDE this test: prove magenta is detectable at all on
  // this machine before asserting its absence — otherwise a renders-nothing
  // box (the hybrid-GPU scar) passes the exclusion assertion vacuously when
  // this test runs in isolation (ctest -R ExcludedFromScreenCapture).
  ASSERT_TRUE(RunMagentaProbe(/*apply_exclusion=*/false, nullptr))
      << "positive control rendered nothing — the absence assertion below "
         "would be vacuous. POC NO-GO.";
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

// GDI presenter border integrity: the bubble used to paint camera then border
// straight onto the window DC (camera_floating_overlay.cpp Paint). Without a
// back buffer, every repaint transiently overwrote the border ring with camera
// pixels, and whenever DWM composed inside that window the DISPLAYED frame had
// no border — the user-reported "border flickers non-stop, camera solid" (it
// stopped on pause because pause stops the repaints; measured pre-fix as
// 12/180 borderless samples on the composed screen over 6s). This test streams
// frames and asserts the composed screen NEVER shows the border zone without
// its border: it fails on an unbuffered Paint and passes with the
// double-buffered one.
//
// It MUST sample the DWM-composed screen, not the window's own DC — GetPixel
// on the window DC serializes with (and flushes) the painter's GDI batch, so
// the mid-paint state is invisible there; DWM textures the redirection surface
// without that serialization, which is exactly how users see the flicker.
// Like every armed pixel probe, it needs an awake, unlocked desktop.
TEST(CameraFloatingOverlayPaint, BorderNeverDropsWhileStreaming) {
  if (!PixelProbesArmed()) {
    GTEST_SKIP() << "set CLINGFY_REQUIRE_PIXEL_TESTS=1 to run the on-screen "
                    "probe (briefly shows a window)";
  }
  auto& geometry = CameraOverlayGeometryStore::Instance();
  auto& style = CameraOverlayStyleStore::Instance();
  geometry.SetSize(220.0);
  geometry.SetCustomPosition(0.5, 0.5);
  style.SetShape(5);  // squircle — the user's failing shape.
  style.SetRoundness(0.0);
  style.SetOpacity(1.0);
  style.SetShadow(0);  // GDI bubble has no shadow anyway.
  style.SetBorder(1);
  style.SetBorderWidth(8.0);
  style.SetBorderColor(0xFFFF0000);  // opaque red
  style.SetChromaEnabled(false);
  style.SetMirror(false);

  CameraFloatingOverlay overlay;
  FloatingPlacement place;
  place.x = 200;
  place.y = 200;
  place.width = 400;
  place.height = 225;
  if (!overlay.Start(place)) {
    GTEST_SKIP() << "GDI overlay could not start in this session";
  }
  HWND hwnd = ::FindWindowW(L"ClingfyCameraFloatingOverlay", nullptr);
  ASSERT_NE(hwnd, nullptr);
  // Start applies WDA_EXCLUDEFROMCAPTURE, which hides the window from screen
  // BitBlt. Lift it (own window, own process) so the probe can sample the
  // DWM-composed display — display-side behavior is unaffected by WDA.
  ::SetWindowDisplayAffinity(hwnd, WDA_NONE);
  const std::vector<std::uint8_t> frame = MagentaFrame(64, 64);
  overlay.PublishBgra(frame.data(), 64, 64);
  overlay.Show();

  // Warm-up: keep frames flowing until magenta is on screen. The test process
  // is DPI-unaware, so the window rect is virtualized while captures are
  // physical — scan a rect WIDENED by a full window size on every side so a
  // physical/virtual offset (any monitor scale) can't hide the content.
  const auto warm_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(8);
  RECT rc{};
  bool warm = false;
  while (std::chrono::steady_clock::now() < warm_deadline) {
    overlay.PublishBgra(frame.data(), 64, 64);
    if (::GetWindowRect(hwnd, &rc) != 0) {
      RECT wide = rc;
      const int w = rc.right - rc.left;
      const int h = rc.bottom - rc.top;
      wide.left -= w;
      wide.top -= h;
      wide.right += w;
      wide.bottom += h;
      if (ScreenRegionHasMagenta(wide)) {
        warm = true;
        break;
      }
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(60));
  }
  if (!warm) {
    overlay.Hide();
    overlay.Stop();
    style.SetBorder(0);
    style.SetBorderWidth(0.0);
    geometry.SetSize(220.0);
    geometry.SetPosition(3);
    FAIL() << "GDI bubble never rendered on screen — is the display awake and "
              "the session unlocked?";
  }

  // Self-locate the content in CAPTURE coordinates (the test process is
  // DPI-unaware, so window rects are virtualized while captures are physical),
  // then measure BOTH extents so the border sample sits at the content's true
  // mid-height — on the squircle's straight edge, not its corner arc.
  ::GetWindowRect(hwnd, &rc);
  int seed_x = -1, seed_y = -1;
  {
    const int w = rc.right - rc.left;
    const int x0 = rc.left - w / 2, y0 = rc.top - w / 2;
    const int step = (2 * w) / 66;
    for (int gy = 0; gy < 66 && seed_x < 0; ++gy) {
      for (int gx = 0; gx < 66 && seed_x < 0; ++gx) {
        const int sx = x0 + gx * step, sy = y0 + gy * step;
        if (ClassifyFlickerSample(ScreenPatchAvg(sx, sy, 2, 2)) == 'M') {
          seed_x = sx + 24;
          seed_y = sy + 24;
        }
      }
    }
  }
  ASSERT_GT(seed_x, 0) << "could not locate magenta content in the capture";
  auto walk = [&](int x, int y, int dx, int dy) {
    while (ClassifyFlickerSample(ScreenPatchAvg(x, y, 2, 2)) == 'M') {
      x += dx;
      y += dy;
    }
    return std::pair<int, int>(x, y);
  };
  const int content_l = walk(seed_x, seed_y, -1, 0).first;
  const int content_r = walk(seed_x, seed_y, 1, 0).first;
  const int mid_x = (content_l + content_r) / 2;
  const int content_t = walk(mid_x, seed_y, 0, -1).second;
  const int content_b = walk(mid_x, seed_y, 0, 1).second;
  const int mid_y = (content_t + content_b) / 2;
  // Left border zone at true mid-height: just past the content edge.
  const int edge = walk(mid_x, mid_y, -1, 0).first;
  int b_first = -1, b_last = -1;
  for (int i = 0; i < 24; ++i) {
    const char k = ClassifyFlickerSample(ScreenPatchAvg(edge - i, mid_y, 2, 2));
    if (k == 'B') {
      if (b_first < 0) b_first = edge - i;
      b_last = edge - i;
    } else if (b_first >= 0) {
      break;
    }
  }
  std::cout << "[gdi-border] content x=[" << content_l << "," << content_r
            << "] y=[" << content_t << "," << content_b << "] border zone=["
            << b_last << "," << b_first << "] @y=" << mid_y << std::endl;
  const int border_x = b_first >= 0 ? (b_first + b_last) / 2 : -1;

  // Stream ~30fps for 6s and sample the composed screen: the border pixel must
  // be 'B' in EVERY sample; the camera center stays 'M' as the control.
  std::string border_tl, cam_tl;
  if (border_x >= 0) {
    auto next_publish = std::chrono::steady_clock::now();
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(6);
    while (std::chrono::steady_clock::now() < deadline) {
      if (std::chrono::steady_clock::now() >= next_publish) {
        overlay.PublishBgra(frame.data(), 64, 64);
        next_publish += std::chrono::milliseconds(33);
      }
      border_tl += ClassifyFlickerSample(ScreenPatchAvg(border_x, mid_y, 2, 2));
      cam_tl += ClassifyFlickerSample(ScreenPatchAvg(mid_x, mid_y, 2, 2));
    }
  }

  overlay.Hide();
  overlay.Stop();
  style.SetBorder(0);
  style.SetBorderWidth(0.0);
  style.SetShape(5);
  geometry.SetSize(220.0);
  geometry.SetPosition(3);

  ASSERT_GE(border_x, 0) << "no border found left of the content at "
                            "mid-height";
  int border_drops = 0;
  for (char c : border_tl) {
    if (c != 'B') ++border_drops;
  }
  int cam_drops = 0;
  for (char c : cam_tl) {
    if (c != 'M') ++cam_drops;
  }
  std::cout << "[gdi-border] samples=" << border_tl.size() << " borderDrops="
            << border_drops << " transitions=" << CountTransitions(border_tl)
            << " camDrops=" << cam_drops << std::endl;
  std::cout << "[gdi-border] border: " << border_tl.substr(0, 160)
            << std::endl;
  EXPECT_EQ(border_drops, 0)
      << "the GDI bubble's border vanished from the composed screen "
      << border_drops << "/" << border_tl.size()
      << " samples while streaming — the camera-then-border Paint must stay "
         "double-buffered";
  EXPECT_EQ(cam_drops, 0) << "camera content was unstable — probe aim suspect";
}

}  // namespace
}  // namespace clingfy::capture
