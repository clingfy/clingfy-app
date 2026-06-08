#ifndef RUNNER_CAPTURE_CAMERA_CAMERA_META_H_
#define RUNNER_CAPTURE_CAMERA_CAMERA_META_H_

#include <cstdint>
#include <optional>
#include <string>

// Phase 9.2 — the camera/camera.meta.json sidecar.
//
// Parity-shaped with macOS `CameraRecordingMetadata` (Core/RecordingMetadata.swift)
// where it makes sense; Windows records ONE raw.mov (no segments / merge), so
// `segments` is always an empty array. The key Windows-specific field is
// `startOffsetMs`: the camera's first frame lands a little after recording t=0
// (camera startup latency), and the raw.mov is rebased to start at 0, so the
// export (Phase 9.4) finds the camera frame for screen-time `tMs` at
// `tMs - startOffsetMs` in the camera file.
//
// Pure string builder — no filesystem, fully unit-testable.
namespace clingfy::capture {

struct CameraMetaFields {
  // Ties the camera to its recording session (the project id). Mirrors macOS
  // `recordingId`.
  std::string recording_id;
  // Media Foundation symbolic-link id of the captured device.
  std::string device_id;
  std::uint32_t width = 0;
  std::uint32_t height = 0;
  std::uint32_t fps = 0;
  // Recording-time (ms) of the first captured camera frame. Sync key for
  // export. 0 when no frame was captured.
  std::int64_t start_offset_ms = 0;
  std::uint64_t frames_written = 0;
  // Windows records the camera unmirrored; mirror is applied at export so it
  // stays editable (Phase 9.5). Always false today, but written for parity +
  // forward-compat.
  bool mirrored_raw = false;
  // The capture ended early because the device was lost mid-recording. The
  // raw.mov is still a valid (shorter) clip.
  bool device_lost = false;
  // Phase 9.3.1: whether the live preview was burned into screen.mov during
  // recording. False for the Flutter-texture preview path (the camera is NOT in
  // the screen video) → Phase 9.4 export composites it from raw.mov. True only
  // if a captured topmost overlay path was used. The reader/export uses this to
  // avoid double-drawing the camera.
  bool preview_burned_in = false;
};

std::string BuildCameraMetaJson(const CameraMetaFields& fields);

// Phase 9.4 — parse a `camera/camera.meta.json` document back into its fields.
// Tolerant of unknown keys and the (always-empty) `segments` array, but returns
// nullopt when the input is not a JSON object (empty / no balanced braces) so a
// malformed sidecar makes the export fall back to screen-only rather than draw a
// garbage camera. Missing scalar keys take the `CameraMetaFields` defaults. Pure
// — no filesystem; the caller reads the file and hands the text in.
std::optional<CameraMetaFields> ParseCameraMetaJson(const std::string& json);

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CAMERA_CAMERA_META_H_
