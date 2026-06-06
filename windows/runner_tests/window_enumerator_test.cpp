#include "Bridge/Devices/window_enumerator.h"

#include <windows.h>

#include <gtest/gtest.h>

#include <cstdint>

namespace clingfy::bridge::devices {
namespace {

// Phase 7.1: ResolveAppWindow reverses the HWND-as-int64 `window_id` that
// EnumerateAppWindows surfaces and revalidates the handle, so the recording
// engine can turn a Dart-selected window id back into a live HWND for WGC
// CreateForWindow (and fail cleanly when the window has gone away).

TEST(ResolveAppWindowTest, NulloptIdReturnsNullopt) {
  EXPECT_FALSE(ResolveAppWindow(std::nullopt).has_value());
}

TEST(ResolveAppWindowTest, BogusIdReturnsNullopt) {
  // An int64 that does not name a window must not resolve to a dangling HWND.
  EXPECT_FALSE(
      ResolveAppWindow(std::optional<std::int64_t>(0xABCD1234)).has_value());
}

TEST(ResolveAppWindowTest, LiveWindowResolvesThenStaleAfterDestroy) {
  // "STATIC" is a built-in window class, so no RegisterClass is needed. The
  // window is never shown; ResolveAppWindow only checks the handle is live.
  HWND hwnd = ::CreateWindowExW(0, L"STATIC", L"clingfy-resolve-test",
                                WS_OVERLAPPEDWINDOW, 0, 0, 16, 16, nullptr,
                                nullptr, ::GetModuleHandleW(nullptr), nullptr);
  ASSERT_NE(hwnd, nullptr);

  const std::int64_t id =
      static_cast<std::int64_t>(reinterpret_cast<std::uintptr_t>(hwnd));
  const auto resolved = ResolveAppWindow(id);
  ASSERT_TRUE(resolved.has_value());
  EXPECT_EQ(*resolved, hwnd);

  ::DestroyWindow(hwnd);
  // The same id no longer names a live window after destruction.
  EXPECT_FALSE(ResolveAppWindow(id).has_value());
}

}  // namespace
}  // namespace clingfy::bridge::devices
