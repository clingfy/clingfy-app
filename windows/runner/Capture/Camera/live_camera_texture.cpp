#include "Capture/Camera/live_camera_texture.h"

#include <utility>

namespace clingfy::capture {

LiveCameraTexture& LiveCameraTexture::Instance() {
  static LiveCameraTexture instance;
  return instance;
}

std::int64_t LiveCameraTexture::Initialize(
    FlutterDesktopPluginRegistrarRef registrar) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (texture_id_ >= 0) {
    return texture_id_;  // already registered.
  }
  if (registrar == nullptr) {
    return -1;
  }
  texture_registrar_ =
      FlutterDesktopRegistrarGetTextureRegistrar(registrar);
  if (texture_registrar_ == nullptr) {
    return -1;
  }
  FlutterDesktopTextureInfo info{};
  info.type = kFlutterDesktopPixelBufferTexture;
  info.pixel_buffer_config.user_data = this;
  info.pixel_buffer_config.callback = &LiveCameraTexture::CopyPixelBuffer;
  texture_id_ = FlutterDesktopTextureRegistrarRegisterExternalTexture(
      texture_registrar_, &info);
  return texture_id_;
}

std::int64_t LiveCameraTexture::texture_id() const {
  // texture_id_ is set once under the lock in Initialize and then immutable, so
  // a plain read is safe.
  return texture_id_;
}

void LiveCameraTexture::SwizzleBgraToRgba(const std::uint8_t* bgra, int width,
                                          int height, std::uint8_t* dst) {
  if (bgra == nullptr || dst == nullptr || width <= 0 || height <= 0) {
    return;
  }
  // src BGRA bytes: [0]=B [1]=G [2]=R [3]=A. dst RGBA: [0]=R [1]=G [2]=B [3]=A.
  const size_t pixels = static_cast<size_t>(width) * height;
  for (size_t i = 0; i < pixels; ++i) {
    const size_t o = i * 4;
    dst[o + 0] = bgra[o + 2];  // R
    dst[o + 1] = bgra[o + 1];  // G
    dst[o + 2] = bgra[o + 0];  // B
    dst[o + 3] = bgra[o + 3];  // A
  }
}

void LiveCameraTexture::PublishBgra(const std::uint8_t* bgra, int width,
                                    int height) {
  if (texture_registrar_ == nullptr || texture_id_ < 0 || bgra == nullptr ||
      width <= 0 || height <= 0) {
    return;
  }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    rgba_.resize(static_cast<size_t>(width) * height * 4);
    SwizzleBgraToRgba(bgra, width, height, rgba_.data());
    width_ = width;
    height_ = height;
  }
  FlutterDesktopTextureRegistrarMarkExternalTextureFrameAvailable(
      texture_registrar_, texture_id_);
}

const FlutterDesktopPixelBuffer* LiveCameraTexture::CopyPixelBuffer(
    size_t /*width*/, size_t /*height*/, void* user_data) {
  auto* self = static_cast<LiveCameraTexture*>(user_data);
  if (self == nullptr) {
    return nullptr;
  }
  // Copy the latest frame into the raster-thread-owned staging buffer under the
  // lock, then release the lock and hand Flutter the staging buffer. No lock
  // spans the upload and no release callback is needed.
  {
    std::lock_guard<std::mutex> lock(self->mutex_);
    if (self->rgba_.empty() || self->width_ <= 0 || self->height_ <= 0) {
      return nullptr;  // no frame yet → Flutter shows nothing this tick.
    }
    self->staging_.assign(self->rgba_.begin(), self->rgba_.end());
    self->flutter_buffer_.width = static_cast<size_t>(self->width_);
    self->flutter_buffer_.height = static_cast<size_t>(self->height_);
  }
  self->flutter_buffer_.buffer = self->staging_.data();
  self->flutter_buffer_.release_callback = nullptr;
  self->flutter_buffer_.release_context = nullptr;
  return &self->flutter_buffer_;
}

}  // namespace clingfy::capture
