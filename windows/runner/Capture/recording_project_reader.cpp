#include "Capture/recording_project_reader.h"

#include <cctype>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <optional>
#include <sstream>
#include <string>
#include <variant>
#include <vector>

namespace clingfy::capture {

namespace fs = std::filesystem;

namespace {

// ---------------------------------------------------------------------
// Minimal recursive-descent JSON parser.
//
// Scope: the subset emitted by `recording_project_writer.cpp` and the
// macOS `RecordingProjectManifest` writer — objects, strings (no
// surrogate-pair `\u` escapes), numbers (int + decimal), booleans, null,
// arrays. Everything in `project.json` is one of those today, and the
// schema is bound to `schemaVersion: 2` so future shape changes get a
// loud error from the reader before they reach this parser.
//
// Trailing commas, comments, single-quoted strings: all rejected. The
// writers don't emit them.
// ---------------------------------------------------------------------

class JsonValue;
using JsonObject = std::map<std::string, JsonValue>;
using JsonArray = std::vector<JsonValue>;

class JsonValue {
 public:
  enum class Type {
    kNull,
    kBool,
    kNumber,
    kString,
    kArray,
    kObject,
  };

  JsonValue() : type_(Type::kNull) {}
  explicit JsonValue(bool b) : type_(Type::kBool), bool_(b) {}
  explicit JsonValue(double d) : type_(Type::kNumber), number_(d) {}
  explicit JsonValue(std::string s)
      : type_(Type::kString), string_(std::move(s)) {}
  explicit JsonValue(JsonArray a)
      : type_(Type::kArray), array_(std::make_unique<JsonArray>(std::move(a))) {}
  explicit JsonValue(JsonObject o)
      : type_(Type::kObject),
        object_(std::make_unique<JsonObject>(std::move(o))) {}

  Type type() const { return type_; }
  bool is_null() const { return type_ == Type::kNull; }
  bool is_bool() const { return type_ == Type::kBool; }
  bool is_number() const { return type_ == Type::kNumber; }
  bool is_string() const { return type_ == Type::kString; }
  bool is_object() const { return type_ == Type::kObject; }
  bool is_array() const { return type_ == Type::kArray; }

  bool as_bool() const { return bool_; }
  double as_number() const { return number_; }
  const std::string& as_string() const { return string_; }
  const JsonObject& as_object() const { return *object_; }
  const JsonArray& as_array() const { return *array_; }

