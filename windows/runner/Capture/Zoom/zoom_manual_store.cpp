#include "Capture/Zoom/zoom_manual_store.h"

#include <windows.h>

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <fstream>
#include <set>
#include <sstream>

namespace clingfy::capture {

namespace {

// A deliberately small, total scanner for the ONE shape this file has:
// `{"version":2,"segments":[{...},{...}]}` with string and integer fields.
//
// It is not a general JSON parser and does not pretend to be. It walks the
// text looking for the keys it knows, ignores everything else, and never
// throws. Anything it cannot make sense of yields no segment rather than an
// error — see the header on why losing an edit beats refusing to open a
// project.
//
// (There is a fuller hand-rolled parser inside recording_project_reader.cpp.
// It lives in an anonymous namespace and would need a ~400-line extraction to
// share, which does not belong in the same change as this feature. Worth
// consolidating once something needs a third reader.)
class Scanner {
 public:
  explicit Scanner(const std::string& text) : s_(text) {}

  void SkipWs() {
    while (i_ < s_.size() && std::isspace(static_cast<unsigned char>(s_[i_]))) {
      ++i_;
    }
  }

  bool Eof() const { return i_ >= s_.size(); }
  char Peek() const { return i_ < s_.size() ? s_[i_] : '\0'; }
  void Advance() {
    if (i_ < s_.size()) ++i_;
  }

  // Read a double-quoted string with the escapes the writers can emit.
  bool ReadString(std::string* out) {
    SkipWs();
    if (Peek() != '"') return false;
    Advance();
    std::string value;
    while (!Eof()) {
      const char c = s_[i_++];
      if (c == '"') {
        *out = value;
        return true;
      }
      if (c == '\\' && i_ < s_.size()) {
        const char esc = s_[i_++];
        switch (esc) {
          case 'n': value.push_back('\n'); break;
          case 't': value.push_back('\t'); break;
          case 'r': value.push_back('\r'); break;
          case 'b': value.push_back('\b'); break;
          case 'f': value.push_back('\f'); break;
          case 'u': {
            // Only the BMP escapes a path or id could realistically carry;
            // anything longer is skipped rather than mis-decoded.
            if (i_ + 4 <= s_.size()) i_ += 4;
            value.push_back('?');
            break;
          }
          default: value.push_back(esc); break;
        }
        continue;
      }
      value.push_back(c);
    }
    return false;  // unterminated
  }

  bool ReadInt(std::int64_t* out) {
    SkipWs();
    const size_t start = i_;
    if (Peek() == '-' || Peek() == '+') Advance();
    while (!Eof() && std::isdigit(static_cast<unsigned char>(Peek()))) {
      Advance();
    }
    if (i_ == start) return false;
    // A fractional part is tolerated and truncated: Dart can hand back a
    // double for a whole number.
    if (Peek() == '.') {
      Advance();
      while (!Eof() && std::isdigit(static_cast<unsigned char>(Peek()))) {
        Advance();
      }
    }
    try {
      *out = static_cast<std::int64_t>(std::stod(s_.substr(start, i_ - start)));
    } catch (...) {
      return false;
    }
    return true;
  }

  size_t pos() const { return i_; }
  void set_pos(size_t p) { i_ = p; }

