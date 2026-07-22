#ifndef RUNNER_CAPTURE_EXPORT_AUDIO_SIDECAR_PROBE_H_
#define RUNNER_CAPTURE_EXPORT_AUDIO_SIDECAR_PROBE_H_

#include <string>

// Audio separation D7 — the ONE decodability gate, shared by export and
// preview (the Windows analog of macOS `readableAudioAsset`).
//
// A sidecar path in the manifest is necessary but not sufficient: the file
// can be truncated by a crash, zero-length, or not audio at all. The gate
// mirrors macOS's decode-one-sample probe: open a throwaway audio-only
// IMFSourceReader, negotiate PCM, and read a single sample — only a real
// decoded sample passes. Consumers that gate on this probe never have to
// handle a mid-stream open failure; everything else falls back to the
// embedded premixed track in screen.mov.
namespace clingfy::capture::export_ {

// True when `path` names a file whose first audio stream decodes at least
// one PCM sample. Missing/empty path, no audio stream, refused PCM type,
// read failure, and immediate EOS (zero samples) are all false. Never
// throws; cost is one short-lived source reader.
bool ProbeDecodableAudio(const std::wstring& path);

}  // namespace clingfy::capture::export_

#endif  // RUNNER_CAPTURE_EXPORT_AUDIO_SIDECAR_PROBE_H_
