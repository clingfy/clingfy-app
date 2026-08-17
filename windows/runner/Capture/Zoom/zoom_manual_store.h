#ifndef RUNNER_CAPTURE_ZOOM_ZOOM_MANUAL_STORE_H_
#define RUNNER_CAPTURE_ZOOM_ZOOM_MANUAL_STORE_H_

#include <cstdint>
#include <string>
#include <vector>

#include "Capture/Zoom/zoom_timeline_builder.h"

// Persistence for USER-AUTHORED zoom segments — the manual half of the zoom
// lane, which Windows has never had.
//
// Auto zoom has worked end to end for a while: the cursor sidecar feeds
// `BuildZoomSegments`, and both the preview and the export render the result.
// What was missing is everything the user can do ON TOP of that — add a
// segment, drag its edges, delete one the auto-detector produced. The whole
// Dart editor for it exists and is attached on both platforms; on Windows it
// wrote into three stubs (`saveManualZoomSegments` always returned false,
// `getManualZoomSegments` always returned an empty list, and
// `previewSetZoomSegments` was a registered no-op), so nothing survived a
// keystroke.
//
// FILE FORMAT is macOS's, byte for byte, at `capture/zoom.manual.json`:
//
//   {"version":2,"segments":[{"id":"...","startMs":0,"endMs":1000,
//                             "source":"manual","baseId":"auto_3"}]}
//
// The two fields that carry the real semantics:
//
//   * `baseId` — this manual segment OVERRIDES the auto segment with that id.
//     The auto one must then be dropped from the effective timeline, or the
//     user's edit would render on top of the thing they edited.
//   * a segment with `endMs <= startMs` is a TOMBSTONE, not a zero-length
//     zoom. It exists solely to carry a `baseId` and say "the user deleted
//     that auto segment". It must never reach a renderer.
namespace clingfy::capture {

struct ZoomManualSegment {
  std::string id;
  std::int64_t start_ms = 0;
  std::int64_t end_ms = 0;
  std::string source;   // "manual" when absent
  std::string base_id;  // empty when this is not an override
};

// True for a segment that only records a deletion. See the note above: this
// is a deliberate encoding, not malformed data, and both the preview and the
// export have to honour it.
inline bool IsZoomTombstone(const ZoomManualSegment& s) {
  return s.end_ms <= s.start_ms;
}

// Parse the sidecar's bytes. Tolerant by design — a malformed or truncated
// file yields an empty list rather than an error, because losing manual edits
// is bad but refusing to open the project is worse. Unknown keys are ignored
// so a newer macOS-written file still loads.
std::vector<ZoomManualSegment> ParseZoomManualJson(const std::string& bytes);

// Serialize to the v2 shape macOS reads. Tombstones are preserved: they are
// the only record that an auto segment was deleted.
std::string SerializeZoomManualJson(
    const std::vector<ZoomManualSegment>& segments);

// The effective timeline: what the preview and the export should actually
// render, given the auto segments the cursor sidecar produced and whatever the
// user has authored on top.
//
// The rule is macOS's:
//   1. every manual segment that is not a tombstone is kept;
//   2. an auto segment is dropped when ANY manual segment names it via
//      `base_id` — including by a tombstone, which is how deletion works;
//   3. auto ids are positional, `auto_<index>`, matching what
//      `getZoomSegments` hands Dart, so the ids the user's edits refer to and
//      the ids we generate here have to come from the same ordering.
// Result is sorted by start time so downstream consumers can assume order.
std::vector<ZoomSegment> MergeZoomSegments(
    const std::vector<ZoomSegment>& auto_segments,
    const std::vector<ZoomManualSegment>& manual_segments);

// Read / write `<project>/capture/zoom.manual.json`. Both soft-fail: a missing
// file loads as empty, and a failed write returns false for the Dart caller to
// surface rather than throwing.
std::vector<ZoomManualSegment> LoadZoomManualSegments(
    const std::wstring& project_path);
bool SaveZoomManualSegments(const std::wstring& project_path,
                            const std::vector<ZoomManualSegment>& segments);

// The sidecar's path for a project root. Exposed so the export can read the
// store without duplicating the layout rule.
std::wstring ZoomManualSidecarPath(const std::wstring& project_path);

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_ZOOM_ZOOM_MANUAL_STORE_H_
