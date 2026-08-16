#ifndef RUNNER_CAPTURE_CURSOR_CURSOR_SIDECAR_READER_H_
#define RUNNER_CAPTURE_CURSOR_CURSOR_SIDECAR_READER_H_

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

// Phase 8.2 — pure reader for the `cursor.jsonl` sidecar produced in 8.1, plus
// time interpolation. Used by the export cursor renderer to look up the cursor
// position at each frame's timestamp. Pure (no Win32 / no D2D) so the parse +
// interpolation are unit-tested against literal jsonl text.
//
// Tolerant by design: a malformed / truncated line is skipped, unknown line
// types (e.g. "click") are ignored, and a missing/headerless file yields
// std::nullopt so the caller renders no cursor rather than failing the export.
namespace clingfy::capture {

struct CursorSidecarSample {
  std::int64_t t_ms = 0;     // recording-time ms (pause-aware), sorted ascending.
  std::int32_t x = 0;        // capture-local px (same space as the encoded frame).
  std::int32_t y = 0;
  bool visible = false;
  // Which recorded SHAPE this sample was drawn with; -1 when the recording
  // carries none (anything captured before shapes existed, or a cursor that
  // failed to rasterize). The export falls back to its vector arrow there,
  // which is why that arrow cannot simply be deleted.
  int sprite_id = -1;
};

// One recorded cursor shape. `pixels` is premultiplied BGRA, top-down, exactly
// width*height*4 bytes — the layout Direct2D consumes directly.
struct CursorSidecarSprite {
  int id = -1;
  std::int32_t width = 0;
  std::int32_t height = 0;
  // The point inside the sprite that sits at the reported position. Drawing
  // without subtracting it puts every non-arrow cursor off by up to its own
  // size — most visible on an I-beam, whose hotspot is its middle.
  std::int32_t hotspot_x = 0;
  std::int32_t hotspot_y = 0;
  std::vector<std::uint8_t> pixels;
};

// A recorded click edge (Phase 8.1 writes press + release; Phase 8.3 smart zoom
// uses the timestamps to decide when to zoom). Button/down are kept for 8.4.
struct CursorSidecarClick {
  std::int64_t t_ms = 0;
};

struct CursorSidecarData {
  std::int32_t width = 0;    // header capture dims (informational).
  std::int32_t height = 0;
  std::string target_type;   // "display" | "window" | "area".
  std::vector<CursorSidecarSample> samples;  // sorted by t_ms.
  std::vector<CursorSidecarClick> clicks;    // sorted by t_ms.
  // Recorded shapes, indexed by their id (sprites[i].id == i for a file this
  // app wrote). Empty for every recording made before shapes were captured.
  std::vector<CursorSidecarSprite> sprites;
};

// Parse the full `cursor.jsonl` contents. Returns std::nullopt when the header
// line is missing/unparseable (the caller then renders no cursor). Sample lines
// that fail to parse are skipped; `click` and unknown lines are ignored.
std::optional<CursorSidecarData> ParseCursorSidecar(const std::string& jsonl);

struct CursorAtResult {
  bool has = false;   // false only when there are no samples at all.
  double x = 0.0;
  double y = 0.0;
  bool visible = false;
  // The recorded shape in effect at this time, or -1 for the fallback
  // arrow. Never interpolated: a shape is discrete.
  int sprite_id = -1;
};

// Resolve the cursor position at `t_ms`. Before the first / after the last sample
// clamps to it. Between two samples: linearly interpolate position when BOTH are
// visible (smooth motion), else snap to the nearest-in-time sample (never
// interpolate across a visibility boundary). Pure + testable.
CursorAtResult SampleCursorAt(const std::vector<CursorSidecarSample>& samples,
                              std::int64_t t_ms);

// Where + how big to draw the cursor glyph on the export canvas. Pure so the
// mapping (shared by display/window/area — the sidecar x,y are already
// capture-local) and the cursorSize scaling are unit-tested without D2D.
struct CursorPlacement {
  double canvas_x = 0.0;    // glyph hotspot (arrow tip) position on the canvas.
  double canvas_y = 0.0;
  double glyph_scale = 0.0;  // cursor-units → canvas px (cursorSize * content scale).
};

// Map a capture-local cursor point into the export content rect. The content rect
// is the source frame placed/scaled on the canvas (`export_geometry`), so the
// cursor scales + positions exactly like the video pixels under it.
// `cursor_size` is the user multiplier (0.5..3.0).
CursorPlacement ResolveCursorPlacement(double capture_x, double capture_y,
                                       double content_x, double content_y,
                                       double content_w, double content_h,
                                       double source_w, double source_h,
                                       double cursor_size);

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CURSOR_CURSOR_SIDECAR_READER_H_
