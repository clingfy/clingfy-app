#ifndef RUNNER_CAPTURE_CAMERA_CAMERA_OVERLAY_DRAG_H_
#define RUNNER_CAPTURE_CAMERA_CAMERA_OVERLAY_DRAG_H_

#include <windows.h>

#include <cstdint>

// Shared drag write-back for floating camera-bubble presenters (renderer P1,
// factored out in P3 so the GDI and DComp presenters share one code path).
//
// On WM_EXITSIZEMOVE a presenter calls this: it reads the window rect and the
// nearest monitor's work area, stores the normalized center on the process-wide
// CameraOverlayGeometryStore as the custom position, and reports it to Dart via
// CameraOverlayMovePublisher (`cameraOverlayMoved`) so it persists — macOS
// ScreenRecorderEventBridge parity.
//
// Returns the geometry-store revision the write produced (0 if the window rect
// could not be read and nothing was written). The caller must mark that
// revision as already-seen THROUGH AdoptDragRevision (camera_overlay_geometry_
// store.h) — not by assigning it directly: a platform-thread setter that
// landed between the caller's last sync tick and this write-back holds an
// intermediate revision, and adopting the returned one unconditionally would
// jump the seen counter past it, silently dropping that mutation.
namespace clingfy::capture {

std::uint64_t WriteBackOverlayDragEnd(HWND hwnd);

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CAMERA_CAMERA_OVERLAY_DRAG_H_
