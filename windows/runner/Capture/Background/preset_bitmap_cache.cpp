#include "Capture/Background/preset_bitmap_cache.h"

namespace clingfy::capture::background {

ID2D1Bitmap1* PresetBitmapCache::Get(ID2D1DeviceContext* ctx,
                                     const CanvasPresetSpec& spec, UINT width,
                                     UINT height) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (ctx == nullptr || spec.preset_id.empty() || width == 0 || height == 0) {
    bitmap_.Reset();
    cached_key_.clear();
    rendered_ = false;
    return nullptr;
  }

  const std::string key = CanvasPresetCacheKey(spec, width, height);

  // Cache hit. Keyed on `rendered_`, NOT on the bitmap being non-null, so a
  // render that failed is remembered as a failure instead of being retried on
  // every frame.
  if (rendered_ && key == cached_key_) {
    return bitmap_.Get();
  }

  bitmap_ = RenderCanvasPreset(ctx, width, height, spec);
  ++render_count_;
  cached_key_ = key;
  rendered_ = true;
  return bitmap_.Get();
}

void PresetBitmapCache::Reset() {
  std::lock_guard<std::mutex> lock(mutex_);
  bitmap_.Reset();
  cached_key_.clear();
  rendered_ = false;
}

std::int64_t PresetBitmapCache::render_count() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return render_count_;
}

}  // namespace clingfy::capture::background
