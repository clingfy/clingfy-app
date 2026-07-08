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

// P4a sync-tick semantics, exercised HIDDEN (no Show — nothing flashes, runs
// unarmed): a style-only revision whose padding is unchanged must NOT re-place
// the window (the store's clamped placement would teleport a dragged bubble),
// while a padding-changing style revision must resize AROUND the dragged
// center.
TEST(CameraDcompOverlayPoc, StyleOnlyRevisionKeepsDraggedPosition) {
  auto& geometry = CameraOverlayGeometryStore::Instance();
  auto& style = CameraOverlayStyleStore::Instance();
  geometry.SetSize(220.0);
  geometry.SetPosition(3);
  style.SetShape(5);
  style.SetRoundness(0.0);
  style.SetOpacity(1.0);
  style.SetShadow(0);
  style.SetBorder(0);
  style.SetBorderWidth(0.0);
  style.SetChromaEnabled(false);
  style.SetMirror(false);

  CameraDcompOverlay overlay;
  FloatingPlacement place;
  place.x = 100;
  place.y = 100;
  place.width = 220;
  place.height = 220;
  if (!overlay.Start(place)) {
    if (::GetDesktopWindow() == nullptr) {
      GTEST_SKIP() << "no desktop in this session";
    }
    FAIL() << "DComp presenter failed to start on this machine";
  }
  HWND hwnd = ::FindWindowW(L"ClingfyCameraDcompOverlay", nullptr);
  ASSERT_NE(hwnd, nullptr);

  // Simulated OS drag (the modal loop's outcome): move, then drag-end.
  RECT before{};
  ASSERT_NE(::GetWindowRect(hwnd, &before), 0);
  ASSERT_NE(::SetWindowPos(hwnd, nullptr, before.left - 180, before.top - 120,
                           0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE),
            0);
  ::PostMessageW(hwnd, WM_EXITSIZEMOVE, 0, 0);
  const auto adopt_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(3);
  bool wrote_back = false;
  while (std::chrono::steady_clock::now() < adopt_deadline) {
    if (geometry.Snapshot().use_custom) {
      wrote_back = true;
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(25));
  }
  ASSERT_TRUE(wrote_back) << "drag end never wrote the custom position back";
  std::this_thread::sleep_for(std::chrono::milliseconds(150));
  RECT dropped{};
  ASSERT_NE(::GetWindowRect(hwnd, &dropped), 0);

  // Style-only revision, padding unchanged (border stays OFF, so the color
  // write cannot alter ComputeCameraEffectPadding): the rect must stay
  // BIT-identical — any move means the clamped re-place ran.
  style.SetBorderColor(0xFF112233);
  std::this_thread::sleep_for(std::chrono::milliseconds(300));
  RECT after{};
  ASSERT_NE(::GetWindowRect(hwnd, &after), 0);
  EXPECT_EQ(after.left, dropped.left)
      << "style-only revision re-placed a dragged bubble";
  EXPECT_EQ(after.top, dropped.top);
  EXPECT_EQ(after.right, dropped.right);
  EXPECT_EQ(after.bottom, dropped.bottom);

  // Padding-changing style revision: the window must grow (12 -> 30 px halo)
  // around the DRAGGED center, not teleport back to the preset corner.
  style.SetShadow(2);
  const auto grow_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(3);
  RECT grown{};
  bool grew = false;
  while (std::chrono::steady_clock::now() < grow_deadline) {
    if (::GetWindowRect(hwnd, &grown) != 0 &&
        grown.right - grown.left == 220 + 2 * 30) {
      grew = true;
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(25));
  }
  EXPECT_TRUE(grew) << "padding change did not resize the window (width="
                    << (grown.right - grown.left) << ")";
  if (grew) {
    const int dropped_cx = (dropped.left + dropped.right) / 2;
    const int dropped_cy = (dropped.top + dropped.bottom) / 2;
    const int grown_cx = (grown.left + grown.right) / 2;
    const int grown_cy = (grown.top + grown.bottom) / 2;
    EXPECT_NEAR(grown_cx, dropped_cx, 3) << "resize lost the dragged center";
    EXPECT_NEAR(grown_cy, dropped_cy, 3) << "resize lost the dragged center";
  }

  overlay.Stop();
  style.SetShadow(0);
  geometry.SetSize(220.0);
  geometry.SetPosition(3);
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

// P4a: the effect-padding halo must be click-through while the content square
// stays the drag handle. HTTRANSPARENT alone cannot fall through to other
// threads' windows, so the presenter tracks the cursor on its tick and flips
// WS_EX_TRANSPARENT at the content/halo boundary — this probe MOVES the real
// cursor (restored afterwards) and verifies both directions of the flip via
// WindowFromPoint. No pixels are read (immune to capture-privacy state), but
// it briefly shows the overlay window and drives the cursor, so it stays
// behind the armed gate like every on-screen probe.
TEST(CameraDcompOverlayPoc, HaloIsClickThroughContentIsDragHandle) {
  if (!PixelProbesArmed()) {
    GTEST_SKIP() << "set CLINGFY_REQUIRE_PIXEL_TESTS=1 to run the on-screen "
                    "probe (briefly shows a window and moves the cursor)";
  }
  auto& geometry = CameraOverlayGeometryStore::Instance();
  auto& style = CameraOverlayStyleStore::Instance();
  geometry.SetSize(220.0);
  geometry.SetCustomPosition(0.5, 0.5);
  style.SetShape(5);
  style.SetRoundness(0.0);
  style.SetOpacity(1.0);
  style.SetShadow(2);  // padding 30 px — a real halo to hit-test.
  style.SetBorder(0);
  style.SetChromaEnabled(false);
  style.SetMirror(false);

  CameraDcompOverlay overlay;
  FloatingPlacement place;
  place.x = 200;
  place.y = 200;
  place.width = 220;
  place.height = 220;
  if (!overlay.Start(place)) {
    GTEST_SKIP() << "DComp overlay could not start in this session";
  }
  overlay.Show();
  std::this_thread::sleep_for(std::chrono::milliseconds(200));

  HWND hwnd = ::FindWindowW(L"ClingfyCameraDcompOverlay", nullptr);
  ASSERT_NE(hwnd, nullptr);
  RECT wr{};
  ASSERT_NE(::GetWindowRect(hwnd, &wr), 0);
  // Deterministic (DPI-unaware test process, scale pinned to 1.0): shadow
  // preset 2 pads exactly 30, so a wrong style snapshot (e.g. the 12 px
  // default floor) is caught, not just "some padding".
  EXPECT_EQ(wr.right - wr.left, 220 + 2 * 30)
      << "window width does not match the store-derived padding";

  // The belt-and-braces WM_NCHITTEST split must answer without any cursor
  // machinery: halo -> HTTRANSPARENT (covers the flip-lag window), content ->
  // HTCAPTION (drag handle).
  const POINT center{(wr.left + wr.right) / 2, (wr.top + wr.bottom) / 2};
  EXPECT_EQ(::SendMessageW(
                hwnd, WM_NCHITTEST, 0,
                MAKELPARAM(static_cast<short>(wr.left + 5),
                           static_cast<short>(wr.top + 5))),
            HTTRANSPARENT);
  EXPECT_EQ(::SendMessageW(
                hwnd, WM_NCHITTEST, 0,
                MAKELPARAM(static_cast<short>(center.x),
                           static_cast<short>(center.y))),
            HTCAPTION);

  POINT original_cursor{};
  ::GetCursorPos(&original_cursor);
  // Several tick intervals so the cursor-tracked flip lands before sampling.
  const auto settle = std::chrono::milliseconds(150);
  // Cursor moves must actually land (a human nudging the mouse mid-probe or a
  // UIPI-elevated foreground window makes assertions below misleading).
  auto cursor_at = [](int x, int y) {
    ::SetCursorPos(x, y);
    POINT p{};
    return ::GetCursorPos(&p) != 0 && p.x == x && p.y == y;
  };

  // 1) Cursor on the halo corner: TRANSPARENT set -> hit-test falls through.
  if (!cursor_at(wr.left + 5, wr.top + 5)) {
    overlay.Hide();
    overlay.Stop();
    style.SetShadow(0);
    GTEST_SKIP() << "cursor could not be positioned (locked/elevated desktop?)";
  }
  std::this_thread::sleep_for(settle);
  const HWND at_halo = ::WindowFromPoint(POINT{wr.left + 5, wr.top + 5});
  // 2) Cursor on the content center: TRANSPARENT cleared -> ours + WDA holds
  // across the style flip (the Electron-scar re-verify must have nothing to
  // repair, or have repaired it).
  ASSERT_TRUE(cursor_at(center.x, center.y));
  std::this_thread::sleep_for(settle);
  const HWND at_content = ::WindowFromPoint(center);
  DWORD affinity_after_flip = 0;
  const BOOL affinity_read =
      ::GetWindowDisplayAffinity(hwnd, &affinity_after_flip);
  // 3) Back to the halo: the flip must be repeatable, not one-shot.
  ASSERT_TRUE(cursor_at(wr.left + 5, wr.top + 5));
  std::this_thread::sleep_for(settle);
  const HWND at_halo_again = ::WindowFromPoint(POINT{wr.left + 5, wr.top + 5});

  // 4) Style-driven resize MID-RUN (the P4a sync-tick behavior, distinct from
  // creation-time sizing): a stronger shadow must grow the window through
  // SyncAndRender within a few ticks.
  style.SetShadow(3);  // padding 41 -> width 302
  RECT grown{};
  const auto resize_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(3);
  bool resized = false;
  while (std::chrono::steady_clock::now() < resize_deadline) {
    if (::GetWindowRect(hwnd, &grown) != 0 &&
        grown.right - grown.left == 220 + 2 * 41) {
      resized = true;
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(25));
  }

  ::SetCursorPos(original_cursor.x, original_cursor.y);
  overlay.Hide();
  overlay.Stop();
  style.SetShadow(0);
  geometry.SetSize(220.0);
  geometry.SetPosition(3);

  EXPECT_NE(at_halo, hwnd)
      << "halo point hit-tested to the bubble — halo is not click-through";
  EXPECT_EQ(at_content, hwnd)
      << "content center did not hit-test to the bubble";
  EXPECT_NE(at_halo_again, hwnd)
      << "click-through did not re-engage after leaving the content";
  EXPECT_TRUE(affinity_read != 0 &&
              affinity_after_flip == WDA_EXCLUDEFROMCAPTURE)
      << "capture exclusion did not survive the WS_EX_TRANSPARENT flip "
         "(affinity=" << affinity_after_flip << ")";
  EXPECT_TRUE(resized)
      << "style-driven padding change did not resize the window mid-run "
         "(last width=" << (grown.right - grown.left) << ", want 302)";
}

// P4a content-offset wiring, end to end: PreparePainter must place the bubble
// at (padding, padding) inside the padded window. A regression to a (0,0)
// bubble keeps every other probe green (they scan the whole window rect for
// ANY magenta) while the rendered content sits top-left-shifted, misaligned
// with the hit-test content square and shadow-clipped on two sides. Pin: the
// magenta bounding box's center must coincide with the window's center in
// capture space — a (0,0) regression shifts it by ~padding * display scale
// (>= 30 px), far beyond the tolerance.
TEST(CameraDcompOverlayPoc, ContentIsCenteredInPaddedWindow) {
  if (!PixelProbesArmed()) {
    GTEST_SKIP() << "set CLINGFY_REQUIRE_PIXEL_TESTS=1 to run the on-screen "
                    "probe (briefly shows a window)";
  }
  auto& geometry = CameraOverlayGeometryStore::Instance();
  auto& style = CameraOverlayStyleStore::Instance();
  geometry.SetSize(220.0);
  geometry.SetCustomPosition(0.5, 0.5);
  style.SetShape(2);  // square: the content fills its square — crisp bbox.
  style.SetRoundness(0.0);
  style.SetOpacity(1.0);
  style.SetShadow(2);  // padding 30
  style.SetBorder(0);
  style.SetChromaEnabled(false);
  style.SetMirror(false);

  CameraDcompOverlay::Options options;
  options.apply_capture_exclusion = false;  // BitBlt must see the window.
  CameraDcompOverlay overlay(options);
  FloatingPlacement place;
  place.x = 200;
  place.y = 200;
  place.width = 220;
  place.height = 220;
  if (!overlay.Start(place)) {
    GTEST_SKIP() << "DComp overlay could not start in this session";
  }
  const std::vector<std::uint8_t> frame = MagentaFrame(64, 64);
  overlay.PublishBgra(frame.data(), 64, 64);
  overlay.Show();

  HWND hwnd = ::FindWindowW(L"ClingfyCameraDcompOverlay", nullptr);
  ASSERT_NE(hwnd, nullptr);
  RECT rc{};
  bool warm = false;
  const auto warm_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(8);
  while (std::chrono::steady_clock::now() < warm_deadline) {
    overlay.PublishBgra(frame.data(), 64, 64);
    if (::GetWindowRect(hwnd, &rc) != 0) {
      RECT wide = rc;
      const int w = rc.right - rc.left;
      wide.left -= w;
      wide.top -= w;
      wide.right += w;
      wide.bottom += w;
      if (ScreenRegionHasMagenta(wide)) {
        warm = true;
        break;
      }
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(60));
  }
  auto cleanup = [&]() {
    overlay.Hide();
    overlay.Stop();
    style.SetShadow(0);
    style.SetShape(5);
    geometry.SetSize(220.0);
    geometry.SetPosition(3);
  };
  if (!warm) {
    cleanup();
    FAIL() << "bubble never rendered — display awake and unlocked?";
  }

  // Locate the magenta bounding box in CAPTURE (physical) coordinates.
  ::GetWindowRect(hwnd, &rc);
  int seed_x = -1, seed_y = -1;
  {
    const int w = rc.right - rc.left;
    const int x0 = rc.left - w, y0 = rc.top - w;
    const int step = (3 * w) / 96;
    for (int gy = 0; gy < 96 && seed_x < 0; ++gy) {
      for (int gx = 0; gx < 96 && seed_x < 0; ++gx) {
        const int sx = x0 + gx * step, sy = y0 + gy * step;
        if (ClassifyFlickerSample(ScreenPatchAvg(sx, sy, 2, 2)) == 'M') {
          seed_x = sx;
          seed_y = sy;
        }
      }
    }
  }
  if (seed_x < 0) {
    cleanup();
    FAIL() << "could not locate magenta content in the capture";
  }
  auto walk = [&](int x, int y, int dx, int dy) {
    while (ClassifyFlickerSample(ScreenPatchAvg(x, y, 2, 2)) == 'M') {
      x += dx;
      y += dy;
    }
    return std::pair<int, int>(x, y);
  };
  // Center the seed first so the four walks measure the true extents.
  const int row_l = walk(seed_x, seed_y, -1, 0).first;
  const int row_r = walk(seed_x, seed_y, 1, 0).first;
  const int mid_x = (row_l + row_r) / 2;
  const int col_t = walk(mid_x, seed_y, 0, -1).second;
  const int col_b = walk(mid_x, seed_y, 0, 1).second;
  const int mid_y = (col_t + col_b) / 2;
  const int box_l = walk(mid_x, mid_y, -1, 0).first;
  const int box_r = walk(mid_x, mid_y, 1, 0).first;
  const int box_t = walk(mid_x, mid_y, 0, -1).second;
  const int box_b = walk(mid_x, mid_y, 0, 1).second;

  // Virtual -> physical scale (the test process is DPI-unaware; the capture
  // is physical). Primary monitor sits at the origin in both spaces.
  HDC screen = ::GetDC(nullptr);
  const double phys_scale =
      static_cast<double>(::GetDeviceCaps(screen, DESKTOPHORZRES)) /
      (std::max)(1, ::GetDeviceCaps(screen, HORZRES));
  ::ReleaseDC(nullptr, screen);
  const double want_cx = ((rc.left + rc.right) / 2.0) * phys_scale;
  const double want_cy = ((rc.top + rc.bottom) / 2.0) * phys_scale;
  const double want_side = 220.0 * phys_scale;
  const double got_cx = (box_l + box_r) / 2.0;
  const double got_cy = (box_t + box_b) / 2.0;
  std::cout << "[content-center] bbox=(" << box_l << "," << box_t << ")-("
            << box_r << "," << box_b << ") center=(" << got_cx << ","
            << got_cy << ") want=(" << want_cx << "," << want_cy
            << ") scale=" << phys_scale << std::endl;
  cleanup();

  EXPECT_NEAR(got_cx, want_cx, 14.0)
      << "content is horizontally off the window center — bubble offset "
         "regression (a (0,0) bubble shifts by ~" << 30 * phys_scale << ")";
  EXPECT_NEAR(got_cy, want_cy, 14.0)
      << "content is vertically off the window center";
  EXPECT_NEAR(box_r - box_l, want_side, 14.0)
      << "content square is not the DPI-scaled 220 px";
}

// P4b: the recording glow ring must render on the live bubble and PULSE (the
// macOS opacity animation). The red stroke sits just inside the content edge
// over the magenta camera, so its BLUE channel swings with the pulse opacity
// (magenta b=255, systemRed b=48: p=0.75 -> ~103, p=1.0 -> ~48) while the
// bubble center stays steady magenta. Disabling the glow must shrink the
// window back to the 12 px halo (padding is glow-gated).
TEST(CameraDcompOverlayPoc, GlowRingPulsesOnTheLiveBubble) {
  if (!PixelProbesArmed()) {
    GTEST_SKIP() << "set CLINGFY_REQUIRE_PIXEL_TESTS=1 to run the on-screen "
                    "probe (briefly shows a window)";
  }
  auto& geometry = CameraOverlayGeometryStore::Instance();
  auto& style = CameraOverlayStyleStore::Instance();
  geometry.SetSize(220.0);
  geometry.SetCustomPosition(0.5, 0.5);
  style.SetShape(2);  // square: ring hugs the content edge, crisp geometry.
  style.SetRoundness(0.0);
  style.SetOpacity(1.0);
  style.SetShadow(0);
  style.SetBorder(0);
  style.SetChromaEnabled(false);
  style.SetMirror(false);
  style.SetGlowStrength(1.0);  // strongest swing: pulse 0.75..1.0, lw 10.
  style.SetGlowEnabled(true);

  CameraDcompOverlay::Options options;
  options.apply_capture_exclusion = false;  // BitBlt must see the window.
  CameraDcompOverlay overlay(options);
  FloatingPlacement place;
  place.x = 200;
  place.y = 200;
  place.width = 220;
  place.height = 220;
  if (!overlay.Start(place)) {
    style.SetGlowEnabled(false);
    GTEST_SKIP() << "DComp overlay could not start in this session";
  }
  const std::vector<std::uint8_t> frame = MagentaFrame(64, 64);
  overlay.PublishBgra(frame.data(), 64, 64);
  overlay.Show();

  HWND hwnd = ::FindWindowW(L"ClingfyCameraDcompOverlay", nullptr);
  ASSERT_NE(hwnd, nullptr);
  auto cleanup = [&]() {
    overlay.Hide();
    overlay.Stop();
    style.SetGlowEnabled(false);
    style.SetShape(5);
    geometry.SetSize(220.0);
    geometry.SetPosition(3);
  };
  RECT rc{};
  bool warm = false;
  const auto warm_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(8);
  while (std::chrono::steady_clock::now() < warm_deadline) {
    overlay.PublishBgra(frame.data(), 64, 64);
    if (::GetWindowRect(hwnd, &rc) != 0) {
      RECT wide = rc;
      const int w = rc.right - rc.left;
      wide.left -= w;
      wide.top -= w;
      wide.right += w;
      wide.bottom += w;
      if (ScreenRegionHasMagenta(wide)) {
        warm = true;
        break;
      }
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(60));
  }
  if (!warm) {
    cleanup();
    FAIL() << "bubble never rendered — display awake and unlocked?";
  }
  // Glow-on padding: 21 + 47*1.0 = 68 px halo (DPI-unaware process, scale 1).
  ::GetWindowRect(hwnd, &rc);
  EXPECT_EQ(rc.right - rc.left, 220 + 2 * 68)
      << "window does not carry the glow-reserved padding";

  // Locate the magenta interior; the ring is the red band just outside it.
  int seed_x = -1, seed_y = -1;
  {
    const int w = rc.right - rc.left;
    const int x0 = rc.left - w, y0 = rc.top - w;
    const int step = (3 * w) / 96;
    for (int gy = 0; gy < 96 && seed_x < 0; ++gy) {
      for (int gx = 0; gx < 96 && seed_x < 0; ++gx) {
        const int sx = x0 + gx * step, sy = y0 + gy * step;
        if (ClassifyFlickerSample(ScreenPatchAvg(sx, sy, 2, 2)) == 'M') {
          seed_x = sx;
          seed_y = sy;
        }
      }
    }
  }
  if (seed_x < 0) {
    cleanup();
    FAIL() << "could not locate magenta content in the capture";
  }
  auto walk = [&](int x, int y, int dx, int dy) {
    while (ClassifyFlickerSample(ScreenPatchAvg(x, y, 2, 2)) == 'M') {
      x += dx;
      y += dy;
    }
    return std::pair<int, int>(x, y);
  };
  const int row_l = walk(seed_x, seed_y, -1, 0).first;
  const int row_r = walk(seed_x, seed_y, 1, 0).first;
  const int mid_x = (row_l + row_r) / 2;
  const int col_t = walk(mid_x, seed_y, 0, -1).second;
  const int col_b = walk(mid_x, seed_y, 0, 1).second;
  const int mid_y = (col_t + col_b) / 2;
  const int magenta_l = walk(mid_x, mid_y, -1, 0).first;
  const int ring_x = magenta_l - 6;  // inside the red stroke band

  // Sample the pulse for ~2 s (s=1.0 -> full period 1.2 s): the ring's blue
  // channel must swing while the bubble center holds steady.
  int ring_b_min = 255, ring_b_max = 0, ring_r_sum = 0, samples = 0;
  int cam_b_min = 255, cam_b_max = 0;
  const auto pulse_deadline =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(2000);
  auto next_publish = std::chrono::steady_clock::now();
  while (std::chrono::steady_clock::now() < pulse_deadline) {
    if (std::chrono::steady_clock::now() >= next_publish) {
      overlay.PublishBgra(frame.data(), 64, 64);
      next_publish += std::chrono::milliseconds(66);
    }
    const AvgColor ring = ScreenPatchAvg(ring_x, mid_y, 2, 2);
    const AvgColor cam = ScreenPatchAvg(mid_x, mid_y, 2, 2);
    ring_b_min = (std::min)(ring_b_min, ring.b);
    ring_b_max = (std::max)(ring_b_max, ring.b);
    ring_r_sum += ring.r;
    cam_b_min = (std::min)(cam_b_min, cam.b);
    cam_b_max = (std::max)(cam_b_max, cam.b);
    ++samples;
    std::this_thread::sleep_for(std::chrono::milliseconds(40));
  }
  std::cout << "[glow-pulse] ring b=[" << ring_b_min << "," << ring_b_max
            << "] avg r=" << (samples > 0 ? ring_r_sum / samples : -1)
            << " cam b=[" << cam_b_min << "," << cam_b_max << "] samples="
            << samples << std::endl;

  // Disabling the glow must shrink the window (padding 68 -> 12).
  style.SetGlowEnabled(false);
  bool shrank = false;
  RECT small_rc{};
  const auto shrink_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(3);
  while (std::chrono::steady_clock::now() < shrink_deadline) {
    if (::GetWindowRect(hwnd, &small_rc) != 0 &&
        small_rc.right - small_rc.left == 220 + 2 * 12) {
      shrank = true;
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(25));
  }
  cleanup();

  EXPECT_GT(ring_r_sum / (std::max)(1, samples), 150)
      << "the ring band is not red — glow ring missing";
  EXPECT_GT(ring_b_max - ring_b_min, 25)
      << "the ring's blue channel did not swing — glow is not pulsing";
  EXPECT_LT(cam_b_max - cam_b_min, 20)
      << "the bubble interior is unstable — probe aim suspect";
  EXPECT_TRUE(shrank) << "disabling the glow did not shrink the window "
                         "(width=" << (small_rc.right - small_rc.left) << ")";
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
