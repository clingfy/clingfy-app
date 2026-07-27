// Disk cache of rendered preset thumbnails for the background picker.
//
// The picker used to draw a linear gradient of the palette colours, which made
// all three presets look identical — the only thing that varied was the
// palette, so "Abstract Waves", "Graphic Mesh" and "Radial Glow" were three
// copies of the same swatch. A thumbnail has to be the actual renderer's
// output or it is not telling the user what they are picking.
//
// Rendering one per frame is out (four ribbons, two gradients and a Gaussian
// blur per card), and holding them in GPU memory is wasteful for something
// that changes only when the user drags a slider. So they go to disk, under
// %LOCALAPPDATA%, and are treated as DISPOSABLE: the preset itself is data,
// the pixels are derived, and deleting the whole directory costs nothing but
// the next render.
//
// The filename IS the cache key — `CanvasPresetCacheKey`, which already folds
// in every pixel-affecting parameter AND `kCanvasPresetRendererVersion`. That
// means bumping the renderer version invalidates every thumbnail on disk
// automatically, instead of showing pre-change art next to post-change
// backgrounds. A stale file is never read because its name cannot be
// regenerated.

#ifndef RUNNER_CAPTURE_BACKGROUND_PRESET_THUMBNAIL_CACHE_H_
#define RUNNER_CAPTURE_BACKGROUND_PRESET_THUMBNAIL_CACHE_H_

#include <windows.h>

#include <string>

#include "Capture/Background/canvas_preset_renderer.h"

namespace clingfy::capture::background {

// The directory thumbnails live in: `%LOCALAPPDATA%\Clingfy\PresetThumbnails`,
// or `$CLINGFY_PRESET_THUMBNAIL_ROOT` when set (tests point this at a temp
// directory — same override discipline as `CLINGFY_RECORDINGS_ROOT`).
std::string PresetThumbnailRoot();

// Pure: the file name for `spec` at `width` x `height`.
//
// Derived from CanvasPresetCacheKey with the separators made filename-safe.
// Kept readable rather than hashed — a hash would be shorter, but a collision
// would silently show the wrong art, and being able to see which preset a file
// belongs to is worth more than the bytes.
std::string PresetThumbnailFileName(const CanvasPresetSpec& spec, UINT width,
                                    UINT height);

// The full path for `spec`, whether or not the file exists yet.
std::string PresetThumbnailPath(const CanvasPresetSpec& spec, UINT width,
                                UINT height);

// The thumbnail path for `spec`, rendering and writing the PNG when it is not
// already on disk. Returns an empty string when rendering or encoding fails —
// the caller then shows its own placeholder rather than a broken image.
//
// Cheap on a hit: it stats the file and returns. No GPU device is created, so
// a picker that is only scrolling costs nothing.
std::string EnsurePresetThumbnail(const CanvasPresetSpec& spec, UINT width,
                                  UINT height);

}  // namespace clingfy::capture::background

#endif  // RUNNER_CAPTURE_BACKGROUND_PRESET_THUMBNAIL_CACHE_H_
