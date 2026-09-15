#ifndef RUNNER_CAPTURE_CURSOR_CURSOR_BASE64_H_
#define RUNNER_CAPTURE_CURSOR_CURSOR_BASE64_H_

#include <cstdint>
#include <string>
#include <vector>

// Base64 for the cursor sidecar's sprite pixel payload.
//
// Its own unit, deliberately, and deliberately Win32-free: the sidecar READER
// is pure so it can be unit-tested against literal JSONL, while the sprite
// capture that produces the payload is necessarily full of GDI. Both need the
// codec, so it belongs to neither.
//
// Separately tested because a codec bug here corrupts every recorded cursor
// shape while leaving the file structurally valid — the parse still succeeds,
// the sizes still match, and the only symptom is garbled pixels.
namespace clingfy::capture {

std::string Base64Encode(const std::vector<std::uint8_t>& bytes);

// Ignores padding and any stray whitespace. Returns whatever decoded cleanly;
// callers validate the length against the payload's own declared dimensions
// rather than trusting this.
std::vector<std::uint8_t> Base64Decode(const std::string& text);

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CURSOR_CURSOR_BASE64_H_
