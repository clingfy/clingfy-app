#include "Encoding/encoder_output_path.h"

#include <cstdlib>
#include <utility>

namespace clingfy::encoding {

namespace {

bool IsSafeChar(char ch) {
  return (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') ||
         (ch >= '0' && ch <= '9') || ch == '.' || ch == '-' || ch == '_';
}

// Trailing slash trim so the join below always emits exactly one
// separator between the directory and the filename, regardless of
// whether the user's `%TEMP%` ends with `\` or `/`.
std::string TrimTrailingSlash(std::string value) {
  while (!value.empty() &&
         (value.back() == '\\' || value.back() == '/')) {
    value.pop_back();
  }
  return value;
}

// Resolve the temp directory (override → %TEMP% → %TMP% → fallback), trimmed.
std::string ResolveTempDir(const std::string& temp_dir_override) {
  std::string temp_dir;
  if (!temp_dir_override.empty()) {
    temp_dir = temp_dir_override;
  } else {
#ifdef _WIN32
    auto read_env = [](const char* name) -> std::string {
      char* value = nullptr;
      size_t size = 0;
      if (_dupenv_s(&value, &size, name) == 0 && value != nullptr) {
        std::string out(value);
        free(value);
        return out;
      }
      return {};
    };
    temp_dir = read_env("TEMP");
    if (temp_dir.empty()) {
      temp_dir = read_env("TMP");
    }
    if (temp_dir.empty()) {
      temp_dir = "C:\\Windows\\Temp";
    }
#else
    temp_dir = "/tmp";
#endif
  }
  return TrimTrailingSlash(std::move(temp_dir));
}

// Join `<temp>/clingfy_<sanitized><suffix>`.
std::string JoinTempClingfyFile(const std::string& temp_dir,
                                const std::string& sanitized,
                                const char* suffix) {
  std::string out;
  out.reserve(temp_dir.size() + 1 + 8 + sanitized.size() + 16);
  out.append(temp_dir);
#ifdef _WIN32
  out.push_back('\\');
#else
  out.push_back('/');
#endif
  out.append("clingfy_");
  out.append(sanitized);
  out.append(suffix);
  return out;
}

}  // namespace

std::string SanitizeSessionId(const std::string& session_id) {
  std::string out;
  out.reserve(session_id.size());
  for (char ch : session_id) {
    out.push_back(IsSafeChar(ch) ? ch : '_');
  }
  if (out.empty()) {
    return "session";
  }
  return out;
}

std::string ResolveTempMp4Path(const std::string& session_id,
                               const std::string& temp_dir_override) {
  // `%TEMP%` is the canonical Windows temp directory; the fallbacks (`%TMP%`,
  // `C:\Windows\Temp`) and `_dupenv_s` (MSVC-safe getenv; the bridge is /WX) are
  // in `ResolveTempDir`.
  const std::string temp_dir = ResolveTempDir(temp_dir_override);
  return JoinTempClingfyFile(temp_dir, SanitizeSessionId(session_id), ".mp4");
}

std::string ResolveTempCursorSidecarPath(const std::string& session_id,
                                         const std::string& temp_dir_override) {
  const std::string temp_dir = ResolveTempDir(temp_dir_override);
  return JoinTempClingfyFile(temp_dir, SanitizeSessionId(session_id),
                             ".cursor.jsonl");
}

std::string ResolveTempCameraRawPath(const std::string& session_id,
                                     const std::string& temp_dir_override) {
  const std::string temp_dir = ResolveTempDir(temp_dir_override);
  return JoinTempClingfyFile(temp_dir, SanitizeSessionId(session_id),
                             ".camera.mp4");
}

}  // namespace clingfy::encoding
