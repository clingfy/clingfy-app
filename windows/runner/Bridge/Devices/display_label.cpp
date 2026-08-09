#include "Bridge/Devices/display_label.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <numeric>

namespace clingfy::bridge::devices {

namespace {

// ASCII-only lowercase. Monitor model names that matter here are ASCII, and a
// locale-sensitive tolower would be a portability hazard under /W4 /WX.
std::string AsciiLower(const std::string& value) {
  std::string out;
  out.reserve(value.size());
  for (const char ch : value) {
    out.push_back(static_cast<char>(
        std::tolower(static_cast<unsigned char>(ch))));
  }
  return out;
}

bool IsSpace(char ch) {
  return std::isspace(static_cast<unsigned char>(ch)) != 0;
}

}  // namespace

std::vector<std::size_t> OrderedIndices(const std::vector<OrderingInput>& in) {
  std::vector<std::size_t> order(in.size());
  std::iota(order.begin(), order.end(), std::size_t{0});
  std::stable_sort(order.begin(), order.end(),
                   [&in](std::size_t lhs, std::size_t rhs) {
                     const OrderingInput& a = in[lhs];
                     const OrderingInput& b = in[rhs];
                     if (a.x != b.x) {
                       return a.x < b.x;
                     }
                     if (a.y != b.y) {
                       return a.y < b.y;
                     }
                     return a.id < b.id;
                   });
  return order;
}

bool IsGenericMonitorName(const std::string& utf8) {
  const std::string normalized = AsciiLower(NormalizeMonitorName(utf8));
  if (normalized.empty()) {
    return true;
  }
  static const std::array<const char*, 6> kGeneric = {
      "display",
      "unknown",
      "unknown display",
      "generic pnp monitor",
      "generic non-pnp monitor",
      "default monitor",
  };
  for (const char* candidate : kGeneric) {
    if (normalized == candidate) {
      return true;
    }
  }
  return false;
}

std::string NormalizeMonitorName(const std::string& utf8) {
  std::string out;
  out.reserve(utf8.size());
  bool pending_space = false;
  for (const char ch : utf8) {
    if (IsSpace(ch)) {
      // Only emit a separator once we know real content follows, which trims
      // both ends and collapses internal runs in one pass.
      pending_space = !out.empty();
      continue;
    }
    if (pending_space) {
      out.push_back(' ');
      pending_space = false;
    }
    out.push_back(ch);
  }
  return out;
}

std::string ComposeDisplayName(const std::string& os_name,
                               std::int64_t ordinal,
                               const std::string& screen_word) {
  const std::string base =
      os_name.empty() ? (screen_word.empty() ? std::string("Screen")
                                             : screen_word)
                      : os_name;
  return std::to_string(ordinal) + ". " + base;
}

}  // namespace clingfy::bridge::devices
