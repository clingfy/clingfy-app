#include "Bridge/Routers/clip_args.h"

#include <cstdint>
#include <string>

namespace clingfy::bridge {

namespace {

// int-or-double → int64, truncating (matches the macOS `intValue` helper and
// the §5.1 truncate-never-round rule). Anything else → 0.
std::int64_t Int64OrZero(const flutter::EncodableMap& map, const char* key) {
  const auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it == map.end()) return 0;
  if (const auto* i32 = std::get_if<std::int32_t>(&it->second)) return *i32;
  if (const auto* i64 = std::get_if<std::int64_t>(&it->second)) return *i64;
  if (const auto* d = std::get_if<double>(&it->second)) {
    return static_cast<std::int64_t>(*d);  // truncation, like Swift Int(d)
  }
  return 0;
}

}  // namespace

std::vector<capture::export_::clip_planner::ClipKeptRange> ParseClipRanges(
    const flutter::EncodableValue* value) {
  std::vector<capture::export_::clip_planner::ClipKeptRange> ranges;
  if (value == nullptr) return ranges;
  const auto* list = std::get_if<flutter::EncodableList>(value);
  if (list == nullptr) return ranges;
  for (const auto& entry : *list) {
    const auto* clip = std::get_if<flutter::EncodableMap>(&entry);
    if (clip == nullptr) continue;
    bool enabled = true;
    if (const auto e = clip->find(flutter::EncodableValue("enabled"));
        e != clip->end()) {
      if (const auto* b = std::get_if<bool>(&e->second)) enabled = *b;
    }
    if (!enabled) continue;
    const std::int64_t in_ms = Int64OrZero(*clip, "sourceInMs");
    const std::int64_t out_ms = Int64OrZero(*clip, "sourceOutMs");
    if (out_ms > in_ms) {
      ranges.push_back(
          capture::export_::clip_planner::ClipKeptRange{in_ms, out_ms});
    }
  }
  return ranges;
}

std::vector<capture::export_::clip_planner::ClipKeptRange> ReadClipRangesArg(
    const flutter::EncodableMap& args) {
  const auto it = args.find(flutter::EncodableValue("clips"));
  if (it == args.end()) return {};
  return ParseClipRanges(&it->second);
}

}  // namespace clingfy::bridge
