#ifndef RUNNER_CAPTURE_CAMERA_CAMERA_OVERLAY_GEOMETRY_STORE_H_
#define RUNNER_CAPTURE_CAMERA_CAMERA_OVERLAY_GEOMETRY_STORE_H_

#include <cstdint>
#include <mutex>

// Live camera-overlay GEOMETRY (position + size) for the recording preview.
//
// Sibling of CameraOverlayStyleStore, split out because geometry drives the
// floating bubble's PLACEMENT (SetWindowPos on the overlay thread) rather than
// its LOOK (window region / paint). On macOS these map to camera.resize() /
// camera.updatePosition(); on Windows they used to be no-op bridge setters, so
// the floating bubble ignored size/position and only OS drag (WM_NCHITTEST ->
// HTCAPTION) moved it. This store is the missing native state.
//
// Wire contract (keep in sync with lib/app/home/overlay/overlay_controller.dart):
//   setCameraOverlaySize           {size:double}   120..400 logical px (macOS pts)
//   setCameraOverlayPosition       {position:int}  OverlayPosition index 0..3
//   setCameraOverlayCustomPosition {normalizedX,normalizedY:double} 0..1 center
//
// OverlayPosition.index (Dart: enum OverlayPosition { topLeft(0), topRight(1),
// bottomLeft(2), bottomRight(3) }).
namespace clingfy::capture {

// Plain snapshot of the live overlay geometry. Defaults mirror the Dart defaults
// (overlaySize 220, position bottomRight) so a snapshot taken before any setter
// fires places a sane bubble.
struct CameraOverlayGeometry {
  double size = 220.0;      // logical px (DPI-independent); clamped to [120,400].
  int position = 3;         // OverlayPosition index; used when !use_custom.
  bool use_custom = false;  // true -> normalized center drives placement.
  double normalized_x = 0.5;
  double normalized_y = 0.5;
};

// A rectangle in physical screen pixels.
struct FloatingRect {
  int x = 0;
  int y = 0;
  int width = 0;
  int height = 0;
};

// Pure geometry: given the target monitor's work area (physical px), the DPI
// scale (dpi/96) of that monitor, and a geometry snapshot, compute where the
// 16:9 floating bubble window should sit.
//
// The bubble's SHORT edge (height) carries `size`, so a compact (circle/square)
// bubble -- inscribed in the window's centered square (see
// CameraOverlayInscribedSquare) -- has diameter == size, matching the macOS
// square overlay and the in-app bubble. Width follows the 16:9 camera aspect.
// The window is kept fully inside the work area (an oversized `size` on a small
// screen shrinks to fit). Unit-tested; no Win32 calls.
FloatingRect ComputeFloatingRect(int work_left, int work_top, int work_right,
                                 int work_bottom, double dpi_scale,
                                 const CameraOverlayGeometry& g);

// Pure inverse for drag write-back: a window rect's center expressed as the
// normalized (0..1, clamped) fraction of the work area — the coordinate space
// Dart persists and `use_custom` placement consumes. Unit-tested; no Win32.
struct NormalizedCenter {
  double x = 0.5;
  double y = 0.5;
};
NormalizedCenter NormalizedCenterForRect(int work_left, int work_top,
                                         int work_right, int work_bottom,
                                         const FloatingRect& rect);

// Drag write-back revision adoption: the overlay may mark its own
// SetCustomPosition revision as seen ONLY when it directly follows the last
// revision it synced (returned == last_seen + 1) — i.e. no platform-thread
// setter slipped in between. Otherwise the seen revision is left untouched so
// the next sync tick applies the intervening mutation (re-placing at the
// just-written custom center is idempotent, so nothing is lost). Pure;
// unit-tested.
std::uint64_t AdoptDragRevision(std::uint64_t last_seen,
                                std::uint64_t returned);

// Thread-safe holder. Setters run on the platform thread (bridge handlers);
// Snapshot()/revision() run on the floating overlay thread.
class CameraOverlayGeometryStore {
 public:
  // Directly constructible so unit tests get an isolated instance; production
  // code shares the process-wide Instance().
  CameraOverlayGeometryStore() = default;

  static CameraOverlayGeometryStore& Instance();

  void SetSize(double size);
  // A preset corner. Also clears the custom-position flag (a preset overrides a
  // prior drag).
  void SetPosition(int position);
  // A free normalized center (0..1 of the work area). Sets the custom flag.
  // Returns the revision this mutation produced so a caller that is ALSO the
  // sync consumer (the overlay writing back its own drag) can mark it as seen
  // atomically — without racing a concurrent platform-thread setter, whose
  // later revision must still be applied.
  std::uint64_t SetCustomPosition(double normalized_x, double normalized_y);

  // A consistent copy of the current geometry.
  CameraOverlayGeometry Snapshot() const;

  // Monotonic counter bumped on every mutation, so the overlay can cheaply
  // detect "did anything change since I last placed the window?".
  std::uint64_t revision() const;

 private:
  mutable std::mutex mutex_;
  CameraOverlayGeometry geometry_;
  std::uint64_t revision_ = 0;
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CAMERA_CAMERA_OVERLAY_GEOMETRY_STORE_H_
