#include "Audio/wasapi_stream_format.h"

#include <ks.h>
#include <ksmedia.h>

namespace clingfy::audio {

WAVEFORMATEXTENSIBLE CanonicalPipelineFormat() {
  WAVEFORMATEXTENSIBLE fmt{};
  // WAVE_FORMAT_EXTENSIBLE rather than plain WAVE_FORMAT_IEEE_FLOAT: shared
  // mode wants the explicit channel mask and sub-format, and the engine is
  // pickier about the plain tag on some drivers.
  fmt.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
  fmt.Format.nChannels = static_cast<WORD>(kPipelineChannelCount);
  fmt.Format.nSamplesPerSec = kPipelineSampleRateHz;
  fmt.Format.wBitsPerSample =
      static_cast<WORD>(kPipelineBytesPerSampleFloat * 8);
  fmt.Format.nBlockAlign = static_cast<WORD>(fmt.Format.nChannels *
                                             kPipelineBytesPerSampleFloat);
  fmt.Format.nAvgBytesPerSec =
      fmt.Format.nSamplesPerSec * fmt.Format.nBlockAlign;
  // cbSize counts only the bytes AFTER the WAVEFORMATEX header. For
  // WAVEFORMATEXTENSIBLE that is exactly 22, and the constant is spelled this
  // way (rather than as a literal) so it stays correct by construction.
  fmt.Format.cbSize =
      static_cast<WORD>(sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX));
  fmt.Samples.wValidBitsPerSample = fmt.Format.wBitsPerSample;
  fmt.dwChannelMask = SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT;
  fmt.SubFormat = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
  return fmt;
}

SharedStreamInit InitializeSharedStream(IAudioClient* client, DWORD base_flags,
                                        REFERENCE_TIME buffer_duration_hns,
                                        const WAVEFORMATEX* mix_format) {
  SharedStreamInit out;
  if (client == nullptr || mix_format == nullptr) {
    out.hr = E_POINTER;
    return out;
  }

  // Already canonical: take the untouched path. Passing the endpoint its own
  // mix format is what shipped before, and AUTOCONVERTPCM would be inert here
  // anyway (the formats are identical), so there is nothing to gain from
  // routing the common case through the conversion branch.
  if (IsPipelineCompatible(Snapshot(mix_format))) {
    out.hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED, base_flags,
                                buffer_duration_hns, 0, mix_format, nullptr);
    out.converted = false;
    return out;
  }

  const WAVEFORMATEXTENSIBLE canonical = CanonicalPipelineFormat();
  out.hr = client->Initialize(
      AUDCLNT_SHAREMODE_SHARED,
      base_flags | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
          AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
      buffer_duration_hns, 0,
      reinterpret_cast<const WAVEFORMATEX*>(&canonical), nullptr);
  out.converted = SUCCEEDED(out.hr);
  return out;
}

}  // namespace clingfy::audio
