#ifndef RUNNER_CAPTURE_CAMERA_CAMERA_OVERLAY_GEOMETRY_STORE_H_
#define RUNNER_CAPTURE_CAMERA_CAMERA_OVERLAY_GEOMETRY_STORE_H_

#include <cstdint>
#include <mutex>
#include <optional>
#include <string>

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

// Square variant for the DirectComposition presenter (renderer redesign P3):
// the macOS bubble window is a SQUARE of side `size` — the shape the shared
// CameraBubblePainter assumes — so the DComp window adopts it. Side carries
// `size` (clamped 120..400 logical px, scaled by dpi_scale), shrunk to fit the
// work area; corner presets use the same 3%-of-width margin as the 16:9
// variant; custom placement centers on the normalized point. Unit-tested; no
// Win32 calls.
FloatingRect ComputeSquareFloatingRect(int work_left, int work_top,
                                       int work_right, int work_bottom,
                                       double dpi_scale,
                                       const CameraOverlayGeometry& g);

// Renderer redesign P4a: the DComp presenter's window outsizes its content
// square by an effect-padding halo on every side so border / shadow / glow are
// not clipped at the window edge (macOS: side = contentSize + 2*effectPadding).
// The CONTENT keeps ComputeSquareFloatingRect's placement exactly — corner
// margins, normalized-center placement, and work-area clamping all apply to
// the content square — and the WINDOW is that rect outset by `padding_px`, so
// the halo may overhang the work area edge (macOS parity: presets place the
// panel at `margin - effectPadding`). Window center == content center, which
// keeps NormalizedCenterForRect drag write-back padding-agnostic.
struct PaddedSquareRect {
  FloatingRect window;   // physical px, content outset by padding_px each side
  int padding_px = 0;    // physical px of halo on each side
  int content_side = 0;  // physical px, the square the painter draws into
};
// `effect_padding_px` is in physical px (ComputeCameraEffectPadding's output —
// the painter renders shadow/border/glow in physical px, so the halo must not
// be DPI-scaled). Pure; unit-tested; no Win32 calls.
PaddedSquareRect ComputePaddedSquareFloatingRect(
    int work_left, int work_top, int work_right, int work_bottom,
    double dpi_scale, const CameraOverlayGeometry& g, double effect_padding_px);

// Hit-test split for the padded window (WM_NCHITTEST): true when the CLIENT
// point lands on the content square (drag handle); false over the halo, which
// must be click-through (HTTRANSPARENT — macOS hitTest parity). Pure.
bool CameraOverlayPointInContent(int client_x, int client_y, int padding_px,
                                 int content_side);

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

// Record-stop -> editor hand-off: the live overlay geometry expressed in the
// EDITOR's coordinate space, for CameraEditorSeed (macOS parity with
// ScreenRecorderFacade.editorSeed / initialEditorCameraCenter).
//
// This is not a rename of the store's fields — the two live in different
// spaces and both axes need converting:
//
//   POSITION. The store normalizes against the MONITOR WORK AREA (rcWork, so
//   the taskbar band is excluded) of whatever monitor the bubble was last
//   dropped on. The seed normalizes against the CAPTURED CONTENT rect, which
//   for a display capture is the FULL monitor (rcMonitor, taskbar included),
//   for an area capture is the crop box, and for a window capture is the
//   window's extended frame bounds. Those rects do not coincide, so the value
//   has to go through absolute screen pixels: de-normalize against the work
//   area, then re-normalize against the content rect. (macOS gets away with a
//   near-identity here because it normalizes the overlay against visibleFrame
//   and falls back to visibleFrame as the content rect; Windows does not.)
//
//   Y AXIS. The store measures y DOWN from the work-area top, which is also
//   what Win32/D2D use. The `cameraNormalizedCenter` wire field is y-UP: Dart
//   writes `1.0 - dy` into it and reads it back the same way (see
//   post_processing_controller.setCameraManualCenterPreview and
//   post_camera_section._resolvedHandlePosition), and macOS consumes it
//   directly as a bottom-up CGRect. So the seed emits `1 - y`, and
//   ComputeCameraBubbleRect flips it back for D2D. Those two flips are the
//   only places this convention is applied — keep them in sync.
//
//   SIZE. The store's `size` is LOGICAL px (120..400, DPI-independent) while
//   the content rect is PHYSICAL px, so the size has to be scaled by the
//   RECORDED monitor's DPI before dividing. Skipping that silently shrinks the
//   seeded bubble on a scaled display (220/2160 = 0.10 instead of 0.20 at
//   200%), and the 0.08 clamp floor hides part of the error.
struct CameraSeedGeometry {
  // cameraLayoutPreset. Always a corner — there is no manual/custom value in
  // either enum, and an unknown string silently coerces to bottom-right on
  // both sides. Still emitted when a custom center is present, because the
  // editor falls back to it if the user clears the manual position, and
  // ResolveCameraSlideEdge reads it for the intro/outro slide direction.
  std::string layout_preset;
  // cameraNormalizedCenter, y-UP. Set ONLY when the user actually dragged the
  // bubble (use_custom): a present center OVERRIDES layout_preset everywhere
  // downstream, so emitting one unconditionally would permanently defeat the
  // corner presets.
  std::optional<double> normalized_center_x;
  std::optional<double> normalized_center_y;
  // cameraSizeFactor, a fraction of the content's SHORT edge. Clamped to the
  // same [0.08, 0.45] band ComputeCameraBubbleRect re-applies, because this
  // value is also surfaced straight to the editor's size slider.
  double size_factor = 0.18;
};

// OverlayPosition index -> CameraLayoutPreset wire name. Mirrors macOS
// CameraLayoutPreset.fromOverlayPosition: 0 topLeft, 1 topRight, 2 bottomLeft,
// anything else bottomRight.
std::string CameraLayoutPresetForOverlayPosition(int position);

// Work-area rect and content rect are both in PHYSICAL screen px (the app is
// PerMonitorV2, so every Win32 rect already is). `dpi_scale` is the RECORDED
// monitor's scale (dpi/96) — never the bubble window's, which no longer exists
// by the time the seed is built. Pure; unit-tested; no Win32 calls.
CameraSeedGeometry ResolveCameraSeedGeometry(
    const CameraOverlayGeometry& g, int work_left, int work_top,
    int work_right, int work_bottom, int content_left, int content_top,
    int content_right, int content_bottom, double dpi_scale);

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