 private:
  Type type_;
  bool bool_ = false;
  double number_ = 0.0;
  std::string string_;
  std::unique_ptr<JsonArray> array_;
  std::unique_ptr<JsonObject> object_;
};

struct ParseState {
  const char* p = nullptr;
  const char* end = nullptr;
  std::string error;
};

bool ParseValue(ParseState& s, JsonValue& out);

void SkipWs(ParseState& s) {
  while (s.p < s.end) {
    const char c = *s.p;
    if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
      ++s.p;
    } else {
      break;
    }
  }
}

bool Expect(ParseState& s, char c) {
  SkipWs(s);
  if (s.p < s.end && *s.p == c) {
    ++s.p;
    return true;
  }
  s.error = "expected '";
  s.error.push_back(c);
  s.error.append("'");
  return false;
}

bool ParseStringLiteral(ParseState& s, std::string& out) {
  SkipWs(s);
  if (s.p >= s.end || *s.p != '"') {
    s.error = "expected string";
    return false;
  }
  ++s.p;
  out.clear();
  while (s.p < s.end) {
    const char c = *s.p++;
    if (c == '"') return true;
    if (c == '\\') {
      if (s.p >= s.end) {
        s.error = "string ended after backslash";
        return false;
      }
      const char esc = *s.p++;
      switch (esc) {
        case '"':  out.push_back('"');  break;
        case '\\': out.push_back('\\'); break;
        case '/':  out.push_back('/');  break;
        case 'b':  out.push_back('\b'); break;
        case 'f':  out.push_back('\f'); break;
        case 'n':  out.push_back('\n'); break;
        case 'r':  out.push_back('\r'); break;
        case 't':  out.push_back('\t'); break;
        case 'u': {
          // Hex escape — pass through unchanged for now (the manifests
          // we read don't use these). Reject if there aren't 4 hex
          // chars so we don't silently truncate; consume them and emit
          // a `?` placeholder so the rest of the string still parses.
          if (s.end - s.p < 4) {
            s.error = "\\u escape needs 4 hex digits";
            return false;
          }
          for (int i = 0; i < 4; ++i) {
            const char h = s.p[i];
            const bool is_hex = (h >= '0' && h <= '9') ||
                                (h >= 'a' && h <= 'f') ||
                                (h >= 'A' && h <= 'F');
            if (!is_hex) {
              s.error = "\\u escape contains non-hex character";
              return false;
            }
          }
          s.p += 4;
          out.push_back('?');
          break;
        }
        default:
          s.error = std::string("unknown escape \\") + esc;
          return false;
      }
    } else {
      out.push_back(c);
    }
  }
  s.error = "string was not terminated";
  return false;
}

bool ParseNumber(ParseState& s, double& out) {
  SkipWs(s);
  const char* start = s.p;
  if (s.p < s.end && *s.p == '-') ++s.p;
  while (s.p < s.end && std::isdigit(static_cast<unsigned char>(*s.p))) ++s.p;
  if (s.p < s.end && *s.p == '.') {
    ++s.p;
    while (s.p < s.end && std::isdigit(static_cast<unsigned char>(*s.p))) ++s.p;
  }
  if (s.p < s.end && (*s.p == 'e' || *s.p == 'E')) {
    ++s.p;
    if (s.p < s.end && (*s.p == '+' || *s.p == '-')) ++s.p;
    while (s.p < s.end && std::isdigit(static_cast<unsigned char>(*s.p))) ++s.p;
  }
  if (s.p == start) {
    s.error = "expected number";
    return false;
  }
  try {
    out = std::stod(std::string(start, s.p - start));
  } catch (...) {
    s.error = "number didn't parse as double";
    return false;
  }
  return true;
}

bool ParseLiteral(ParseState& s, const char* word) {
  SkipWs(s);
  const std::size_t n = std::char_traits<char>::length(word);
  if (s.end - s.p < static_cast<std::ptrdiff_t>(n)) return false;
  if (std::char_traits<char>::compare(s.p, word, n) != 0) return false;
  s.p += n;
  return true;
}

bool ParseObject(ParseState& s, JsonValue& out) {
  if (!Expect(s, '{')) return false;
  JsonObject obj;
  SkipWs(s);
  if (s.p < s.end && *s.p == '}') {
    ++s.p;
    out = JsonValue(std::move(obj));
    return true;
  }
  while (true) {
    std::string key;
    if (!ParseStringLiteral(s, key)) return false;
    if (!Expect(s, ':')) return false;
    JsonValue value;
    if (!ParseValue(s, value)) return false;
    obj.emplace(std::move(key), std::move(value));
    SkipWs(s);
    if (s.p < s.end && *s.p == ',') {
      ++s.p;
      continue;
    }
    if (Expect(s, '}')) {
      out = JsonValue(std::move(obj));
      return true;
    }
    return false;
  }
}

bool ParseArray(ParseState& s, JsonValue& out) {
  if (!Expect(s, '[')) return false;
  JsonArray arr;
  SkipWs(s);
  if (s.p < s.end && *s.p == ']') {
    ++s.p;
    out = JsonValue(std::move(arr));
    return true;
  }
  while (true) {
    JsonValue v;
    if (!ParseValue(s, v)) return false;
    arr.push_back(std::move(v));
    SkipWs(s);
    if (s.p < s.end && *s.p == ',') {
      ++s.p;
      continue;
    }
    if (Expect(s, ']')) {
      out = JsonValue(std::move(arr));
      return true;
    }
    return false;
  }
}

bool ParseValue(ParseState& s, JsonValue& out) {
  SkipWs(s);
  if (s.p >= s.end) {
    s.error = "unexpected end of input";
    return false;
  }
  const char c = *s.p;
  if (c == '{') return ParseObject(s, out);
  if (c == '[') return ParseArray(s, out);
  if (c == '"') {
    std::string str;
    if (!ParseStringLiteral(s, str)) return false;
    out = JsonValue(std::move(str));
    return true;
  }
  if (c == '-' || (c >= '0' && c <= '9')) {
    double n = 0.0;
    if (!ParseNumber(s, n)) return false;
    out = JsonValue(n);
    return true;
  }
  if (ParseLiteral(s, "true"))  { out = JsonValue(true);  return true; }
  if (ParseLiteral(s, "false")) { out = JsonValue(false); return true; }
  if (ParseLiteral(s, "null"))  { out = JsonValue();      return true; }
  s.error = "unexpected token";
  return false;
}

bool ParseJson(const std::string& text, JsonValue& root, std::string& err) {
  ParseState s;
  s.p = text.data();
  s.end = text.data() + text.size();
  if (!ParseValue(s, root)) {
    err = s.error.empty() ? std::string("parse failed") : s.error;
    return false;
  }
  SkipWs(s);
  if (s.p != s.end) {
    err = "trailing content after top-level value";
    return false;
  }
  return true;
}

// ---------------------------------------------------------------------
// JsonObject access helpers.
// ---------------------------------------------------------------------

const JsonValue* GetField(const JsonObject& obj, const std::string& key) {
  auto it = obj.find(key);
  return it == obj.end() ? nullptr : &it->second;
}

std::optional<std::string> GetStringField(const JsonObject& obj,
                                          const std::string& key) {
  const auto* v = GetField(obj, key);
  if (v == nullptr || !v->is_string()) return std::nullopt;
  return v->as_string();
}

std::optional<double> GetNumberField(const JsonObject& obj,
                                     const std::string& key) {
  const auto* v = GetField(obj, key);
  if (v == nullptr || !v->is_number()) return std::nullopt;
  return v->as_number();
}

std::optional<bool> GetBoolField(const JsonObject& obj,
                                 const std::string& key) {
  const auto* v = GetField(obj, key);
  if (v == nullptr || !v->is_bool()) return std::nullopt;
  return v->as_bool();
}

const JsonObject* GetObjectField(const JsonObject& obj,
                                 const std::string& key) {
  const auto* v = GetField(obj, key);
  if (v == nullptr || !v->is_object()) return nullptr;
  return &v->as_object();
}

// Parse the `editorSeed` object (macOS `EditorSeed` on-disk keys) into a
// CameraEditorSeed. Every field is tolerant: a missing / wrong-typed key keeps
// the struct default, so a partial or forward-compatible block still yields a
// usable seed. ARGB values arrive as JSON numbers (e.g. 4294967295) and are
// narrowed to uint32; they fit exactly in a double.
CameraEditorSeed ParseEditorSeed(const JsonObject& obj) {
  CameraEditorSeed s;
  if (auto v = GetBoolField(obj, "cameraVisible"); v) s.visible = *v;
  if (auto v = GetStringField(obj, "cameraLayoutPreset"); v)
    s.layout_preset = *v;
  if (const JsonObject* c = GetObjectField(obj, "cameraNormalizedCenter"); c) {
    if (auto x = GetNumberField(*c, "x"); x) s.normalized_center_x = *x;
    if (auto y = GetNumberField(*c, "y"); y) s.normalized_center_y = *y;
  }
  if (auto v = GetNumberField(obj, "cameraSizeFactor"); v) s.size_factor = *v;
  if (auto v = GetStringField(obj, "cameraShape"); v) s.shape = *v;
  if (auto v = GetNumberField(obj, "cameraCornerRadius"); v)
    s.corner_radius = *v;
  if (auto v = GetNumberField(obj, "cameraBorderWidth"); v) s.border_width = *v;
  if (auto v = GetNumberField(obj, "cameraBorderColorArgb"); v)
    s.border_color_argb = static_cast<std::uint32_t>(*v);
  if (auto v = GetNumberField(obj, "cameraShadow"); v)
    s.shadow_preset = static_cast<int>(*v);
  if (auto v = GetNumberField(obj, "cameraOpacity"); v) s.opacity = *v;
  if (auto v = GetBoolField(obj, "cameraMirror"); v) s.mirror = *v;
  if (auto v = GetStringField(obj, "cameraContentMode"); v)
    s.content_mode = *v;
  if (auto v = GetStringField(obj, "cameraZoomBehavior"); v)
    s.zoom_behavior = *v;
  if (auto v = GetNumberField(obj, "cameraZoomScaleMultiplier"); v)
    s.zoom_scale_multiplier = *v;
  if (auto v = GetStringField(obj, "cameraIntroPreset"); v)
    s.intro_preset = *v;
  if (auto v = GetStringField(obj, "cameraOutroPreset"); v)
    s.outro_preset = *v;
  if (auto v = GetStringField(obj, "cameraZoomEmphasisPreset"); v)
    s.zoom_emphasis_preset = *v;
  if (auto v = GetNumberField(obj, "cameraIntroDurationMs"); v)
    s.intro_duration_ms = static_cast<int>(*v);
  if (auto v = GetNumberField(obj, "cameraOutroDurationMs"); v)
    s.outro_duration_ms = static_cast<int>(*v);
  if (auto v = GetNumberField(obj, "cameraZoomEmphasisStrength"); v)
    s.zoom_emphasis_strength = *v;
  if (auto v = GetBoolField(obj, "cameraChromaKeyEnabled"); v)
    s.chroma_key_enabled = *v;
  if (auto v = GetNumberField(obj, "cameraChromaKeyStrength"); v)
    s.chroma_key_strength = *v;
  if (auto v = GetNumberField(obj, "cameraChromaKeyColorArgb"); v)
    s.chroma_key_color_argb = static_cast<std::uint32_t>(*v);
  return s;
}

// ---------------------------------------------------------------------
// Filesystem helpers.
// ---------------------------------------------------------------------

bool ReadEntireFile(const fs::path& path, std::string& out) {
  std::ifstream in(path, std::ios::in | std::ios::binary);
  if (!in.is_open()) return false;
  std::ostringstream ss;
  ss << in.rdbuf();
  out = ss.str();
  return true;
}

// Join `project_root / relative` from a manifest value and normalize
// the result to native separators. The manifest's `capture.screenVideo`
// etc. always store forward-slashed POSIX-style paths; std::filesystem
// reads them fine on Windows but downstream consumers (texture bridge,
// MediaPlayer URI conversion, logs) get cleaner output when separators
// are uniform — `make_preferred()` flips '/' to '\\' on Windows and is
// a no-op on other platforms.
std::wstring JoinAndStringify(const fs::path& project_root,
                              const std::string& relative_utf8) {
  fs::path joined = project_root / fs::u8path(relative_utf8);
  joined.make_preferred();
  return joined.wstring();
}

bool FileExists(const std::wstring& wpath) {
  std::error_code ec;
  return fs::exists(fs::path(wpath), ec) &&
         fs::is_regular_file(fs::path(wpath), ec);
}

}  // namespace

