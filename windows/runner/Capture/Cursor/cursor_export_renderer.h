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

  bool ready() const { return ready_; }

 private:
  CursorExportRenderer() = default;

  CursorSidecarData data_;
  Microsoft::WRL::ComPtr<ID2D1PathGeometry> arrow_;
  Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> fill_brush_;
  Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> stroke_brush_;
  bool ready_ = false;
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CURSOR_CURSOR_EXPORT_RENDERER_H_
