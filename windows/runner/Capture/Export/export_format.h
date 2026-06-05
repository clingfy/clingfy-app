// Slice 5A of Phase 6 (export) — pure format / bitrate resolution.
//
// Maps the Dart `format` and `bitrate` export args to a concrete output-file
// extension and an H.264 average bitrate. Pure (no Win32 / Media Foundation)
// so it is pinned by `export_format_test.cpp` without an encoder — the same
// split Slices 3/4 used for `export_geometry` / `export_audio`.
//
// Container: the Media Foundation Sink Writer is opened via
// MFCreateSinkWriterFromURL, which picks the container from the file
// extension — so writing a `.mp4` path yields an MP4 (MPEG-4) container and a
// `.mov` path yields QuickTime. There is nothing else to set.
//
// Bitrate parity note: macOS does NOT set an average bitrate on its export
// (it relies on AVAssetExportSession codec defaults and only logs the preset
// string), so there is no macOS numeric table to mirror. Per the Slice 5A
// request to honor the requested bitrate, Windows defines its own
// resolution-aware preset -> bps mapping here.

#ifndef RUNNER_CAPTURE_EXPORT_EXPORT_FORMAT_H_
#define RUNNER_CAPTURE_EXPORT_EXPORT_FORMAT_H_

#include <cstdint>
#include <string>

namespace clingfy::capture::export_ {

// Resolve the output-file extension (including the leading dot) for a Dart
// `format` arg. "mp4" -> ".mp4"; "gif" -> ".gif" (Slice 5B, real animated GIF
// via WIC); "mov" / "" / unknown -> ".mov". Case-insensitive.
std::string ResolveExportExtension(const std::string& format);

// True when the requested format could not be produced and the export was
// written in a different container. Windows now emits .mov, .mp4, AND .gif
// natively (Slices 5A/5B), so this is always false — nothing is downgraded.
// Retained as a contract point (the passthrough Result still carries the flag).
bool FormatWasDowngraded(const std::string& format);

// Resolve a Dart `bitrate` preset ("auto" | "low" | "medium" | "high") to an
// H.264 average bitrate in bits/sec for the given output dimensions + fps.
// Resolution-aware (bits-per-pixel-per-frame): low 0.04, medium/auto 0.08,
// high 0.15, clamped to [2 Mbps, 100 Mbps]. fps==0 is treated as 30. Unknown
// presets behave like "auto". Width/height of 0 clamp to the floor.
std::uint32_t ResolveVideoBitrateBps(const std::string& bitrate,
                                     std::uint32_t width, std::uint32_t height,
                                     std::uint32_t fps);

}  // namespace clingfy::capture::export_

#endif  // RUNNER_CAPTURE_EXPORT_EXPORT_FORMAT_H_
