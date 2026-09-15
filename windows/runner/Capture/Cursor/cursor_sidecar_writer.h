#ifndef RUNNER_CAPTURE_CURSOR_CURSOR_SIDECAR_WRITER_H_
#define RUNNER_CAPTURE_CURSOR_CURSOR_SIDECAR_WRITER_H_

#include <cstdint>
#include <fstream>
#include <mutex>
#include <string>

// Phase 8.1 — streaming cursor sidecar writer (`cursor.jsonl`).
//
// One JSON object per line, written incrementally during recording so a crash /
// target-loss mid-recording still yields a valid file up to the last flushed
// line (aligns with Phase 7.4 keep-the-partial). Layout:
//   line 1   {"type":"header", schemaVersion, sampleRateHz, targetType, width,
//             height, originX, originY}
//   samples  {"type":"sample", tMs, screenX, screenY, x, y, visible}
//   clicks   {"type":"click",  tMs, screenX, screenY, button, action}
//
// `x,y` are capture-local physical px (top-left origin) matching the encoded
// frame; `screenX,screenY` are the raw virtual-desktop px (kept for debugging /
// re-mapping). Cursor SHAPE (sprite) lines are deferred to Phase 8.2 — extraction
// is record-time-only, so 8.2 adds it to the sampler then.
//
// File I/O only (no Win32 / no GPU): unit-testable by pointing at a temp path.
namespace clingfy::capture {

class CursorSidecarWriter {
 public:
  struct Header {
    int schema_version = 1;
    int sample_rate_hz = 60;
    std::string target_type = "display";  // "display" | "window" | "area"
    std::int32_t width = 0;
    std::int32_t height = 0;
    std::int32_t origin_x = 0;  // capture-region top-left in screen px at start
    std::int32_t origin_y = 0;
  };

  CursorSidecarWriter() = default;
  ~CursorSidecarWriter();

  CursorSidecarWriter(const CursorSidecarWriter&) = delete;
  CursorSidecarWriter& operator=(const CursorSidecarWriter&) = delete;

  // Open the file (truncating) and write the header line. Returns false if the
  // file could not be opened — the caller then keeps the Phase 7 cursor-on
  // fallback.
  bool Open(const std::string& path, const Header& header);

  // Append one sample / click line and flush (small lines; flush keeps the file
  // crash-robust). No-ops when not open.
  // `sprite_id` names the shape this sample was drawn with, or -1 when none
  // was captured (an older recording, or a cursor that failed to rasterize).
  // The key is OMITTED from the line when -1, so a v1 reader sees exactly the
  // line it always saw.
  void WriteSample(std::int64_t t_ms, std::int32_t screen_x,
                   std::int32_t screen_y, std::int32_t x, std::int32_t y,
                   bool visible, int sprite_id = -1);

  // Emit one cursor SHAPE. Must be written BEFORE any sample referencing it —
  // the reader resolves ids against sprites it has already seen, and a
  // forward reference would silently render as no shape.
  //
  // `pixels_base64` is premultiplied BGRA, top-down, width*height*4 bytes.
  void WriteSprite(int id, std::int32_t width, std::int32_t height,
                   std::int32_t hotspot_x, std::int32_t hotspot_y,
                   const std::string& pixels_base64);
  // `button` is "left" | "right" | "middle"; `down` true = press, false =
  // release.
  void WriteClick(std::int64_t t_ms, std::int32_t screen_x,
                  std::int32_t screen_y, const char* button, bool down);

  void Flush();
  void Close();
  bool is_open() const;

 private:
  mutable std::mutex mutex_;
  std::ofstream out_;
  bool open_ = false;
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CURSOR_CURSOR_SIDECAR_WRITER_H_
