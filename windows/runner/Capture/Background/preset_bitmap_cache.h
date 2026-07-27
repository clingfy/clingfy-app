// Cache for rendered procedural-preset backgrounds.
//
// The preset is DATA; this holds the pixels it renders to, and they are
// disposable. Drop the cache and the next frame regenerates it — nothing is
// lost, which is exactly why no bitmap is ever stored in the project.
//
// Why it exists: `ComposeFrame` runs once per displayed frame, and rendering
// four wave ribbons plus two radial gradients plus a Gaussian blur per frame
// would be far worse than the per-frame image decode the image cache already
// prevents. Keyed by `CanvasPresetCacheKey`, which folds in every pixel-
// affecting input AND the renderer version, so changing the renderer
// invalidates automatically instead of showing pre-change art.
//
// Same shape as BackgroundImageCache deliberately: one entry, because a canvas
// has exactly one background, and switching evicts rather than growing a map
// nobody invalidates.

#ifndef RUNNER_CAPTURE_BACKGROUND_PRESET_BITMAP_CACHE_H_
#define RUNNER_CAPTURE_BACKGROUND_PRESET_BITMAP_CACHE_H_

#include <windows.h>
#include <d2d1_1.h>
#include <wrl/client.h>

#include <cstdint>
#include <mutex>
#include <string>

#include "Capture/Background/canvas_preset_renderer.h"

namespace clingfy::capture::background {

class PresetBitmapCache {
 public:
  PresetBitmapCache() = default;

  PresetBitmapCache(const PresetBitmapCache&) = delete;
  PresetBitmapCache& operator=(const PresetBitmapCache&) = delete;

  // The rendered bitmap for `spec` at `width` x `height`, rendering on first
  // use and re-rendering only when the cache key changes. Returns nullptr when
  // the render fails, in which case the caller draws the flat background colour
  // — the same thing a canvas with no preset shows.
  //
  // Must NOT be called between the caller's BeginDraw and EndDraw: the renderer
  // retargets the context. Same rule the camera painter's shadow bake follows.
  ID2D1Bitmap1* Get(ID2D1DeviceContext* ctx, const CanvasPresetSpec& spec,
                    UINT width, UINT height);

  // Drop the cached bitmap. Call on device loss — a D2D bitmap belongs to the
  // context that created it.
  void Reset();

  // Test seam: how many renders actually ran. A second Get() with an unchanged
  // key must NOT increment this; that is the property keeping the preset off
  // the per-frame path.
  std::int64_t render_count() const;

 private:
  mutable std::mutex mutex_;
  bool rendered_ = false;
  std::string cached_key_;
  Microsoft::WRL::ComPtr<ID2D1Bitmap1> bitmap_;
  std::int64_t render_count_ = 0;
};

}  // namespace clingfy::capture::background

#endif  // RUNNER_CAPTURE_BACKGROUND_PRESET_BITMAP_CACHE_H_
