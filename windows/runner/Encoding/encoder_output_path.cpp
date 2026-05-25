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
  std::string temp_dir;
  if (!temp_dir_override.empty()) {
    temp_dir = temp_dir_override;
  } else {
#ifdef _WIN32
    // `%TEMP%` is the canonical Windows temp directory environment
    // variable; fall back to `%TMP%` and finally `C:\Windows\Temp` so we
    // never produce an empty path. `_dupenv_s` is the MSVC-safe variant
    // of getenv (the bridge is built with /WX so the deprecated getenv
    // warning would fail the build); we free the duplicated buffer
    // before the function returns.
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

  temp_dir = TrimTrailingSlash(std::move(temp_dir));
  const std::string sanitized = SanitizeSessionId(session_id);
  std::string out;
  out.reserve(temp_dir.size() + 1 + 9 + sanitized.size() + 4);
  out.append(temp_dir);
#ifdef _WIN32
  out.push_back('\\');
#else
  out.push_back('/');
#endif
  out.append("clingfy_");
  out.append(sanitized);
  out.append(".mp4");
  return out;
}

}  // namespace clingfy::encoding
