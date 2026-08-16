#ifndef RUNNER_ENCODING_MF_ENCODER_CONFIG_H_
#define RUNNER_ENCODING_MF_ENCODER_CONFIG_H_

#include <cstdint>
#include <optional>
#include <string>

// Encoder configuration for the Phase 3C Media Foundation Sink Writer
// wrapper.
//
// Kept as a plain struct so the engine can fill it in from the
// `StartRecordingRequest` + the resolved display size, and so it can be
// unit-tested without touching MF.
namespace clingfy::encoding {

// Video codec for the Sink Writer's output stream.
//
// UNLIKE macOS, WHERE THIS IS A FREE CHOICE. AVFoundation always has
// `AVVideoCodecType.hevc`; on Windows an HEVC encoder MFT is hardware- and
// SKU-dependent, so the request has to be probed rather than assumed. See
// `IsHevcEncoderAvailable`.
enum class VideoCodec { kH264, kHevc };

// Map the Dart `codec` wire value ("h264" / "hevc"). Unknown or empty → H.264,
// which is both the safe default and what every Windows export produced before
// codec selection existed.
VideoCodec ParseVideoCodec(const std::string& name);

// Whether this machine can actually encode HEVC.
//
// Enumerates video-encoder MFTs that advertise an HEVC output type. Returns
// false on a box with no hardware HEVC encoder and no software fallback
// installed — a real configuration, not an error, since the codec depends on
// the GPU and (for some paths) the Store "HEVC Video Extensions" package.
//
// Result is cached: MFTEnumEx is not free and the answer cannot change within
// a process's lifetime in any way worth tracking.
bool IsHevcEncoderAvailable();

struct EncoderConfig {
  // Absolute path to the MP4 file the Sink Writer will create.
  // `MFCreateSinkWriterFromURL` requires a fully-qualified URL or file
  // path; relative paths produce confusing E_INVALIDARG errors from
  // somewhere deep inside `mfreadwrite`. The engine resolves this through
  // `encoder_output_path::ResolveTempMp4Path` for Phase 3C; Phase 3E will
  // start routing the file into the real project folder.
  std::string output_path;

  std::uint32_t width = 0;
  std::uint32_t height = 0;
  std::uint32_t fps = 30;

  // ~8 Mbps default. Picked to land between YouTube's recommended 1080p
  // upload bitrate (8-12 Mbps) and the Sink Writer's compressed-but-still
  // honest range. Phase 3D+ may surface this to a quality preset in the
  // settings UI.
  std::uint32_t avg_bitrate_bps = 8'000'000;

  // Maximum frames between IDR keyframes (issue #294). 0 = leave the choice
  // to the encoder MFT, which is what shipped before this field existed.
  //
  // WHY PIN IT: every seek costs a decode from the keyframe AT OR BEFORE the
  // target, so the GOP length is the upper bound on the lead-in for a scrub,
  // a cut-gap jump, a reorder boundary, and an audio-chase reposition alike.
  // Left unpinned, a hardware MFT picks its own — typically 2-4 s on sparse
  // screen recordings, and unbounded in principle — so the preview's seek
  // thresholds have to be sized for the worst case rather than a known one
  // (see kGapSeekThresholdMs / kChaseSeekDeficitMs in preview_engine).
  //
  // `ResolveKeyframeIntervalFrames` supplies the default; see it for why 2 s.
  //
  // NOT a guarantee. MF_MT_MAX_KEYFRAME_SPACING is a HINT some hardware MFTs
  // ignore, and MF_LOW_LATENCY is already TRUE on the writer, which a few
  // encoders read as a licence to shorten the GOP on their own. So this
  // bounds the lead-in on encoders that honour it and changes nothing on
  // those that don't — which is why no seek threshold moves with it. Measure
  // real spacing on device before lowering any of them.
  std::uint32_t keyframe_interval_frames = 0;

  // The codec to encode with. Callers should resolve this through
  // `ResolveVideoCodec` rather than setting kHevc directly, so an unavailable
  // encoder degrades to H.264 instead of failing the export.
  VideoCodec codec = VideoCodec::kH264;

  // Validation. Returns std::nullopt when the config is usable; otherwise
  // a human-readable message describing what's wrong. Kept here so the
  // engine can fail with `BAD_ARGS` before any MF object is created.
  std::optional<std::string> Validate() const;
};

// The keyframe interval to use for a clip at `fps`, in frames (issue #294).
// Pure so both encoder sites and the tests agree without duplicating the rule.
//
// TWO SECONDS, matching what the macOS export already picks
// (`AVVideoMaxKeyFrameIntervalKey = max(fps, 30) * 2`, chosen there for "good
// seek granularity for any downstream reader"). Two seconds is the usual
// streaming-preset GOP: short enough that a seek lead-in stays under the
// preview's frame budget, long enough that the bitrate cost of the extra IDR
// frames stays in the noise for screen content.
//
// `fps` is floored at 30 for the same reason macOS floors it: a 5 fps
// timelapse would otherwise get a 10-frame GOP and pay for keyframes it has
// no seek pressure to justify. Returns 0 for fps 0 (leave it to the encoder)
// so a malformed config degrades to the pre-#294 behaviour rather than
// pinning something nonsensical.
std::uint32_t ResolveKeyframeIntervalFrames(std::uint32_t fps);

// What the export will ACTUALLY encode with, given what the user asked for.
//
// Returns kH264 whenever HEVC was not requested, or was requested on a machine
// with no HEVC encoder. `out_downgraded` (optional) reports the second case
// specifically — the user asked for HEVC and is not getting it — so the caller
// can tell them instead of silently shipping a different codec, which is what
// Windows did for every export before this existed.
VideoCodec ResolveVideoCodec(VideoCodec requested, bool* out_downgraded);

// Audio side of the encoder, added in Phase 3D. Pinned to AAC-LC at
// 48 kHz stereo because that's what the WASAPI mixer produces and what
// the Sink Writer's AAC encoder MFT accepts as a universal input —
// expanding the matrix is future work.
struct AudioEncoderConfig {
  // PCM input: 48 kHz stereo int16. Mirrors the AudioMixer's output.
  std::uint32_t sample_rate_hz = 48'000;
  std::uint16_t channel_count = 2;
  std::uint16_t bits_per_sample = 16;

  // Output AAC bitrate. 128 kbps is the canonical "voice + music"
  // shared-mode default and matches what Windows' own Game Bar uses.
  std::uint32_t avg_bitrate_bps = 128'000;

  std::optional<std::string> Validate() const;
};

}  // namespace clingfy::encoding

#endif  // RUNNER_ENCODING_MF_ENCODER_CONFIG_H_
