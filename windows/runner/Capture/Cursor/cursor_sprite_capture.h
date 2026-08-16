#ifndef RUNNER_CAPTURE_CURSOR_CURSOR_SPRITE_CAPTURE_H_
#define RUNNER_CAPTURE_CURSOR_CURSOR_SPRITE_CAPTURE_H_

#include <windows.h>

#include <cstdint>
#include <map>
#include <string>
#include <vector>

#include "Capture/Cursor/cursor_base64.h"

// Record-time cursor SHAPE capture.
//
// The export used to draw one hardcoded arrow polygon for every recording, so
// an I-beam over text, a pointing hand over a link and a resize cursor on a
// window edge all rendered as the same white arrow. macOS has always captured
// the real bitmap; this is the Windows equivalent.
//
// RECORD-TIME ONLY, and that is the whole reason it lives here rather than in
// the export: `GetCursorInfo` hands back an HCURSOR that is only meaningful
// while the recording is happening. Nothing can backfill shapes for a
// recording already on disk — those keep the arrow fallback forever, which is
// why the export renderer must retain it rather than replace it.
//
// DEDUPED BY HANDLE. A cursor shape is a system resource with a stable handle
// for the life of the process that owns it, so a 60 Hz sampler sees the same
// HCURSOR thousands of times. Rasterizing once per unique handle keeps the
// sidecar small and the sampler cheap.
namespace clingfy::capture {

// One rasterized cursor shape. `pixels` is premultiplied BGRA, top-down, with
// no row padding — the layout Direct2D wants, so the export can upload it with
// no conversion.
struct CursorSprite {
  int id = -1;
  std::int32_t width = 0;
  std::int32_t height = 0;
  // The point INSIDE the sprite that sits at the reported cursor position (the
  // arrow's tip, an I-beam's middle). Drawing at the position without
  // subtracting this puts every non-arrow cursor visibly off by up to its own
  // size.
  std::int32_t hotspot_x = 0;
  std::int32_t hotspot_y = 0;
  std::vector<std::uint8_t> pixels;  // width * height * 4
};

// Rasterize one cursor handle. Returns false when the handle is null or any of
// the GDI steps fail — the caller then records no shape for that sample and the
// export falls back to the arrow.
//
// Handles BOTH cursor kinds:
//   * COLOUR cursors (hbmColor set) — the common case, already 32-bit BGRA.
//   * MONOCHROME cursors (hbmColor null) — the classic I-beam and resize
//     shapes. Their AND and XOR masks are stacked in ONE bitmap of double
//     height, and the two combine to give transparent / black / white /
//     INVERTED pixels. Getting this wrong is not subtle: the shape comes out
//     as a solid black box.
bool RasterizeCursor(HCURSOR cursor, CursorSprite* out);

// Caches rasterized shapes by handle so each unique cursor is converted once.
class CursorSpriteCache {
 public:
  // Returns the sprite id for `cursor`, rasterizing on first sight. `is_new`
  // (optional) reports whether this call produced a new sprite, so the caller
  // knows it must be written to the sidecar before any sample references it.
  // Returns -1 when the cursor could not be rasterized.
  int IdFor(HCURSOR cursor, bool* is_new, CursorSprite* out_sprite);

  size_t size() const { return by_handle_.size(); }

 private:
  std::map<HCURSOR, int> by_handle_;
  // Handles that failed to rasterize, so a broken cursor is not retried 60
  // times a second for the rest of the recording.
  std::map<HCURSOR, bool> failed_;
  int next_id_ = 0;
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CURSOR_CURSOR_SPRITE_CAPTURE_H_