// ---------------------------------------------------------------------
// Manifest parsing — exposed for tests.
// ---------------------------------------------------------------------

ReadResult ParseManifestJson(const std::string& manifest_json) {
  ReadResult result;
  JsonValue root;
  std::string err;
  if (!ParseJson(manifest_json, root, err)) {
    result.error = ReadError::kManifestInvalidJson;
    result.message = "project.json did not parse: " + err;
    return result;
  }
  if (!root.is_object()) {
    result.error = ReadError::kManifestInvalidJson;
    result.message = "project.json top-level value is not an object";
    return result;
  }
  const auto& obj = root.as_object();

  const auto schema_v = GetNumberField(obj, "schemaVersion");
  if (!schema_v.has_value()) {
    result.error = ReadError::kSchemaVersionMismatch;
    result.message = "project.json is missing schemaVersion";
    return result;
  }
  const int schema = static_cast<int>(*schema_v);
  if (schema != 2) {
    result.error = ReadError::kSchemaVersionMismatch;
    result.message = "project.json has unsupported schemaVersion=" +
                     std::to_string(schema) + " (reader requires 2)";
    return result;
  }

  // Phase 10.4: openable-status gate (macOS ProjectOpenValidator parity).
  // Missing status → "ready" so pre-10.4 bundles keep opening; unknown
  // values fail closed.
  std::string status = "ready";
  if (const auto status_field = GetStringField(obj, "status"); status_field) {
    status = *status_field;
  }
  const bool openable =
      status == "ready" || status == "cancelled" || status == "failed";
  if (!openable) {
    result.error = ReadError::kProjectNotOpenable;
    result.message =
        "project status is not openable: " + status;
    return result;
  }

  RecordingProject project;
  project.schema_version = schema;
  project.status = status;
  result.project = std::move(project);
  // Tests only care about schema_version/status + the kNone status. The
  // full reader fills the path fields against a real filesystem.
  return result;
}

