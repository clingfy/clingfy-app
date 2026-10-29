#include "Encoding/aac_bitrate_probe.h"

#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mftransform.h>
#include <wmcodecdsp.h>
#include <wrl/client.h>

#include <map>
#include <mutex>

namespace clingfy::encoding {

namespace {

using Microsoft::WRL::ComPtr;

bool ProbeEncoder(std::uint32_t bits_per_second) {
  const HRESULT co = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const bool balance = SUCCEEDED(co);
  // MFStartup is refcounted; pairing it here keeps the probe self-contained.
  const bool mf_started = SUCCEEDED(::MFStartup(MF_VERSION, MFSTARTUP_LITE));
  bool accepted = false;
  {
    ComPtr<IMFTransform> encoder;
    if (SUCCEEDED(::CoCreateInstance(CLSID_AACMFTEncoder, nullptr,
                                     CLSCTX_INPROC_SERVER,
                                     IID_PPV_ARGS(encoder.GetAddressOf()))) &&
        encoder != nullptr) {
      ComPtr<IMFMediaType> input;
      ComPtr<IMFMediaType> output;
      if (SUCCEEDED(::MFCreateMediaType(input.GetAddressOf())) &&
          SUCCEEDED(::MFCreateMediaType(output.GetAddressOf()))) {
        // The same input the export feeds the Sink Writer's AAC stream
        // (mf_sink_writer_encoder.cpp ConfigureAudioMediaTypes).
        input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
        input->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
        input->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
        input->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, 48'000);
        input->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2);
        input->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, 4);
        input->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 48'000 * 4);
        output->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
        output->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
        output->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
        output->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, 48'000);
        output->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2);
        output->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND,
                          bits_per_second / 8);
        output->SetUINT32(MF_MT_AAC_AUDIO_PROFILE_LEVEL_INDICATION, 0x29);
        accepted = SUCCEEDED(encoder->SetInputType(0, input.Get(), 0)) &&
                   SUCCEEDED(encoder->SetOutputType(0, output.Get(), 0));
      }
    }
  }
  if (mf_started) {
    ::MFShutdown();
  }
  if (balance) {
    ::CoUninitialize();
  }
  return accepted;
}

}  // namespace

bool AacEncoderAcceptsBitrate(std::uint32_t bits_per_second) {
  static std::mutex mutex;
  static std::map<std::uint32_t, bool> cache;
  {
    const std::lock_guard<std::mutex> lock(mutex);
    if (const auto it = cache.find(bits_per_second); it != cache.end()) {
      return it->second;
    }
  }
  const bool accepted = ProbeEncoder(bits_per_second);
  const std::lock_guard<std::mutex> lock(mutex);
  cache[bits_per_second] = accepted;
  return accepted;
}

}  // namespace clingfy::encoding
