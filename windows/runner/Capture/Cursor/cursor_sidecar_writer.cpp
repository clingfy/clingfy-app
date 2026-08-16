#include "Capture/Cursor/cursor_sidecar_writer.h"

#include <sstream>
#include <utility>

namespace clingfy::capture {

namespace {

// Conservative JSON string escape — only the characters JSON forbids. The only
// caller-influenced string is `targetType` ("display"/"window"/"area"), but
// escape defensively so a future field cannot break the line.
std::string JsonEscape(const std::string& value) {
  std::string out;
  out.reserve(value.size() + 2);
  for (char c : value) {
    switch (c) {
      case '\\': out += "\\\\"; break;
      case '"': out += "\\\""; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (static_cast<unsigned char>(c) < 0x20) {
          char buf[8];
          std::snprintf(buf, sizeof(buf), "\\u%04x",
                        static_cast<unsigned int>(c));
          out += buf;
        } else {
          out += c;
        }
    }
  }
  return out;
}

}  // namespace

CursorSidecarWriter::~CursorSidecarWriter() { Close(); }

bool CursorSidecarWriter::Open(const std::string& path, const Header& header) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (open_) {
    return false;
  }
  out_.open(path, std::ios::binary | std::ios::trunc);
  if (!out_.is_open()) {
    return false;
  }
  std::ostringstream line;
  line << "{\"type\":\"header\",\"schemaVersion\":" << header.schema_version
       << ",\"sampleRateHz\":" << header.sample_rate_hz
       << ",\"targetType\":\"" << JsonEscape(header.target_type) << "\""
       << ",\"width\":" << header.width << ",\"height\":" << header.height
       << ",\"originX\":" << header.origin_x
       << ",\"originY\":" << header.origin_y << "}\n";
  const std::string text = line.str();
  out_.write(text.data(), static_cast<std::streamsize>(text.size()));
  out_.flush();
  if (!out_.good()) {
    out_.close();
    return false;
  }
  open_ = true;
  return true;
}

void CursorSidecarWriter::WriteSample(std::int64_t t_ms, std::int32_t screen_x,
                                      std::int32_t screen_y, std::int32_t x,
                                      std::int32_t y, bool visible,
                                      int sprite_id) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!open_) {
    return;
  }
  std::ostringstream line;
  line << "{\"type\":\"sample\",\"tMs\":" << t_ms << ",\"screenX\":" << screen_x
       << ",\"screenY\":" << screen_y << ",\"x\":" << x << ",\"y\":" << y
       << ",\"visible\":" << (visible ? "true" : "false");
  // Omitted rather than written as -1 when there is no shape, so a v1 reader
  // sees exactly the line it always saw and a v2 file stays smaller.
  if (sprite_id >= 0) {
    line << ",\"spriteId\":" << sprite_id;
  }
  line << "}\n";
  const std::string text = line.str();
  out_.write(text.data(), static_cast<std::streamsize>(text.size()));
  out_.flush();
}

void CursorSidecarWriter::WriteSprite(int id, std::int32_t width,
                                      std::int32_t height,
                                      std::int32_t hotspot_x,
                                      std::int32_t hotspot_y,
                                      const std::string& pixels_base64) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!open_) {
    return;
  }
  std::ostringstream line;
  line << "{\"type\":\"sprite\",\"id\":" << id << ",\"width\":" << width
       << ",\"height\":" << height << ",\"hotspotX\":" << hotspot_x
       << ",\"hotspotY\":" << hotspot_y << ",\"pixels\":\"" << pixels_base64
       << "\"}\n";
  const std::string text = line.str();
  out_.write(text.data(), static_cast<std::streamsize>(text.size()));
  out_.flush();
}

void CursorSidecarWriter::WriteClick(std::int64_t t_ms, std::int32_t screen_x,
                                     std::int32_t screen_y, const char* button,
                                     bool down) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!open_) {
    return;
  }
  std::ostringstream line;
  line << "{\"type\":\"click\",\"tMs\":" << t_ms << ",\"screenX\":" << screen_x
       << ",\"screenY\":" << screen_y << ",\"button\":\""
       << (button != nullptr ? button : "left") << "\",\"action\":\""
       << (down ? "down" : "up") << "\"}\n";
  const std::string text = line.str();
  out_.write(text.data(), static_cast<std::streamsize>(text.size()));
  out_.flush();
}

void CursorSidecarWriter::Flush() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (open_) {
    out_.flush();
  }
}

void CursorSidecarWriter::Close() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (open_) {
    out_.flush();
    out_.close();
    open_ = false;
  }
}

bool CursorSidecarWriter::is_open() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return open_;
}

}  // namespace clingfy::capture
