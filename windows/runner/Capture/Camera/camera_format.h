#ifndef RUNNER_CAPTURE_CAMERA_CAMERA_FORMAT_H_
#define RUNNER_CAPTURE_CAMERA_CAMERA_FORMAT_H_

#include <cstdint>

// Phase 9.2 — pure camera-format selection.
//
// A webcam exposes its own native resolution + frame rate; we want a SAFE,
// stable capture format (prefer 720p/1080p, ~30fps, even dimensions for H.264)
// without baking device I/O into untestable code. The device-touching part
// (enumerating IMFMediaType candidates, SetCurrentMediaType) lives in
// camera_recorder.cpp; the *decisions* — what target resolution + fps to ask
// for given the native values — are here, pure and unit-tested.
namespace clingfy::capture {

struct CameraDimensions {
  std::uint32_t width = 0;
  std::uint32_t height = 0;
};

// Choose a capture resolution from the camera's native size:
//   * never upscale — if the camera is <= 1920x1080, keep its native size;
//   * cap at 1920x1080, scaling down proportionally for higher-res cameras
//     (4K webcams) so the encoder + a future overlay stay cheap;
//   * always return EVEN dimensions (H.264 requirement);
//   * fall back to 1280x720 when the native size is unknown (0x0).
// Aspect ratio is preserved on downscale (fit within the 1080p box).
CameraDimensions ChooseCameraTargetResolution(std::uint32_t native_width,
                                              std::uint32_t native_height);

// Choose a stable capture fps from the camera's native frame rate (expressed
// as an MF numerator/denominator ratio). Prefers 30; never forces a slow
// camera faster than it runs (a 24fps camera stays 24); caps at 30 to keep
// the bitrate/CPU sane. Returns 30 when the native rate is unknown (den == 0).
std::uint32_t ChooseCameraFps(std::uint32_t native_fps_numerator,
                              std::uint32_t native_fps_denominator);

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CAMERA_CAMERA_FORMAT_H_
