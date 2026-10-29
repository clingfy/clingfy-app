#include "Bridge/Routers/zoom_focus_args.h"

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace clingfy::bridge {

namespace {

// double or int → value; anything else (missing, string, null) → false.
bool ReadNumber(const flutter::EncodableMap& map, const char* key,
                double* out) {
  const auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it == map.end()) return false;
  if (const auto* d = std::get_if<double>(&it->second)) {
    *out = *d;
  } else if (const auto* i32 = std::get_if<std::int32_t>(&it->second)) {
    *out = static_cast<double>(*i32);
  } else if (const auto* i64 = std::get_if<std::int64_t>(&it->second)) {
    *out = static_cast<double>(*i64);
  } else {
    return false;
  }
  return std::isfinite(*out);
}

}  // namespace

ZoomFocusArgs ReadZoomFocusArgs(const flutter::EncodableMap& segment) {
  ZoomFocusArgs args;
  const auto mode = segment.find(flutter::EncodableValue("focusMode"));
  if (mode != segment.end()) {
    if (const auto* s = std::get_if<std::string>(&mode->second)) {
      args.focus_mode = *s;
    }
  }
  const auto point = segment.find(flutter::EncodableValue("fixedTarget"));
  if (point != segment.end()) {
    if (const auto* map = std::get_if<flutter::EncodableMap>(&point->second)) {
      double x = 0.0;
      double y = 0.0;
      if (ReadNumber(*map, "dx", &x) && ReadNumber(*map, "dy", &y)) {
        args.has_point = true;
        args.x = std::clamp(x, 0.0, 1.0);
        args.y = std::clamp(y, 0.0, 1.0);
      }
    }
  }
  return args;
}

}  // namespace clingfy::bridge
