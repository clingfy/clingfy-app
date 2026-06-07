#include "Capture/Cursor/cursor_sidecar_reader.h"

#include <algorithm>
#include <cctype>
#include <cerrno>
#include <cstdlib>
#include <sstream>

namespace clingfy::capture {

namespace {

// Index just past `"key":` in `line`, or npos. The quoted key guards against
// substring collisions ("x" vs "screenX": the leading quote means `"x":` never
// matches inside `"screenX":`).
std::size_t FindValuePos(const std::string& line, const char* key) {
  std::string needle = "\"";
  needle += key;
  needle += "\":";
  const std::size_t p = line.find(needle);
  if (p == std::string::npos) {
    return std::string::npos;
  }
  std::size_t v = p + needle.size();
  while (v < line.size() && (line[v] == ' ' || line[v] == '\t')) {
    ++v;
  }
  return v;
}

bool FindIntField(const std::string& line, const char* key, std::int64_t* out) {
  std::size_t p = FindValuePos(line, key);
  if (p == std::string::npos) {
    return false;
  }
  const std::size_t start = p;
  if (p < line.size() && (line[p] == '-' || line[p] == '+')) {
    ++p;
  }
  const std::size_t first_digit = p;
  while (p < line.size() &&
         std::isdigit(static_cast<unsigned char>(line[p])) != 0) {
    ++p;
  }
  if (p == first_digit) {
    return false;  // no digits
  }
  errno = 0;
  const long long value =
      std::strtoll(line.substr(start, p - start).c_str(), nullptr, 10);
  if (errno == ERANGE) {
    return false;  // out-of-range garbage → treat the field as absent (skip).
  }
  *out = value;
  return true;
}

bool FindBoolField(const std::string& line, const char* key, bool* out) {
  const std::size_t p = FindValuePos(line, key);
  if (p == std::string::npos) {
    return false;
  }
  if (line.compare(p, 4, "true") == 0) {
    *out = true;
    return true;
  }
  if (line.compare(p, 5, "false") == 0) {
    *out = false;
    return true;
  }
  return false;
}

bool FindStringField(const std::string& line, const char* key,
                     std::string* out) {
  const std::size_t p = FindValuePos(line, key);
  if (p == std::string::npos || p >= line.size() || line[p] != '"') {
    return false;
  }
  const std::size_t begin = p + 1;
  const std::size_t end = line.find('"', begin);
  if (end == std::string::npos) {
    return false;
  }
  *out = line.substr(begin, end - begin);
  return true;
}

}  // namespace

std::optional<CursorSidecarData> ParseCursorSidecar(const std::string& jsonl) {
  CursorSidecarData data;
  bool have_header = false;

  std::istringstream stream(jsonl);
  std::string line;
  while (std::getline(stream, line)) {
    // Tolerate CRLF: getline strips '\n' but leaves a trailing '\r' if the file
    // round-tripped through a text-mode copy / git autocrlf. Drop it so the
    // last field on a line parses cleanly.
    if (!line.empty() && line.back() == '\r') {
      line.pop_back();
    }
    // A truncated final line (no trailing newline) is still returned by getline
    // and simply fails the field probes below — graceful.
    std::string type;
    if (!FindStringField(line, "type", &type)) {
      continue;
    }
    if (type == "header") {
      std::int64_t w = 0;
      std::int64_t h = 0;
      if (FindIntField(line, "width", &w)) data.width = static_cast<std::int32_t>(w);
      if (FindIntField(line, "height", &h)) data.height = static_cast<std::int32_t>(h);
      FindStringField(line, "targetType", &data.target_type);
      have_header = true;
    } else if (type == "sample") {
      std::int64_t t = 0;
      std::int64_t x = 0;
      std::int64_t y = 0;
      bool vis = false;
      if (!FindIntField(line, "tMs", &t) || !FindIntField(line, "x", &x) ||
          !FindIntField(line, "y", &y)) {
        continue;  // malformed sample line — skip.
      }
      FindBoolField(line, "visible", &vis);
      CursorSidecarSample sample;
      sample.t_ms = t;
      sample.x = static_cast<std::int32_t>(x);
      sample.y = static_cast<std::int32_t>(y);
      sample.visible = vis;
      data.samples.push_back(sample);
    }
    // "click" and unknown line types are ignored in 8.2.
  }

  if (!have_header) {
    return std::nullopt;
  }
  std::stable_sort(data.samples.begin(), data.samples.end(),
                   [](const CursorSidecarSample& a,
                      const CursorSidecarSample& b) { return a.t_ms < b.t_ms; });
  return data;
}

CursorAtResult SampleCursorAt(const std::vector<CursorSidecarSample>& samples,
                              std::int64_t t_ms) {
  CursorAtResult result;
  if (samples.empty()) {
    return result;  // has = false
  }
  result.has = true;

  auto use = [&result](const CursorSidecarSample& s) {
    result.x = static_cast<double>(s.x);
    result.y = static_cast<double>(s.y);
    result.visible = s.visible;
  };

  if (t_ms <= samples.front().t_ms) {
    use(samples.front());
    return result;
  }
  if (t_ms >= samples.back().t_ms) {
    use(samples.back());
    return result;
  }

  // First sample with t_ms >= target. Guaranteed in (begin, end) by the clamps.
  const auto it = std::lower_bound(
      samples.begin(), samples.end(), t_ms,
      [](const CursorSidecarSample& s, std::int64_t t) { return s.t_ms < t; });
  const CursorSidecarSample& hi = *it;
  if (hi.t_ms == t_ms) {
    use(hi);
    return result;
  }
  const CursorSidecarSample& lo = *(it - 1);
  if (lo.visible && hi.visible && hi.t_ms != lo.t_ms) {
    const double f = static_cast<double>(t_ms - lo.t_ms) /
                     static_cast<double>(hi.t_ms - lo.t_ms);
    result.x = static_cast<double>(lo.x) +
               (static_cast<double>(hi.x) - static_cast<double>(lo.x)) * f;
    result.y = static_cast<double>(lo.y) +
               (static_cast<double>(hi.y) - static_cast<double>(lo.y)) * f;
    result.visible = true;
  } else {
    // Never interpolate across a visibility boundary — snap to nearest in time.
    use((t_ms - lo.t_ms <= hi.t_ms - t_ms) ? lo : hi);
  }
  return result;
}

CursorPlacement ResolveCursorPlacement(double capture_x, double capture_y,
                                       double content_x, double content_y,
                                       double content_w, double content_h,
                                       double source_w, double source_h,
                                       double cursor_size) {
  CursorPlacement out;
  const double sx = source_w > 0.0 ? content_w / source_w : 0.0;
  const double sy = source_h > 0.0 ? content_h / source_h : 0.0;
  out.canvas_x = content_x + capture_x * sx;
  out.canvas_y = content_y + capture_y * sy;
  // The glyph (defined in ~capture px) scales with the content, times the user
  // multiplier — matches macOS `cursorSize * videoToTargetScale`.
  out.glyph_scale = cursor_size * sx;
  return out;
}

}  // namespace clingfy::capture