// ---------------------------------------------------------------------
// Recovery-sweep status probe (Phase 10.4) — tolerant by design.
// ---------------------------------------------------------------------

ManifestStatusProbe ProbeManifestStatus(const std::string& manifest_json) {
  ManifestStatusProbe probe;
  JsonValue root;
  std::string err;
  if (!ParseJson(manifest_json, root, err) || !root.is_object()) {
    return probe;
  }
  const auto& obj = root.as_object();
  probe.parsed = true;
  if (const auto status = GetStringField(obj, "status"); status) {
    probe.status = *status;
  }
  if (const auto id = GetStringField(obj, "projectId"); id) {
    probe.project_id = *id;
  }
  if (const auto pid = GetNumberField(obj, "ownerPid"); pid && *pid > 0) {
    probe.owner_pid = static_cast<std::uint32_t>(*pid);
  }
  return probe;
}

// ---------------------------------------------------------------------
// screen.meta.json parsing — exposed for tests.
// ---------------------------------------------------------------------

std::optional<RecordingMetadata> ParseScreenMetaJson(
    const std::string& meta_json) {
  JsonValue root;
  std::string err;
  if (!ParseJson(meta_json, root, err)) return std::nullopt;
  if (!root.is_object()) return std::nullopt;
  const auto& obj = root.as_object();
  RecordingMetadata m;
  if (auto v = GetNumberField(obj, "width"); v)
    m.width = static_cast<std::uint32_t>(*v);
  if (auto v = GetNumberField(obj, "height"); v)
    m.height = static_cast<std::uint32_t>(*v);
  if (auto v = GetNumberField(obj, "fps"); v)
    m.fps = static_cast<std::uint32_t>(*v);
  if (auto v = GetNumberField(obj, "framesReceived"); v)
    m.frames_received = static_cast<std::uint64_t>(*v);
  if (auto v = GetNumberField(obj, "framesDropped"); v)
    m.frames_dropped = static_cast<std::uint64_t>(*v);
  if (auto v = GetNumberField(obj, "audioSamplesWritten"); v)
    m.audio_samples_written = static_cast<std::uint64_t>(*v);
  if (auto v = GetBoolField(obj, "micActive"); v) m.mic_active = *v;
  if (auto v = GetBoolField(obj, "loopbackActive"); v) m.loopback_active = *v;
  if (auto v = GetStringField(obj, "platform"); v) m.platform = *v;
  // Phase 5.2: the recording-time camera composition. Absent on older Windows
  // bundles (empty optional → scene-info omits the `camera` key → Dart hidden).
  if (const JsonObject* seed = GetObjectField(obj, "editorSeed"); seed) {
    m.editor_seed = ParseEditorSeed(*seed);
  }
  return m;
}

