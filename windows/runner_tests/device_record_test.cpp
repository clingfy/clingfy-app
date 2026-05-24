#include "Bridge/Devices/device_record.h"

#include <gtest/gtest.h>

#include <flutter/encodable_value.h>

#include <string>

namespace clingfy::bridge::devices {
namespace {

const flutter::EncodableValue* FindKey(const flutter::EncodableMap& map,
                                       const std::string& key) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return nullptr;
  }
  return &it->second;
}

TEST(DeviceRecordTest, DisplayRecordEncodesAllFields) {
  DisplayRecord record;
  record.id = 42;
  record.name = "Built-in";
  record.x = -1280;
  record.y = 0;
  record.width = 1280;
  record.height = 800;
  record.scale = 2.0;

  const auto map = ToEncodable(record);

  EXPECT_EQ(std::get<int64_t>(*FindKey(map, "id")), 42);
  EXPECT_EQ(std::get<std::string>(*FindKey(map, "name")), "Built-in");
  EXPECT_DOUBLE_EQ(std::get<double>(*FindKey(map, "x")), -1280.0);
  EXPECT_DOUBLE_EQ(std::get<double>(*FindKey(map, "y")), 0.0);
  EXPECT_DOUBLE_EQ(std::get<double>(*FindKey(map, "width")), 1280.0);
  EXPECT_DOUBLE_EQ(std::get<double>(*FindKey(map, "height")), 800.0);
  EXPECT_DOUBLE_EQ(std::get<double>(*FindKey(map, "scale")), 2.0);
}

TEST(DeviceRecordTest, AppWindowRecordOmitsBoundsWhenIncomplete) {
  AppWindowRecord record;
  record.window_id = 1234;
  record.app_name = "Notes";
  record.title = "scratch.md";
  // Intentionally leave bounds_height unset.
  record.bounds_x = 10.0;
  record.bounds_y = 20.0;
  record.bounds_width = 100.0;

  const auto map = ToEncodable(record);

  EXPECT_EQ(std::get<int64_t>(*FindKey(map, "windowId")), 1234);
  EXPECT_EQ(std::get<std::string>(*FindKey(map, "appName")), "Notes");
  EXPECT_EQ(std::get<std::string>(*FindKey(map, "title")), "scratch.md");
  EXPECT_EQ(FindKey(map, "bounds"), nullptr)
      << "Bounds map must be omitted when any side is missing — the Dart "
         "parser treats absent bounds as 'unknown', but a partial bounds "
         "would be misread as a degenerate rect.";
}

TEST(DeviceRecordTest, AppWindowRecordIncludesFullBoundsAndOptionalFields) {
  AppWindowRecord record;
  record.window_id = 99;
  record.app_name = "Code";
  record.title = "main.cpp";
  record.bounds_x = 0.0;
  record.bounds_y = 0.0;
  record.bounds_width = 1920.0;
  record.bounds_height = 1080.0;
  record.display_id = 7;
  record.pid = 4321;

  const auto map = ToEncodable(record);

  const auto* bounds = FindKey(map, "bounds");
  ASSERT_NE(bounds, nullptr);
  const auto& bounds_map = std::get<flutter::EncodableMap>(*bounds);
  EXPECT_DOUBLE_EQ(std::get<double>(*FindKey(bounds_map, "x")), 0.0);
  EXPECT_DOUBLE_EQ(std::get<double>(*FindKey(bounds_map, "y")), 0.0);
  EXPECT_DOUBLE_EQ(std::get<double>(*FindKey(bounds_map, "width")), 1920.0);
  EXPECT_DOUBLE_EQ(std::get<double>(*FindKey(bounds_map, "height")), 1080.0);

  EXPECT_EQ(std::get<int64_t>(*FindKey(map, "displayId")), 7);
  EXPECT_EQ(std::get<int64_t>(*FindKey(map, "pid")), 4321);
}

TEST(DeviceRecordTest, AudioSourceRecordEncodesIdAndName) {
  AudioSourceRecord record{"{0.0.1.0}.{abc}", "Studio Mic"};
  const auto map = ToEncodable(record);
  EXPECT_EQ(std::get<std::string>(*FindKey(map, "id")), "{0.0.1.0}.{abc}");
  EXPECT_EQ(std::get<std::string>(*FindKey(map, "name")), "Studio Mic");
}

TEST(DeviceRecordTest, VideoSourceRecordEncodesIdAndName) {
  VideoSourceRecord record{R"(\\?\usb#vid_046d&pid_0825)", "Logitech C270"};
  const auto map = ToEncodable(record);
  EXPECT_EQ(std::get<std::string>(*FindKey(map, "id")),
            R"(\\?\usb#vid_046d&pid_0825)");
  EXPECT_EQ(std::get<std::string>(*FindKey(map, "name")), "Logitech C270");
}

}  // namespace
}  // namespace clingfy::bridge::devices
