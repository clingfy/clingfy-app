#include "Capture/Camera/camera_meta.h"

#include <cctype>
#include <cstdlib>
#include <sstream>
#include <string>

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

// --- Phase 9.4 tolerant scalar reader. camera.meta.json is a flat object of
// scalars (plus an always-empty `segments` array we ignore). Rather than pull in
// a full JSON parser we scan for each `"key":` and read the value token. Good
// enough for our own writer's output; a structurally broken doc is rejected by
// the object-shape check in ParseCameraMetaJson before any of this runs.

bool IsWs(char ch) {
  return ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r';
}

std::string Trim(const std::string& s) {
  size_t b = 0;
  size_t e = s.size();
  while (b < e && IsWs(s[b])) ++b;
  while (e > b && IsWs(s[e - 1])) --e;
  return s.substr(b, e - b);
}

// Position just past the colon of a TOP-LEVEL (depth-1) object key named `key`,
// or npos. String-aware: a `"key":`-shaped substring inside a value string (e.g.
// a device symbolic link, which is untrusted text) is NOT mistaken for a key,
// and only keys at object depth 1 match (nested objects are skipped). This is
// the guard that keeps a crafted deviceId from flipping previewBurnedIn or
// startOffsetMs. Returns npos on an unterminated string (malformed input).
size_t ValueStart(const std::string& json, const std::string& key) {
  int depth = 0;
  const size_t n = json.size();
  size_t i = 0;
  while (i < n) {
    const char c = json[i];
    if (c == '"') {
      // Consume the whole string literal, unescaping into `content` so a key
      // comparison sees the logical name.
      std::string content;
      size_t j = i + 1;
      bool closed = false;
      while (j < n) {
        if (json[j] == '\\' && j + 1 < n) {
          content.push_back(json[j + 1]);
          j += 2;
          continue;
        }
        if (json[j] == '"') {
          closed = true;
          break;
        }
        content.push_back(json[j]);
        ++j;
      }
      if (!closed) {
        return std::string::npos;  // unterminated string → malformed
      }
      size_t after = j + 1;  // just past the closing quote
      size_t k = after;
      while (k < n && IsWs(json[k])) ++k;
      // A string immediately followed by ':' at depth 1 is an object key.
      if (depth == 1 && k < n && json[k] == ':') {
        if (content == key) {
          ++k;  // past ':'
          while (k < n && IsWs(json[k])) ++k;
          return k;
        }
      }
      i = after;  // not our key (or it's a value string) → keep scanning
      continue;
    }
    if (c == '{' || c == '[') {
      ++depth;
    } else if (c == '}' || c == ']') {
      --depth;
    }
    ++i;
  }
  return std::string::npos;
}

bool ReadString(const std::string& json, const std::string& key,
                std::string* out) {
  size_t i = ValueStart(json, key);
  if (i == std::string::npos || i >= json.size() || json[i] != '"') {
    return false;
  }
  ++i;
  std::string value;
  while (i < json.size()) {
    const char ch = json[i];
    if (ch == '\\' && i + 1 < json.size()) {
      const char next = json[i + 1];
      switch (next) {
        case 'n': value.push_back('\n'); break;
        case 'r': value.push_back('\r'); break;
        case 't': value.push_back('\t'); break;
        default: value.push_back(next); break;  // \" \\ and anything else
      }
      i += 2;
      continue;
    }
    if (ch == '"') {
      *out = value;
      return true;
    }
    value.push_back(ch);
    ++i;
  }
  return false;  // unterminated string
}

// Read the raw scalar token (number / true / false) after a key.
bool ReadScalarToken(const std::string& json, const std::string& key,
                     std::string* out) {
  size_t i = ValueStart(json, key);
  if (i == std::string::npos || i >= json.size()) {
    return false;
  }
  size_t j = i;
  while (j < json.size() && json[j] != ',' && json[j] != '}' &&
         json[j] != ']' && !IsWs(json[j])) {
    ++j;
  }
  if (j == i) {
    return false;
  }
  *out = json.substr(i, j - i);
  return true;
}

bool ReadInt64(const std::string& json, const std::string& key,
               std::int64_t* out) {
  std::string token;
  if (!ReadScalarToken(json, key, &token)) {
    return false;
  }
  errno = 0;
  char* end = nullptr;
  const long long parsed = std::strtoll(token.c_str(), &end, 10);
  if (end == token.c_str()) {
    return false;
  }
  *out = static_cast<std::int64_t>(parsed);
  return true;
}

bool ReadBool(const std::string& json, const std::string& key, bool* out) {
  std::string token;
  if (!ReadScalarToken(json, key, &token)) {
    return false;
  }
  if (token == "true") {
    *out = true;
    return true;
  }
  if (token == "false") {
    *out = false;
    return true;
  }
  return false;
}

}  // namespace

std::optional<CameraMetaFields> ParseCameraMetaJson(const std::string& json) {
  const std::string trimmed = Trim(json);
  // Reject anything that is not a JSON object — empty, truncated, or a stray
  // fragment. This is the gate the export relies on to fall back to screen-only
  // on a malformed sidecar.
  if (trimmed.size() < 2 || trimmed.front() != '{' || trimmed.back() != '}') {
    return std::nullopt;
  }

  CameraMetaFields fields;  // defaults stand in for any missing key
  std::string str;
  std::int64_t num = 0;
  bool flag = false;

  if (ReadString(trimmed, "recordingId", &str)) fields.recording_id = str;
  if (ReadString(trimmed, "deviceId", &str)) fields.device_id = str;
  if (ReadInt64(trimmed, "width", &num) && num >= 0) {
    fields.width = static_cast<std::uint32_t>(num);
  }
  if (ReadInt64(trimmed, "height", &num) && num >= 0) {
    fields.height = static_cast<std::uint32_t>(num);
  }
  if (ReadInt64(trimmed, "nominalFrameRate", &num) && num >= 0) {
    fields.fps = static_cast<std::uint32_t>(num);
  }
  if (ReadInt64(trimmed, "startOffsetMs", &num)) {
    fields.start_offset_ms = num;
  }
  if (ReadInt64(trimmed, "framesWritten", &num) && num >= 0) {
    fields.frames_written = static_cast<std::uint64_t>(num);
  }
  if (ReadBool(trimmed, "mirroredRaw", &flag)) fields.mirrored_raw = flag;
  if (ReadBool(trimmed, "deviceLost", &flag)) fields.device_lost = flag;
  if (ReadBool(trimmed, "previewBurnedIn", &flag)) {
    fields.preview_burned_in = flag;
  }
  return fields;
}

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
  out << "  \"previewBurnedIn\": "
      << (fields.preview_burned_in ? "true" : "false") << ",\n";
  // Windows uses a single raw.mov; segments stays empty for macOS parity.
  out << "  \"segments\": [],\n";
  out << "  \"platform\": \"windows\"\n";
  out << "}\n";
  return out.str();
}

}  // namespace clingfy::capture
