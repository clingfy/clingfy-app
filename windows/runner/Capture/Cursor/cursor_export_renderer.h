#ifndef RUNNER_CAPTURE_CURSOR_CURSOR_EXPORT_RENDERER_H_
#define RUNNER_CAPTURE_CURSOR_CURSOR_EXPORT_RENDERER_H_

#include <d2d1_1.h>
#include <wrl/client.h>

#include <cstdint>
#include <memory>
#include <string>

#include "Capture/Cursor/cursor_sidecar_reader.h"

// Phase 8.2 — draws the cursor sidecar back into the export composite.
//
// The recording is cursorless (8.1 strips the OS cursor); this renders the
// cursor at export time so showCursor / cursorSize stay editable. Sprite-accurate
// shapes (capturing the real per-frame cursor bitmap) are deferred — 8.2 draws a
// standard vector arrow (white fill + dark outline, tip = hotspot), which avoids
// fragile GDI/alpha cursor extraction and renders identically everywhere. The
// cursor position comes from the sidecar, interpolated at each frame's timestamp,
// mapped into the content rect exactly like the video pixels under it.
//
// All failures are soft: a missing / malformed sidecar or a brush/geometry
// failure yields no cursor (never a failed export).
namespace clingfy::capture {

// Phase 8.4: progress (0..1) of a click ripple at `frame_ms`, or -1 when the
// click is not animating (before it, or past `ripple_ms` after it). Pure +
// testable. The ripple's location is the cursor position at the click time (you
// click where the cursor is), so a click line only needs its timestamp.
double ClickRippleProgress(std::int64_t click_t_ms, std::int64_t frame_ms,
                           std::int64_t ripple_ms);

class CursorExportRenderer {
 public:
  // Load + parse the sidecar. Returns nullptr when the file is missing or
  // unparseable — the caller then renders no cursor and the export proceeds.
  static std::unique_ptr<CursorExportRenderer> Create(
      const std::wstring& sidecar_path);

  // Build the arrow geometry + brushes on this device. Returns false if they
  // could not be created (the caller then skips cursor drawing). Call once.
  bool Prepare(ID2D1Factory1* factory, ID2D1DeviceContext* ctx);

  // Draw the cursor for a frame presented at `frame_ms` (recording-relative ms),
  // clipped by the caller to the content rect. No-op when the cursor is hidden at
  // that time, Prepare failed, or there are no samples.
  void Draw(ID2D1DeviceContext* ctx, std::int64_t frame_ms,
            const D2D1_RECT_F& content_rect, double source_w, double source_h,
            double cursor_size);

  // Phase 8.4: draw an expanding/fading ring at each recently-clicked point
  // (the cursor position at the click time), under the caller's current
  // transform (so it stays aligned with the cursor + smart zoom). No-op when
  // there are no clicks. Call after Draw, inside the same clip/zoom transform.
  void DrawClicks(ID2D1DeviceContext* ctx, std::int64_t frame_ms,
                  const D2D1_RECT_F& content_rect, double source_w,
                  double source_h);

  bool ready() const { return ready_; }

 private:
  CursorExportRenderer() = default;

  CursorSidecarData data_;
  Microsoft::WRL::ComPtr<ID2D1PathGeometry> arrow_;
  Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> fill_brush_;
  Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> stroke_brush_;
  Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> ripple_brush_;  // click animation
  bool ready_ = false;
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CURSOR_CURSOR_EXPORT_RENDERER_H_
