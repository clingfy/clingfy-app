#ifndef RUNNER_BRIDGE_DEVICES_DEVICE_RECORD_H_
#define RUNNER_BRIDGE_DEVICES_DEVICE_RECORD_H_

#include <flutter/encodable_value.h>

#include <cstdint>
#include <optional>
#include <string>

// Plain-data records that mirror the Dart parsers in
// `lib/core/models/app_models.dart` (DisplayInfo, AppWindowInfo, AudioSource,
// CamSource). The OS-specific enumerators populate these structs; the
// `ToEncodable*` helpers below convert them to the EncodableMap shape the
// Flutter side expects.
//
// Separating the data from the OS calls is what makes the formatter
// helpers unit-testable without a display, camera, or microphone attached.
namespace clingfy::bridge::devices {

struct DisplayRecord {
  std::int64_t id = 0;
  std::string name;
  double x = 0.0;
  double y = 0.0;
  double width = 0.0;
  double height = 0.0;
  double scale = 1.0;
  // 1-based position in the geometry-derived desk ordering. This is the number
  // the identify overlay paints, and the prefix of `name`.
  std::int64_t ordinal = 0;
  // The real monitor name after placeholder normalisation. Empty means absent
  // on the wire, so Dart reads null and substitutes its own localized word.
  std::string os_name;
  bool is_primary = false;
  // Always false on Windows in v1: a null selection resolves to the primary
  // monitor here, not to the app window's display, so the marker would be
  // informative rather than semantic. On the wire so enabling it is additive.
  bool is_app_window_host = false;
};

struct AppWindowRecord {
  std::int64_t window_id = 0;
  std::string app_name;
  std::string title;
  std::optional<double> bounds_x;
  std::optional<double> bounds_y;
  std::optional<double> bounds_width;
  std::optional<double> bounds_height;
  std::optional<std::int64_t> display_id;
  std::optional<std::int64_t> pid;
};

struct AudioSourceRecord {
  std::string id;
  std::string name;
};

struct VideoSourceRecord {
  std::string id;
  std::string name;
};

flutter::EncodableMap ToEncodable(const DisplayRecord& record);
flutter::EncodableMap ToEncodable(const AppWindowRecord& record);
flutter::EncodableMap ToEncodable(const AudioSourceRecord& record);
flutter::EncodableMap ToEncodable(const VideoSourceRecord& record);

}  // namespace clingfy::bridge::devices

#endif  // RUNNER_BRIDGE_DEVICES_DEVICE_RECORD_H_