// ---------------------------------------------------------------------
// Full reader — resolves paths against the filesystem.
// ---------------------------------------------------------------------

ReadResult ReadRecordingProject(const std::wstring& project_path) {
  ReadResult result;

  if (project_path.empty()) {
    result.error = ReadError::kBundleNotFound;
    result.message = "project_path is empty";
    return result;
  }

  const fs::path root_path = fs::path(project_path);
  std::error_code ec;
  if (!fs::exists(root_path, ec) || !fs::is_directory(root_path, ec)) {
    result.error = ReadError::kBundleNotFound;
    result.message = "project path does not exist or is not a directory";
    return result;
  }

  const fs::path manifest_path = root_path / "project.json";
  if (!fs::exists(manifest_path, ec) ||
      !fs::is_regular_file(manifest_path, ec)) {
    result.error = ReadError::kBundleNotFound;
    result.message = "project.json not found inside bundle";
    return result;
  }

  std::string manifest_text;
  if (!ReadEntireFile(manifest_path, manifest_text)) {
    result.error = ReadError::kBundleNotFound;
    result.message = "project.json could not be read";
    return result;
  }

  // Parse + validate schema.
  ReadResult parsed = ParseManifestJson(manifest_text);
  if (parsed.error != ReadError::kNone) return parsed;

  // Re-parse to access the structured contents (ParseManifestJson
  // currently surfaces only schema; reading the manifest body here is
  // cheaper than threading the JsonValue through the public API).
  JsonValue root;
  std::string err;
  if (!ParseJson(manifest_text, root, err) || !root.is_object()) {
    result.error = ReadError::kManifestInvalidJson;
    result.message = "project.json re-parse failed: " + err;
    return result;
  }
  const auto& obj = root.as_object();

  RecordingProject project;
  project.project_path = root_path.wstring();
  project.schema_version = 2;
  // ParseManifestJson above already enforced the openable gate; carry the
  // accepted status through (defaulting matches the gate's tolerance).
  if (const auto status_field = GetStringField(obj, "status"); status_field) {
    project.status = *status_field;
  }

  // capture/screen* paths — required.
  const JsonObject* capture = GetObjectField(obj, "capture");
  if (capture == nullptr) {
    result.error = ReadError::kRequiredFileMissing;
    result.message = "manifest has no `capture` block";
    return result;
  }
  const auto screen_video_rel = GetStringField(*capture, "screenVideo");
  const auto screen_meta_rel = GetStringField(*capture, "screenMetadata");
  if (!screen_video_rel.has_value() || !screen_meta_rel.has_value()) {
    result.error = ReadError::kRequiredFileMissing;
    result.message =
        "manifest `capture` block missing screenVideo / screenMetadata";
    return result;
  }
  project.screen_path = JoinAndStringify(root_path, *screen_video_rel);
  project.screen_metadata_path =
      JoinAndStringify(root_path, *screen_meta_rel);
  if (!FileExists(project.screen_path)) {
    result.error = ReadError::kRequiredFileMissing;
    result.message = "required file missing: capture/" + *screen_video_rel;
    return result;
  }
  if (!FileExists(project.screen_metadata_path)) {
    result.error = ReadError::kRequiredFileMissing;
    result.message = "required file missing: capture/" + *screen_meta_rel;
    return result;
  }

  // Optional capture-side assets — silently absent.
  if (const auto rel = GetStringField(*capture, "cursorData"); rel) {
    auto p = JoinAndStringify(root_path, *rel);
    if (FileExists(p)) project.cursor_path = std::move(p);
  }
  if (const auto rel = GetStringField(*capture, "zoomManual"); rel) {
    auto p = JoinAndStringify(root_path, *rel);
    if (FileExists(p)) project.zoom_manual_path = std::move(p);
  }

  // Camera assets — present-together-or-not-at-all.
  if (const JsonObject* camera = GetObjectField(obj, "camera");
      camera != nullptr) {
    const auto raw_rel = GetStringField(*camera, "rawVideo");
    const auto meta_rel = GetStringField(*camera, "metadata");
    if (raw_rel.has_value() && meta_rel.has_value()) {
      const auto raw_path = JoinAndStringify(root_path, *raw_rel);
      const auto meta_path = JoinAndStringify(root_path, *meta_rel);
      const bool raw_exists = FileExists(raw_path);
      const bool meta_exists = FileExists(meta_path);
      if (raw_exists && meta_exists) {
        project.camera_video_path = raw_path;
        project.camera_metadata_path = meta_path;
      } else if (raw_exists != meta_exists) {
        result.error = ReadError::kRequiredFileMissing;
        result.message =
            std::string("camera assets present-together-or-not-at-all violated; ") +
            (raw_exists ? "raw exists but metadata missing"
                        : "metadata exists but raw missing");
        return result;
      }
      // else: neither exists → leave optionals empty, no error.
    }
  }

  // Parse screen.meta.json. Failure is non-fatal — metadata stays empty.
  std::string meta_text;
  if (ReadEntireFile(fs::path(project.screen_metadata_path), meta_text)) {
    project.metadata = ParseScreenMetaJson(meta_text);
  }

  result.project = std::move(project);
  return result;
}

}  // namespace clingfy::capture
