#ifndef RUNNER_CAPTURE_EXPORT_VIDEO_SOURCE_PROBE_H_
#define RUNNER_CAPTURE_EXPORT_VIDEO_SOURCE_PROBE_H_

#include <optional>
#include <string>

#include "Capture/Export/export_geometry.h"

// The source-dimension question, asked the same way twice.
//
// `export_pipeline` reads the frame size from the NEGOTIATED media type rather
// than from the project manifest, and says why in its own comment: "Read the
// true source dimensions from the negotiated type rather than trusting the
// project metadata." `screen.meta.json` records what the recorder intended;
// the negotiated type is what the decoder will actually hand the compositor,
// and only the second one governs the exported frame.
//
// `resolveExportSize` has to answer that same question BEFORE an export runs,
// so Flutter can rasterize caption bitmaps against the canvas the frames will
// really have. If the two answers ever diverge, captions are laid out for one
// size and burned into another — and nothing reports an error, because both
// halves did exactly what they were told. That is the failure this probe
// exists to make structurally impossible: one negotiation, one answer.
namespace clingfy::capture::export_ {

// Frame size of the first decodable video stream in `path`, as the exporter's
// own RGB32 negotiation would report it.
//
// Returns nullopt when the path is empty, the file will not open, there is no
// video stream, RGB32 cannot be negotiated, or the reported size has a zero
// axis — the same conditions under which `export_pipeline` gives up with
// "export: could not determine source video dimensions." Callers treat nullopt
// as "cannot answer" and must not substitute a guess: a wrong size here is
// silently wrong output, which is strictly worse than no captions.
//
// Never throws. Cost is one short-lived source reader; no frame is decoded.
std::optional<PixelSize> ProbeVideoFrameSize(const std::wstring& path);

}  // namespace clingfy::capture::export_

#endif  // RUNNER_CAPTURE_EXPORT_VIDEO_SOURCE_PROBE_H_
