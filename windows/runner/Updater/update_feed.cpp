#include "Updater/update_feed.h"

#include <cerrno>
#include <cstdlib>

namespace clingfy::updater {

namespace {

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

// Position just past the colon of a TOP-LEVEL (depth-1) object key named
// `key`, or npos. Same string- and depth-aware scan as camera_meta.cpp's
// ValueStart (Phase 9.4 review hardening): a `"key":`-shaped substring
// inside a VALUE string is not mistaken for a key, and nested objects are
// skipped. Returns npos on an unterminated string (malformed input).
size_t ValueStart(const std::string& json, const std::string& key) {
  int depth = 0;
  const size_t n = json.size();
  size_t i = 0;
  while (i < n) {
    const char c = json[i];
    if (c == '"') {
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
        return std::string::npos;
      }
      size_t after = j + 1;
      size_t k = after;
      while (k < n && IsWs(json[k])) ++k;
      if (depth == 1 && k < n && json[k] == ':') {
        if (content == key) {
          ++k;
          while (k < n && IsWs(json[k])) ++k;
          return k;
        }
      }
      i = after;
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
        default: value.push_back(next); break;
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
  return false;
}

bool ReadInt64(const std::string& json, const std::string& key,
               std::int64_t* out) {
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
  const std::string token = json.substr(i, j - i);
  errno = 0;
  char* end = nullptr;
  const long long parsed = std::strtoll(token.c_str(), &end, 10);
  if (end == token.c_str() || *end != '\0' || errno == ERANGE) {
    // ERANGE: strtoll saturated (e.g. a 25-digit "build") — reject as
    // malformed instead of treating LLONG_MAX as a real build number.
    return false;
  }
  *out = static_cast<std::int64_t>(parsed);
  return true;
}

bool IsHttpsUrl(const std::string& url) {
  static constexpr char kPrefix[] = "https://";
  static constexpr size_t kPrefixLen = sizeof(kPrefix) - 1;
  return url.size() > kPrefixLen && url.compare(0, kPrefixLen, kPrefix) == 0;
}

}  // namespace

std::string SanitizeForEvent(const std::string& input, size_t max_len) {
  std::string out;
  out.reserve(input.size() < max_len ? input.size() : max_len);
  size_t i = 0;
  const size_t n = input.size();
  while (i < n && out.size() < max_len) {
    const unsigned char c = static_cast<unsigned char>(input[i]);
    if (c < 0x80) {
      out.push_back(static_cast<char>(c));
      ++i;
      continue;
    }
    // Determine the expected sequence length from the lead byte; 0xC0/0xC1
    // (overlong) and > 0xF4 (beyond U+10FFFF) are invalid leads.
    size_t len = 0;
    if (c >= 0xC2 && c <= 0xDF) len = 2;
    else if (c >= 0xE0 && c <= 0xEF) len = 3;
    else if (c >= 0xF0 && c <= 0xF4) len = 4;
    bool ok = len > 0 && i + len <= n;
    if (ok) {
      const unsigned char c1 = static_cast<unsigned char>(input[i + 1]);
      // Tight second-byte ranges kill overlong encodings and surrogate
      // halves (0xED 0xA0.. is what a strict decoder rejects).
      if (c == 0xE0) ok = c1 >= 0xA0 && c1 <= 0xBF;
      else if (c == 0xED) ok = c1 >= 0x80 && c1 <= 0x9F;
      else if (c == 0xF0) ok = c1 >= 0x90 && c1 <= 0xBF;
      else if (c == 0xF4) ok = c1 >= 0x80 && c1 <= 0x8F;
      else ok = (c1 & 0xC0) == 0x80;
      for (size_t j = 2; ok && j < len; ++j) {
        ok = (static_cast<unsigned char>(input[i + j]) & 0xC0) == 0x80;
      }
    }
    if (ok) {
      if (out.size() + len > max_len) {
        break;  // never split a multi-byte character at the cap
      }
      out.append(input, i, len);
      i += len;
    } else {
      out.push_back('?');
      ++i;
    }
  }
  return out;
}

UpdateFeed ParseUpdateFeed(const std::string& json) {
  UpdateFeed feed;
  const std::string trimmed = Trim(json);
  if (trimmed.size() < 2 || trimmed.front() != '{' || trimmed.back() != '}') {
    return feed;  // parsed stays false
  }
  feed.parsed = true;

  std::string str;
  std::int64_t num = 0;
  if (ReadString(trimmed, "version", &str)) feed.version = str;
  if (ReadInt64(trimmed, "build", &num)) feed.build = num;
  if (ReadString(trimmed, "versionFull", &str)) feed.version_full = str;
  if (ReadString(trimmed, "channel", &str)) feed.channel = str;
  if (ReadString(trimmed, "platform", &str)) feed.platform = str;
  if (ReadString(trimmed, "url", &str)) feed.url = str;
  if (ReadString(trimmed, "sha256", &str)) feed.sha256 = str;
  if (ReadInt64(trimmed, "sizeBytes", &num)) feed.size_bytes = num;
  if (ReadString(trimmed, "publishedAt", &str)) feed.published_at = str;
  return feed;
}

std::optional<AppVersion> ParseVersionString(const std::string& version) {
  AppVersion out;
  int parts[3] = {0, 0, 0};
  size_t i = 0;
  for (int p = 0; p < 3; ++p) {
    if (i >= version.size() || version[i] < '0' || version[i] > '9') {
      return std::nullopt;
    }
    long value = 0;
    while (i < version.size() && version[i] >= '0' && version[i] <= '9') {
      value = value * 10 + (version[i] - '0');
      if (value > 1000000) {
        return std::nullopt;  // absurd segment -> malformed
      }
      ++i;
    }
    parts[p] = static_cast<int>(value);
    if (p < 2) {
      if (i >= version.size() || version[i] != '.') {
        return std::nullopt;
      }
      ++i;  // past '.'
    }
  }
  if (i != version.size()) {
    return std::nullopt;  // trailing garbage ("1.0.4-beta", "1.0.4.2")
  }
  out.major = parts[0];
  out.minor = parts[1];
  out.patch = parts[2];
  out.build = 0;
  return out;
}

bool FeedIsNewer(const AppVersion& feed, const AppVersion& current) {
  if (feed.major != current.major) return feed.major > current.major;
  if (feed.minor != current.minor) return feed.minor > current.minor;
  if (feed.patch != current.patch) return feed.patch > current.patch;
  return feed.build > current.build;
}

UpdateDecision EvaluateUpdateFeed(const UpdateFeed& feed,
                                  const std::string& expected_channel,
                                  const AppVersion& current) {
  UpdateDecision decision;
  if (!feed.parsed) {
    decision.action = UpdateDecision::Action::kError;
    decision.code = codes::kFeedMalformed;
    decision.message = "Update feed is not a JSON object.";
    return decision;
  }
  if (!feed.platform.empty() && feed.platform != "windows-x64") {
    decision.action = UpdateDecision::Action::kError;
    decision.code = codes::kFeedMismatch;
    decision.message = "Update feed platform '" + feed.platform +
                       "' is not windows-x64.";
    return decision;
  }
  if (!expected_channel.empty() && !feed.channel.empty() &&
      feed.channel != expected_channel) {
    decision.action = UpdateDecision::Action::kError;
    decision.code = codes::kFeedMismatch;
    decision.message = "Update feed channel '" + feed.channel +
                       "' does not match this build's channel '" +
                       expected_channel + "'.";
    return decision;
  }
  const std::optional<AppVersion> feed_version =
      ParseVersionString(feed.version);
  if (!feed_version.has_value()) {
    decision.action = UpdateDecision::Action::kError;
    decision.code = codes::kFeedMalformed;
    decision.message = "Update feed version '" + feed.version +
                       "' is not a x.y.z version.";
    return decision;
  }
  AppVersion candidate = *feed_version;
  candidate.build = feed.build >= 0 ? feed.build : 0;

  if (!FeedIsNewer(candidate, current)) {
    decision.action = UpdateDecision::Action::kNoUpdate;
    return decision;
  }
  if (!IsHttpsUrl(feed.url)) {
    decision.action = UpdateDecision::Action::kError;
    decision.code = codes::kUrlMissing;
    decision.message =
        feed.url.empty()
            ? "Update feed advertises a newer version but has no download URL."
            : "Update feed download URL is not https.";
    return decision;
  }
  decision.action = UpdateDecision::Action::kUpdateAvailable;
  return decision;
}

}  // namespace clingfy::updater
