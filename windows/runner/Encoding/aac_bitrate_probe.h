#ifndef RUNNER_ENCODING_AAC_BITRATE_PROBE_H_
#define RUNNER_ENCODING_AAC_BITRATE_PROBE_H_

#include <cstdint>

namespace clingfy::encoding {

// Does this machine's in-box AAC encoder MFT (CLSID_AACMFTEncoder) take an
// AAC-LC 48 kHz stereo output at `bits_per_second`, given the 16-bit PCM input
// the export feeds it?
//
// Asked of the encoder rather than assumed: Microsoft documents 96 / 128 /
// 160 / 192 kbps, but the Windows 11 encoder also accepts, and really
// produces, 256 and 320 (measured in aac_encoder_bitrate_test.cpp). The Sink
// Writer would otherwise refuse an unsupported rate late, as an opaque HRESULT
// from AddStream, failing the whole export.
//
// Answers are cached per bitrate for the life of the process (the encoder does
// not change under a running app). Thread-safe; initializes COM on the calling
// thread for the probe if needed and balances it. False when the encoder is
// missing (Windows N without the Media Feature Pack).
bool AacEncoderAcceptsBitrate(std::uint32_t bits_per_second);

}  // namespace clingfy::encoding

#endif  // RUNNER_ENCODING_AAC_BITRATE_PROBE_H_
