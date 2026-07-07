// Real-window smoke test for the floating camera bubble's live geometry: this
// is the native equivalent of the manual "click a position preset / drag the
// size slider while recording" smoke. It creates the ACTUAL CameraFloatingOverlay
// (hidden — never shown, so nothing flashes on screen), drives the process-wide
// CameraOverlayGeometryStore exactly like the bridge setters do, and asserts the
// OS window rect (GetWindowRect) converges to ComputeFloatingRect's answer via
// the overlay thread's timer sync.
//
// The overlay window stays HIDDEN throughout (Start creates it hidden and the
// test never calls Show), and geometry sync intentionally runs regardless of
// visibility, so this exercises the real SetWindowPos path without any visual
// side effect on the desktop running the tests.

#include <windows.h>

#include <chrono>
#include <thread>

#include <gtest/gtest.h>

#include "Capture/Camera/camera_floating_overlay.h"
#include "Capture/Camera/camera_overlay_geometry_store.h"

namespace clingfy::capture {
namespace {

constexpr wchar_t kOverlayClassName[] = L"ClingfyCameraFloatingOverlay";

// Compute the rect the overlay SHOULD occupy for the store's current geometry,
// using the same inputs SyncGeometryFromStore uses (nearest monitor work area +
// the window's DPI). Recomputed per poll so a monitor change mid-move can't
// produce a stale expectation.
FloatingRect ExpectedRect(HWND hwnd, const CameraOverlayGeometry& g) {
  RECT work{0, 0, ::GetSystemMetrics(SM_CXSCREEN),
            ::GetSystemMetrics(SM_CYSCREEN)};
  if (HMONITOR mon = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
      mon != nullptr) {
    MONITORINFO mi{};
    mi.cbSize = sizeof(mi);
    if (::GetMonitorInfoW(mon, &mi) != 0) {
      work = mi.rcWork;
    }
  }
  const UINT dpi = ::GetDpiForWindow(hwnd);
  const double scale = dpi > 0 ? dpi / 96.0 : 1.0;
  return ComputeFloatingRect(work.left, work.top, work.right, work.bottom,
                             scale, g);
}

// Poll (the geometry sync runs on the overlay thread's ~33ms timer) until the
// window rect matches the store-derived expectation, or time out.
::testing::AssertionResult WindowConverges(HWND hwnd) {
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(3);
  RECT last{};
  FloatingRect want{};
  while (std::chrono::steady_clock::now() < deadline) {
    const CameraOverlayGeometry g =
        CameraOverlayGeometryStore::Instance().Snapshot();
    want = ExpectedRect(hwnd, g);
    if (::GetWindowRect(hwnd, &last) != 0 && last.left == want.x &&
        last.top == want.y && last.right - last.left == want.width &&
        last.bottom - last.top == want.height) {
      return ::testing::AssertionSuccess();
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(25));
  }
  return ::testing::AssertionFailure()
         << "window rect (" << last.left << "," << last.top << " "
         << (last.right - last.left) << "x" << (last.bottom - last.top)
         << ") never converged to expected (" << want.x << "," << want.y << " "
         << want.width << "x" << want.height << ")";
}

TEST(CameraFloatingOverlayGeometrySmoke, PresetSizeAndCustomPositionMoveTheWindow) {
  auto& store = CameraOverlayGeometryStore::Instance();
  // Known starting state (Dart defaults), set BEFORE Start so the creation-time
  // sync applies it while the window is still hidden.
  store.SetSize(220.0);
  store.SetPosition(3);  // bottomRight

  CameraFloatingOverlay overlay;
  FloatingPlacement place;
  place.x = 100;
  place.y = 100;
  place.width = 400;
  place.height = 225;
  if (!overlay.Start(place)) {
    GTEST_SKIP() << "overlay window could not be created in this session";
  }

  HWND hwnd = ::FindWindowW(kOverlayClassName, nullptr);
  ASSERT_NE(hwnd, nullptr) << "overlay window class not found";

  // 1. Creation-time sync: the deliberately-wrong Start placement must have
  //    been corrected to the store's bottom-right/220 answer already.
  EXPECT_TRUE(WindowConverges(hwnd)) << "initial placement";

  // 2. Size slider: grow to 300 logical px.
  store.SetSize(300.0);
  EXPECT_TRUE(WindowConverges(hwnd)) << "size slider -> 300";

  // 3. Position preset: jump to top-left.
  store.SetPosition(0);
  EXPECT_TRUE(WindowConverges(hwnd)) << "preset -> topLeft";

  // 4. Custom position: center of the work area.
  store.SetCustomPosition(0.5, 0.5);
  EXPECT_TRUE(WindowConverges(hwnd)) << "custom -> center";

  overlay.Stop();

  // Leave the process-wide store at Dart defaults for any later test.
  store.SetSize(220.0);
  store.SetPosition(3);
}

TEST(CameraFloatingOverlayGeometrySmoke, DragEndWritesCustomPositionBack) {
  auto& store = CameraOverlayGeometryStore::Instance();
  store.SetSize(220.0);
  store.SetPosition(3);  // bottomRight, use_custom cleared.

  CameraFloatingOverlay overlay;
  FloatingPlacement place;
  place.x = 100;
  place.y = 100;
  place.width = 400;
  place.height = 225;
  if (!overlay.Start(place)) {
    GTEST_SKIP() << "overlay window could not be created in this session";
  }
  HWND hwnd = ::FindWindowW(kOverlayClassName, nullptr);
  ASSERT_NE(hwnd, nullptr);
  ASSERT_TRUE(WindowConverges(hwnd)) << "initial placement";

  // Simulate the OS drag: move the window (as the modal move loop would) and
  // deliver the drag-end signal the overlay handles.
  RECT before{};
  ASSERT_NE(::GetWindowRect(hwnd, &before), 0);
  const int nx = before.left - 180;
  const int ny = before.top - 120;
  ASSERT_NE(::SetWindowPos(hwnd, nullptr, nx, ny, 0, 0,
                           SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE),
            0);
  ::PostMessageW(hwnd, WM_EXITSIZEMOVE, 0, 0);

  // The store must adopt the dragged position as the custom center.
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(3);
  CameraOverlayGeometry g{};
  bool wrote_back = false;
  while (std::chrono::steady_clock::now() < deadline) {
    g = store.Snapshot();
    if (g.use_custom) {
      wrote_back = true;
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(25));
  }
  ASSERT_TRUE(wrote_back) << "drag end never set the custom position";

  // The written-back center matches where the window was dropped.
  RECT dropped{};
  ASSERT_NE(::GetWindowRect(hwnd, &dropped), 0);
  RECT work{0, 0, ::GetSystemMetrics(SM_CXSCREEN),
            ::GetSystemMetrics(SM_CYSCREEN)};
  if (HMONITOR mon = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
      mon != nullptr) {
    MONITORINFO mi{};
    mi.cbSize = sizeof(mi);
    if (::GetMonitorInfoW(mon, &mi) != 0) work = mi.rcWork;
  }
  const NormalizedCenter want = NormalizedCenterForRect(
      work.left, work.top, work.right, work.bottom,
      FloatingRect{dropped.left, dropped.top, dropped.right - dropped.left,
                   dropped.bottom - dropped.top});
  EXPECT_NEAR(g.normalized_x, want.x, 0.01);
  EXPECT_NEAR(g.normalized_y, want.y, 0.01);

  // Self-echo suppression: with the drag's own revision marked as seen, the
  // sync tick must not SetWindowPos again — the rect stays BIT-identical.
  // (A suppression-less re-place through the normalized round-trip lands
  // within ~2px and would slip through a tolerance check, so exact equality is
  // what actually pins the mechanism.)
  std::this_thread::sleep_for(std::chrono::milliseconds(200));
  RECT after{};
  ASSERT_NE(::GetWindowRect(hwnd, &after), 0);
  EXPECT_EQ(after.left, dropped.left);
  EXPECT_EQ(after.top, dropped.top);

  // The headline regression this PR fixes, end-to-end: a later geometry
  // mutation (the size slider) must re-place the bubble around the DRAGGED
  // center — not teleport it back to the stale bottom-right preset.
  // WindowConverges recomputes its expectation from the store snapshot, which
  // now carries use_custom + the dragged center.
  store.SetSize(300.0);
  EXPECT_TRUE(WindowConverges(hwnd)) << "size change after drag must keep the dragged center";

  overlay.Stop();
  store.SetSize(220.0);
  store.SetPosition(3);
}

}  // namespace
}  // namespace clingfy::capture
