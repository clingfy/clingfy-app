#ifndef RUNNER_ENCODING_ENCODER_OUTPUT_PATH_H_
#define RUNNER_ENCODING_ENCODER_OUTPUT_PATH_H_

#include <string>

// Phase 3C output-path helpers.
//
// The Sink Writer needs a fully-qualified `.mp4` path it can create.
// Phase 3C lands the file in `%TEMP%\clingfy_<sanitized_session_id>.mp4`
// — a known location that is guaranteed writable on every Windows host
// and that we know `MFCreateSinkWriterFromURL` will accept.
//
// Phase 3E will replace this with a routing into the real project folder
// (alongside the project manifest + diagnostics). Until then, the helper
// is intentionally trivial so unit tests can pin the sanitization rules
// without dragging in Win32.
namespace clingfy::encoding {

// Sanitize a caller-provided session id so it is safe to use as a
// filename. Replaces anything outside `[A-Za-z0-9._-]` with `_`. Returns
// `"session"` if the input is empty or sanitizes to an empty string.
std::string SanitizeSessionId(const std::string& session_id);

// Build the full `%TEMP%\clingfy_<sanitized>.mp4` path for the given
// session id, using `%TEMP%` from the process environment.
//
// `temp_dir_override` lets unit tests inject a fake `%TEMP%` so the path
// composition is fully testable without mutating the process
// environment.
std::string ResolveTempMp4Path(const std::string& session_id,
                               const std::string& temp_dir_override = "");

// Phase 8.1: the cursor sidecar streams to
// `%TEMP%\clingfy_<sanitized>.cursor.jsonl` during recording (mirroring the temp
// MP4 flow), then the project writer bundles it into `capture/cursor.jsonl`.
// Same sanitization + `temp_dir_override` testability as `ResolveTempMp4Path`.
std::string ResolveTempCursorSidecarPath(const std::string& session_id,
                                         const std::string& temp_dir_override = "");

}  // namespace clingfy::encoding

#endif  // RUNNER_ENCODING_ENCODER_OUTPUT_PATH_H_
