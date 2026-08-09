#include "Bridge/Devices/device_record.h"

namespace clingfy::bridge::devices {

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

}  // namespace

EncodableMap ToEncodable(const DisplayRecord& record) {
  EncodableMap map{
      {EncodableValue("id"), EncodableValue(record.id)},
      {EncodableValue("name"), EncodableValue(record.name)},
      {EncodableValue("x"), EncodableValue(record.x)},
      {EncodableValue("y"), EncodableValue(record.y)},
      {EncodableValue("width"), EncodableValue(record.width)},
      {EncodableValue("height"), EncodableValue(record.height)},
      {EncodableValue("scale"), EncodableValue(record.scale)},
      {EncodableValue("ordinal"), EncodableValue(record.ordinal)},
      {EncodableValue("isPrimary"), EncodableValue(record.is_primary)},
      {EncodableValue("isAppWindowHost"),
       EncodableValue(record.is_app_window_host)},
  };

  // Absent rather than empty: Dart reads null and falls back to its own
  // localized screen word, which an empty string would defeat.
  if (!record.os_name.empty()) {
    map[EncodableValue("osName")] = EncodableValue(record.os_name);
  }
  return map;
}

EncodableMap ToEncodable(const AppWindowRecord& record) {
  EncodableMap map{
      {EncodableValue("windowId"), EncodableValue(record.window_id)},
      {EncodableValue("appName"), EncodableValue(record.app_name)},
      {EncodableValue("title"), EncodableValue(record.title)},
  };

  // Bounds: only attach if all four corners are present. The Dart parser
  // treats `bounds` as nullable and falls back to a zero rect if absent,
  // so omitting an incomplete bounds is safer than fabricating values.
  if (record.bounds_x && record.bounds_y && record.bounds_width &&
      record.bounds_height) {
    EncodableMap bounds{
        {EncodableValue("x"), EncodableValue(*record.bounds_x)},
        {EncodableValue("y"), EncodableValue(*record.bounds_y)},
        {EncodableValue("width"), EncodableValue(*record.bounds_width)},
        {EncodableValue("height"), EncodableValue(*record.bounds_height)},
    };
    map[EncodableValue("bounds")] = EncodableValue(std::move(bounds));
  }

  if (record.display_id) {
    map[EncodableValue("displayId")] = EncodableValue(*record.display_id);
  }
  if (record.pid) {
    map[EncodableValue("pid")] = EncodableValue(*record.pid);
  }
  return map;
}

EncodableMap ToEncodable(const AudioSourceRecord& record) {
  return EncodableMap{
      {EncodableValue("id"), EncodableValue(record.id)},
      {EncodableValue("name"), EncodableValue(record.name)},
  };
}

EncodableMap ToEncodable(const VideoSourceRecord& record) {
  return EncodableMap{
      {EncodableValue("id"), EncodableValue(record.id)},
      {EncodableValue("name"), EncodableValue(record.name)},
  };
}

}  // namespace clingfy::bridge::devices