 private:
  const std::string& s_;
  size_t i_ = 0;
};

// Consume one `{...}` object, filling whichever known keys appear.
bool ReadSegmentObject(Scanner& sc, ZoomManualSegment* out) {
  sc.SkipWs();
  if (sc.Peek() != '{') return false;
  sc.Advance();

  bool has_start = false;
  bool has_end = false;
  while (!sc.Eof()) {
    sc.SkipWs();
    if (sc.Peek() == '}') {
      sc.Advance();
      break;
    }
    if (sc.Peek() == ',') {
      sc.Advance();
      continue;
    }
    std::string key;
    if (!sc.ReadString(&key)) {
      return false;
    }
    sc.SkipWs();
    if (sc.Peek() != ':') return false;
    sc.Advance();
    sc.SkipWs();

    if (key == "startMs" || key == "endMs") {
      std::int64_t value = 0;
      if (!sc.ReadInt(&value)) return false;
      if (key == "startMs") {
        out->start_ms = value;
        has_start = true;
      } else {
        out->end_ms = value;
        has_end = true;
      }
      continue;
    }
    if (key == "id" || key == "source" || key == "baseId") {
      // `null` is legal for the optional strings.
      if (sc.Peek() == 'n') {
        for (int k = 0; k < 4 && !sc.Eof(); ++k) sc.Advance();
        continue;
      }
      std::string value;
      if (!sc.ReadString(&value)) return false;
      if (key == "id") out->id = value;
      else if (key == "source") out->source = value;
      else out->base_id = value;
      continue;
    }
    // Unknown key: skip its value. Only scalars appear in this schema, so a
    // bounded scan to the next delimiter is enough.
    if (sc.Peek() == '"') {
      std::string ignored;
      if (!sc.ReadString(&ignored)) return false;
    } else {
      while (!sc.Eof() && sc.Peek() != ',' && sc.Peek() != '}') sc.Advance();
    }
  }
  // A segment without both bounds is not a segment. Dropping it is safer than
  // inventing a zero-length one, which would read as a tombstone.
  return has_start && has_end;
}

void AppendEscaped(std::string* out, const std::string& value) {
  for (const char c : value) {
    switch (c) {
      case '"': *out += "\\\""; break;
      case '\\': *out += "\\\\"; break;
      case '\n': *out += "\\n"; break;
      case '\r': *out += "\\r"; break;
      case '\t': *out += "\\t"; break;
      default: out->push_back(c); break;
    }
  }
}

}  // namespace

std::vector<ZoomManualSegment> ParseZoomManualJson(const std::string& bytes) {
  std::vector<ZoomManualSegment> out;
  const size_t segments_key = bytes.find("\"segments\"");
  if (segments_key == std::string::npos) {
    return out;
  }
  Scanner sc(bytes);
  sc.set_pos(segments_key + 10);
  sc.SkipWs();
  if (sc.Peek() != ':') return out;
  sc.Advance();
  sc.SkipWs();
  if (sc.Peek() != '[') return out;
  sc.Advance();

  while (!sc.Eof()) {
    sc.SkipWs();
    if (sc.Peek() == ']') break;
    if (sc.Peek() == ',') {
      sc.Advance();
      continue;
    }
    ZoomManualSegment segment;
    if (!ReadSegmentObject(sc, &segment)) {
      break;  // malformed from here on — keep whatever parsed cleanly
    }
    if (segment.source.empty()) {
      segment.source = "manual";
    }
    out.push_back(std::move(segment));
  }
  return out;
}

std::string SerializeZoomManualJson(
    const std::vector<ZoomManualSegment>& segments) {
  std::string out = "{\"version\":2,\"segments\":[";
  bool first = true;
  for (const ZoomManualSegment& s : segments) {
    if (!first) out += ",";
    first = false;
    out += "{\"id\":\"";
    AppendEscaped(&out, s.id);
    out += "\",\"startMs\":" + std::to_string(s.start_ms);
    out += ",\"endMs\":" + std::to_string(s.end_ms);
    out += ",\"source\":\"";
    AppendEscaped(&out, s.source.empty() ? std::string("manual") : s.source);
    out += "\"";
    if (!s.base_id.empty()) {
      out += ",\"baseId\":\"";
      AppendEscaped(&out, s.base_id);
      out += "\"";
    }
    out += "}";
  }
  out += "]}";
  return out;
}

std::vector<ZoomSegment> MergeZoomSegments(
    const std::vector<ZoomSegment>& auto_segments,
    const std::vector<ZoomManualSegment>& manual_segments) {
  // Every auto id any manual segment claims to replace — INCLUDING those
  // claimed by tombstones, which is exactly how a deletion is expressed.
  std::set<std::string> overridden;
  for (const ZoomManualSegment& s : manual_segments) {
    if (!s.base_id.empty()) {
      overridden.insert(s.base_id);
    }
  }

  std::vector<ZoomSegment> out;
  for (const ZoomManualSegment& s : manual_segments) {
    if (IsZoomTombstone(s)) {
      continue;  // carries a baseId and nothing else; never rendered
    }
    out.push_back(ZoomSegment{s.start_ms, s.end_ms});
  }
  // Auto ids are POSITIONAL and must match what getZoomSegments handed Dart,
  // or the user's "delete auto_3" would remove a different segment.
  for (size_t i = 0; i < auto_segments.size(); ++i) {
    if (overridden.count("auto_" + std::to_string(i)) > 0) {
      continue;
    }
    out.push_back(auto_segments[i]);
  }
  std::sort(out.begin(), out.end(),
            [](const ZoomSegment& a, const ZoomSegment& b) {
              if (a.start_ms != b.start_ms) return a.start_ms < b.start_ms;
              return a.end_ms < b.end_ms;
            });
  return out;
}

std::wstring ZoomManualSidecarPath(const std::wstring& project_path) {
  if (project_path.empty()) {
    return {};
  }
  std::wstring path = project_path;
  if (path.back() != L'\\' && path.back() != L'/') {
    path += L'\\';
  }
  return path + L"capture\\zoom.manual.json";
}

std::vector<ZoomManualSegment> LoadZoomManualSegments(
    const std::wstring& project_path) {
  const std::wstring path = ZoomManualSidecarPath(project_path);
  if (path.empty()) {
    return {};
  }
  std::ifstream file(path, std::ios::binary);
  if (!file.is_open()) {
    return {};  // no manual edits yet — the common case, not an error
  }
  std::ostringstream buffer;
  buffer << file.rdbuf();
  return ParseZoomManualJson(buffer.str());
}

bool SaveZoomManualSegments(const std::wstring& project_path,
                            const std::vector<ZoomManualSegment>& segments) {
  const std::wstring path = ZoomManualSidecarPath(project_path);
  if (path.empty()) {
    return false;
  }
  const std::string json = SerializeZoomManualJson(segments);
  // Write to a temp file and move it into place, so an interrupted save
  // cannot leave a half-written sidecar that parses as "the user deleted
  // everything".
  const std::wstring temp = path + L".tmp";
  {
    std::ofstream file(temp, std::ios::binary | std::ios::trunc);
    if (!file.is_open()) {
      return false;
    }
    file.write(json.data(), static_cast<std::streamsize>(json.size()));
    if (!file.good()) {
      return false;
    }
  }
  if (::MoveFileExW(temp.c_str(), path.c_str(),
                    MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) == 0) {
    ::DeleteFileW(temp.c_str());
    return false;
  }
  return true;
}

}  // namespace clingfy::capture
