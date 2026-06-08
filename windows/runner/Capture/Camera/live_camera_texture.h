#ifndef RUNNER_CAPTURE_CAMERA_LIVE_CAMERA_TEXTURE_H_
#define RUNNER_CAPTURE_CAMERA_LIVE_CAMERA_TEXTURE_H_

#include <flutter_plugin_registrar.h>
#include <flutter_texture_registrar.h>

#include <cstdint>
#include <mutex>
#include <vector>

// Phase 9.3.1 — live camera preview as a Flutter Texture (NOT a captured
// topmost overlay).
//
// The 9.3 topmost overlay was always on top of whatever the user captured, so
// it was burned into screen.mov on every recording (and WDA_EXCLUDEFROMCAPTURE
// hid it entirely on hybrid-GPU laptops). Rendering the preview as a Flutter
// Texture inside the app window removes that: it is only captured in the edge
// case where the user records the app's own monitor with the app visible (which
// the existing "exclude recorder app" path handles), so the camera stays
// editable-at-export from camera/raw.mov (Phase 9.4) instead of pre-burned.
//
// This is an app-lifetime singleton: it registers ONE pixel-buffer texture when
// the Flutter registrar is available (flutter_window) and keeps it for the whole
// process, so there is no per-recording register/unregister race. The 9.2
// CameraRecorder feeds it downscaled BGRA frames (swizzled to RGBA here) only
// while recording; Dart shows the Texture widget during recording and hides it
// otherwise.
namespace clingfy::capture {

class LiveCameraTexture {
 public:
  static LiveCameraTexture& Instance();

  LiveCameraTexture(const LiveCameraTexture&) = delete;
  LiveCameraTexture& operator=(const LiveCameraTexture&) = delete;

  // Register the pixel-buffer texture with the Flutter registrar. Called once
  // from flutter_window at startup. Idempotent. Returns the texture id (or -1).
  std::int64_t Initialize(FlutterDesktopPluginRegistrarRef registrar);

  // The registered texture id, or -1 when registration failed / not yet done.
  // Dart fetches this via the getCameraPreviewTextureId bridge method.
  std::int64_t texture_id() const;

  // Feed the latest camera frame (tightly-packed BGRA, stride = width*4) from
  // the recorder's preview hook. Swizzles to RGBA, stores it, and signals
  // Flutter. Thread-safe; a no-op before Initialize. Called from the camera
  // capture thread.
  void PublishBgra(const std::uint8_t* bgra, int width, int height);

  // Swizzle BGRA -> RGBA into `dst` (Flutter's pixel buffer is RGBA; the camera
  // frames are BGRA). `dst` must hold width*height*4 bytes. Pure + tested.
  static void SwizzleBgraToRgba(const std::uint8_t* bgra, int width, int height,
                                std::uint8_t* dst);

 private:
  LiveCameraTexture() = default;

  // Flutter pixel-buffer copy callback (raster thread). Copies the latest frame
  // into `staging_` under the lock and returns that stable buffer (no lock spans
  // the upload, and no release callback is needed — this avoids depending on
  // Flutter's undocumented copy/release threading). Flutter serializes copy
  // callbacks on the raster thread, so `staging_`/`flutter_buffer_` are only
  // touched here, one frame at a time.
  static const FlutterDesktopPixelBuffer* CopyPixelBuffer(size_t width,
                                                          size_t height,
                                                          void* user_data);

  FlutterDesktopTextureRegistrarRef texture_registrar_ = nullptr;
  std::int64_t texture_id_ = -1;

  std::mutex mutex_;
  std::vector<std::uint8_t> rgba_;  // latest frame (written by PublishBgra)
  int width_ = 0;
  int height_ = 0;
  std::vector<std::uint8_t> staging_;  // raster-thread copy handed to Flutter
  FlutterDesktopPixelBuffer flutter_buffer_{};
};

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CAMERA_LIVE_CAMERA_TEXTURE_H_
