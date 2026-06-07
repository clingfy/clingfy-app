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

}  // namespace
}  // namespace clingfy::capture
