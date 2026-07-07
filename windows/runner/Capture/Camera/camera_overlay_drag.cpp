#include "Capture/Camera/camera_overlay_drag.h"

#include "Bridge/camera_overlay_move_publisher.h"
#include "Capture/Camera/camera_overlay_geometry_store.h"

namespace clingfy::capture {

std::uint64_t WriteBackOverlayDragEnd(HWND hwnd) {
  RECT wnd{};
  if (::GetWindowRect(hwnd, &wnd) == 0) {
    return 0;
  }
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
  const FloatingRect rect{wnd.left, wnd.top, wnd.right - wnd.left,
                          wnd.bottom - wnd.top};
  const NormalizedCenter center = NormalizedCenterForRect(
      work.left, work.top, work.right, work.bottom, rect);

  const std::uint64_t revision =
      CameraOverlayGeometryStore::Instance().SetCustomPosition(center.x,
                                                               center.y);
  clingfy::bridge::CameraOverlayMovePublisher::Instance().EmitMoved(center.x,
                                                                    center.y);
  return revision;
}

}  // namespace clingfy::capture
