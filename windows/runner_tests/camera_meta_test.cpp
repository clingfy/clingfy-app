#include "Capture/Camera/camera_meta.h"

#include <gtest/gtest.h>

#include <string>

namespace clingfy::capture {
namespace {

CameraMetaFields SampleFields() {
  CameraMetaFields f;
  f.recording_id = "sess-cam";
  f.device_id = "\\\\?\\usb#vid_046d&pid_0825";
  f.width = 1280;
  f.height = 720;
  f.fps = 30;
  f.start_offset_ms = 150;
  f.frames_written = 900;
  f.mirrored_raw = false;
  f.device_lost = false;
  return f;
}

TEST(CameraMetaTest, IncludesAllCoreFields) {
  const std::string json = BuildCameraMetaJson(SampleFields());
  EXPECT_NE(json.find("\"version\": 1"), std::string::npos);
  EXPECT_NE(json.find("\"recordingId\": \"sess-cam\""), std::string::npos);
  EXPECT_NE(json.find("\"rawRelativePath\": \"camera/raw.mov\""),
            std::string::npos);
  EXPECT_NE(json.find("\"metadataRelativePath\": \"camera/camera.meta.json\""),
            std::string::npos);
  EXPECT_NE(json.find("\"width\": 1280"), std::string::npos);
  EXPECT_NE(json.find("\"height\": 720"), std::string::npos);
  EXPECT_NE(json.find("\"nominalFrameRate\": 30"), std::string::npos);
  EXPECT_NE(json.find("\"startOffsetMs\": 150"), std::string::npos);
  EXPECT_NE(json.find("\"framesWritten\": 900"), std::string::npos);
  EXPECT_NE(json.find("\"segments\": []"), std::string::npos);
  EXPECT_NE(json.find("\"platform\": \"windows\""), std::string::npos);
}

TEST(CameraMetaTest, EscapesBackslashesInDeviceId) {
  const std::string json = BuildCameraMetaJson(SampleFields());
  // The raw symbolic link's backslashes MUST be JSON-escaped or the reader's
  // parser chokes. Expect the escaped form, not the raw one.
  EXPECT_NE(json.find("\\\\\\\\?\\\\usb#vid_046d&pid_0825"), std::string::npos);
}

TEST(CameraMetaTest, MirrorAndDeviceLostReflectFlags) {
  CameraMetaFields f = SampleFields();
  f.mirrored_raw = true;
  f.device_lost = true;
  const std::string json = BuildCameraMetaJson(f);
  EXPECT_NE(json.find("\"mirroredRaw\": true"), std::string::npos);
  EXPECT_NE(json.find("\"deviceLost\": true"), std::string::npos);

  const std::string json2 = BuildCameraMetaJson(SampleFields());
  EXPECT_NE(json2.find("\"mirroredRaw\": false"), std::string::npos);
  EXPECT_NE(json2.find("\"deviceLost\": false"), std::string::npos);
}

TEST(CameraMetaTest, PreviewBurnedInReflectsFlag) {
  // Flutter-texture preview path → not burned into screen.mov.
  EXPECT_NE(BuildCameraMetaJson(SampleFields()).find("\"previewBurnedIn\": false"),
            std::string::npos);
  CameraMetaFields f = SampleFields();
  f.preview_burned_in = true;
  EXPECT_NE(BuildCameraMetaJson(f).find("\"previewBurnedIn\": true"),
            std::string::npos);
}

// --- Phase 9.4 ParseCameraMetaJson ------------------------------------------

TEST(CameraMetaParseTest, RoundTripsBuiltJson) {
  CameraMetaFields f = SampleFields();
  f.fps = 30;
  f.start_offset_ms = 150;
  f.frames_written = 900;
  f.preview_burned_in = false;
  const auto parsed = ParseCameraMetaJson(BuildCameraMetaJson(f));
  ASSERT_TRUE(parsed.has_value());
  EXPECT_EQ(parsed->recording_id, "sess-cam");
  EXPECT_EQ(parsed->device_id, "\\\\?\\usb#vid_046d&pid_0825");
  EXPECT_EQ(parsed->width, 1280u);
  EXPECT_EQ(parsed->height, 720u);
  EXPECT_EQ(parsed->fps, 30u);
  EXPECT_EQ(parsed->start_offset_ms, 150);
  EXPECT_EQ(parsed->frames_written, 900u);
  EXPECT_FALSE(parsed->preview_burned_in);
  EXPECT_FALSE(parsed->device_lost);
}

TEST(CameraMetaParseTest, ParsesBurnedInTrueAndDeviceLost) {
  CameraMetaFields f = SampleFields();
  f.preview_burned_in = true;
  f.device_lost = true;
  const auto parsed = ParseCameraMetaJson(BuildCameraMetaJson(f));
  ASSERT_TRUE(parsed.has_value());
  EXPECT_TRUE(parsed->preview_burned_in);
  EXPECT_TRUE(parsed->device_lost);
}

TEST(CameraMetaParseTest, NegativeStartOffsetSurvives) {
  // start_offset_ms is signed; a (defensive) negative value must parse, not clip.
  const std::string json = "{ \"startOffsetMs\": -42, \"framesWritten\": 3 }";
  const auto parsed = ParseCameraMetaJson(json);
  ASSERT_TRUE(parsed.has_value());
  EXPECT_EQ(parsed->start_offset_ms, -42);
  EXPECT_EQ(parsed->frames_written, 3u);
}

TEST(CameraMetaParseTest, MissingKeysTakeDefaults) {
  const auto parsed = ParseCameraMetaJson("{ \"platform\": \"windows\" }");
  ASSERT_TRUE(parsed.has_value());
  EXPECT_EQ(parsed->start_offset_ms, 0);
  EXPECT_EQ(parsed->frames_written, 0u);
  EXPECT_FALSE(parsed->preview_burned_in);
}

TEST(CameraMetaParseTest, KeyLikeSubstringInValueIsNotMistakenForKey) {
  // The deviceId is an untrusted device symbolic link. A value that embeds a
  // key-shaped substring must NOT flip the real top-level keys — otherwise a
  // crafted device name could silently double or drop the camera at export.
  const std::string json =
      "{ \"deviceId\": \"cam \\\"previewBurnedIn\\\":true "
      "\\\"startOffsetMs\\\":99999\", \"startOffsetMs\": 120, "
      "\"previewBurnedIn\": false, \"framesWritten\": 10 }";
  const auto parsed = ParseCameraMetaJson(json);
  ASSERT_TRUE(parsed.has_value());
  // The REAL top-level values win, not the substrings inside deviceId.
  EXPECT_EQ(parsed->start_offset_ms, 120);
  EXPECT_FALSE(parsed->preview_burned_in);
  EXPECT_EQ(parsed->frames_written, 10u);
}

TEST(CameraMetaParseTest, NestedObjectKeysAreIgnored) {
  // Only depth-1 keys count; a same-named key inside a nested object (e.g. a
  // segment) must not shadow the real top-level value.
  const std::string json =
      "{ \"segments\": [ { \"startOffsetMs\": 5 } ], "
      "\"startOffsetMs\": 300 }";
  const auto parsed = ParseCameraMetaJson(json);
  ASSERT_TRUE(parsed.has_value());
  EXPECT_EQ(parsed->start_offset_ms, 300);
}

TEST(CameraMetaParseTest, MalformedReturnsNullopt) {
  EXPECT_FALSE(ParseCameraMetaJson("").has_value());
  EXPECT_FALSE(ParseCameraMetaJson("   ").has_value());
  EXPECT_FALSE(ParseCameraMetaJson("not json").has_value());
  // Truncated object (no closing brace) is the on-disk corruption case.
  EXPECT_FALSE(ParseCameraMetaJson("{ \"startOffsetMs\": 10").has_value());
}

}  // namespace
}  // namespace clingfy::capture
