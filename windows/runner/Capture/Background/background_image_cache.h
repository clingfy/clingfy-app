// Background image decoding + caching for the canvas.
//
// WHY A CACHE EXISTS AT ALL
//
// `PreviewCompositor::ComposeFrame` runs once per displayed frame. Decoding a
// background image inside it would re-decode a static image at playback rate on
// the Intel integrated GPUs this port targets. macOS solved the same problem
// with `PreviewBackgroundImageCache`; this is the Windows counterpart.
//
// The decoded ID2D1Bitmap is keyed by (path, last-write-time) so an image edited
// in place is picked up without restarting the app, and re-decoded exactly once
// when it changes. Device loss drops the bitmap via Reset(), because a D2D
// bitmap belongs to the device context that created it.
//
// COVER GEOMETRY
//
// A background fills the canvas the way a desktop wallpaper does: scaled to
// COVER, centred, overflow cropped. That differs from the video, which is fit
// (letterboxed) inside the padded content rect. Keeping the source-rect math in
// a pure function means it is unit-testable without a GPU, which the decode
// itself is not.
//
//   image 4000x2000 into canvas 1280x720:
//     scale to cover = max(1280/4000, 720/2000) = 0.36
//     visible source = 1280/0.36 x 720/0.36 = 3555x2000  (full height, cropped width)
//     centred        => src.x = (4000 - 3555) / 2 = 222
//
//   ┌───────────── source image ─────────────┐
//   │ cropped │   visible source rect  │ crop│
//   └───────────────────────────────────────┘

#ifndef RUNNER_CAPTURE_BACKGROUND_BACKGROUND_IMAGE_CACHE_H_
#define RUNNER_CAPTURE_BACKGROUND_BACKGROUND_IMAGE_CACHE_H_

#include <windows.h>
#include <d2d1_1.h>
#include <wrl/client.h>

#include <cstdint>
#include <mutex>
#include <string>

#include "Capture/Export/export_geometry.h"

namespace clingfy::capture::background {

// The sub-rectangle of the source image that is visible when the image is
// scaled to COVER `canvas` and centred. Returned in source-image pixels.
//
// Degenerate inputs (any zero/negative dimension) return the full image rect, so
// a caller that skipped validation draws something rather than nothing.
export_::RectF ComputeCoverSourceRect(export_::SizeF image,
                                      export_::SizeF canvas);

// Decodes and caches one background image at a time — the canvas has exactly one
// background, so a single-entry cache is the whole requirement. Switching images
// evicts the previous bitmap immediately rather than growing a map nobody
// invalidates.
class BackgroundImageCache {
 public:
  BackgroundImageCache() = default;

  BackgroundImageCache(const BackgroundImageCache&) = delete;
  BackgroundImageCache& operator=(const BackgroundImageCache&) = delete;

  // Returns the decoded bitmap for `path`, decoding on first use and re-decoding
  // when the file's last-write-time changes. Returns nullptr when `path` is
  // empty, missing, or fails to decode — the caller then draws the background
  // colour, which is the same thing a project with no image shows.
  //
  // Thread-safe. Call from the thread that owns `ctx`.
  ID2D1Bitmap* Get(ID2D1DeviceContext* ctx, const std::wstring& path);

  // Drop the cached bitmap. Call on device loss: a D2D bitmap belongs to the
  // context that created it and cannot outlive it.
  void Reset();

  // Test seam: how many times a decode actually ran. A second Get() for an
  // unchanged file must NOT increment this — that is the property that keeps a
  // static image off the per-frame decode path.
  std::int64_t decode_count() const;

 private:
  mutable std::mutex mutex_;
  // Whether a decode has been ATTEMPTED for (cached_path_, cached_write_time_).
  // Deliberately separate from `bitmap_` being non-null: a missing or corrupt
  // file caches a null result, and keying the hit on the bitmap instead would
  // re-attempt the decode on every frame.
  bool attempted_ = false;
  std::wstring cached_path_;
  std::int64_t cached_write_time_ = 0;
  Microsoft::WRL::ComPtr<ID2D1Bitmap> bitmap_;
  std::int64_t decode_count_ = 0;
};

// Last-write-time of `path` as a comparable integer, or 0 when unavailable.
// Exposed so the cache's invalidation rule can be reasoned about (and stubbed)
// independently of the decode.
std::int64_t FileWriteTime(const std::wstring& path);

}  // namespace clingfy::capture::background

#endif  // RUNNER_CAPTURE_BACKGROUND_BACKGROUND_IMAGE_CACHE_H_
