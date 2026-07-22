#include "Bridge/Routers/color_grade_args.h"

#include <cstdint>
#include <string>

namespace clingfy::bridge {

namespace {

// Mirrors the macOS `number(_:)` helper: double or int → double, anything
// else (missing, string, bool, null) → 0.
double NumberOrZero(const flutter::EncodableMap& map, const char* key) {
  const auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it == map.end()) return 0.0;
  if (const auto* d = std::get_if<double>(&it->second)) return *d;
  if (const auto* i32 = std::get_if<std::int32_t>(&it->second)) {
    return static_cast<double>(*i32);
  }
  if (const auto* i64 = std::get_if<std::int64_t>(&it->second)) {
    return static_cast<double>(*i64);
  }
  return 0.0;
}

bool BoolOrFalse(const flutter::EncodableMap& map, const char* key) {
  const auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it == map.end()) return false;
  if (const auto* b = std::get_if<bool>(&it->second)) return *b;
  return false;
}

}  // namespace

capture::export_::color::ColorGrade ParseColorGrade(
    const flutter::EncodableValue* value) {
  capture::export_::color::ColorGrade grade;
  if (value == nullptr) return grade;
  const auto* map = std::get_if<flutter::EncodableMap>(value);
  if (map == nullptr) return grade;
  grade.auto_enabled = BoolOrFalse(*map, "autoEnabled");
  grade.exposure = NumberOrZero(*map, "exposure");
  grade.contrast = NumberOrZero(*map, "contrast");
  grade.saturation = NumberOrZero(*map, "saturation");
  grade.temperature = NumberOrZero(*map, "temperature");
  grade.tint = NumberOrZero(*map, "tint");
  return grade;
}

capture::export_::color::ColorGrade ReadColorGradeArg(
    const flutter::EncodableMap& args) {
  const auto it = args.find(flutter::EncodableValue("colorGrade"));
  if (it == args.end()) return capture::export_::color::ColorGrade{};
  return ParseColorGrade(&it->second);
}

}  // namespace clingfy::bridge
