#include "Capture/Camera/camera_meta.h"

#include <sstream>

namespace clingfy::capture {

namespace {

// Minimal JSON string escaping for the handful of fields that can contain
// arbitrary text (recordingId, deviceId). Symbolic links contain backslashes,
// which MUST be escaped or the manifest reader's JSON parser chokes.
std::string JsonEscape(const std::string& value) {
  std::string out;
  out.reserve(value.size() + 8);
  for (const char ch : value) {
    switch (ch) {
      case '"':
        out += "\\\"";
        break;
      case '\\':
        out += "\\\\";
        break;
      case '\n':
        out += "\\n";
        break;
      case '\r':
        out += "\\r";
        break;
      case '\t':
        out += "\\t";
        break;
      default:
        out.push_back(ch);
        break;
    }
  }
  return out;
}

}  // namespace

std::string BuildCameraMetaJson(const CameraMetaFields& fields) {
  std::ostringstream out;
  out << "{\n";
  out << "  \"version\": 1,\n";
  out << "  \"recordingId\": \"" << JsonEscape(fields.recording_id) << "\",\n";
  out << "  \"rawRelativePath\": \"camera/raw.mov\",\n";
  out << "  \"metadataRelativePath\": \"camera/camera.meta.json\",\n";
  out << "  \"deviceId\": \"" << JsonEscape(fields.device_id) << "\",\n";
  out << "  \"width\": " << fields.width << ",\n";
  out << "  \"height\": " << fields.height << ",\n";
  out << "  \"nominalFrameRate\": " << fields.fps << ",\n";
  out << "  \"startOffsetMs\": " << fields.start_offset_ms << ",\n";
  out << "  \"framesWritten\": " << fields.frames_written << ",\n";
  out << "  \"mirroredRaw\": " << (fields.mirrored_raw ? "true" : "false")
      << ",\n";
  out << "  \"deviceLost\": " << (fields.device_lost ? "true" : "false")
      << ",\n";
  // Windows uses a single raw.mov; segments stays empty for macOS parity.
  out << "  \"segments\": [],\n";
  out << "  \"platform\": \"windows\"\n";
  out << "}\n";
  return out.str();
}

}  // namespace clingfy::capture
