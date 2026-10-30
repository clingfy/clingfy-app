#include "Encoding/aac_bitrate_probe.h"

#include <windows.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mftransform.h>
#include <wmcodecdsp.h>
#include <wrl/client.h>

#include <gtest/gtest.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <mutex>

#include "Capture/Export/export_format.h"

// What bitrates does the in-box Microsoft AAC encoder MFT actually take, and
// does it really produce them?
//
// macOS offers 192 / 256 / 320 kbps AAC. Windows used to clamp every tier to
// 192 because nobody had measured the encoder; Microsoft documents only 96 /
// 128 / 160 / 192. Measured on Windows 11 (2026-10-29): it accepts 256 and 320
// at 48 kHz stereo AND produces them (256103 / 320091 bps on white noise). So
// the export asks `AacEncoderAcceptsBitrate` and steps down where an older
// encoder refuses.
namespace clingfy::encoding {
namespace {

using Microsoft::WRL::ComPtr;

void EnsureMfStarted() {
  static std::once_flag flag;
  std::call_once(flag, [] { ::MFStartup(MF_VERSION, MFSTARTUP_LITE); });
}

// Encode `seconds` of full-scale white noise (so the encoder spends its whole
// budget) at `bits_per_second` and return the bitrate it actually produced, in
// bits per second, or -1 when the encoder refused the type.
double MeasuredAacBitrate(std::uint32_t bits_per_second, int seconds) {
  EnsureMfStarted();
  ComPtr<IMFTransform> encoder;
  if (FAILED(::CoCreateInstance(CLSID_AACMFTEncoder, nullptr,
                                CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(encoder.GetAddressOf())))) {
    return -1;
  }
  ComPtr<IMFMediaType> input;
  ::MFCreateMediaType(input.GetAddressOf());
  input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  input->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
  input->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
  input->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, 48'000);
  input->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2);
  input->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, 4);
  input->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 48'000 * 4);
  if (FAILED(encoder->SetInputType(0, input.Get(), 0))) return -1;
  ComPtr<IMFMediaType> output;
  ::MFCreateMediaType(output.GetAddressOf());
  output->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  output->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
  output->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
  output->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, 48'000);
  output->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2);
  output->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, bits_per_second / 8);
  output->SetUINT32(MF_MT_AAC_AUDIO_PROFILE_LEVEL_INDICATION, 0x29);
  if (FAILED(encoder->SetOutputType(0, output.Get(), 0))) return -1;
  encoder->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);

  MFT_OUTPUT_STREAM_INFO info{};
  encoder->GetOutputStreamInfo(0, &info);
  const DWORD out_size = info.cbSize > 0 ? info.cbSize : 8192;
  std::uint64_t encoded_bytes = 0;
  const auto drain = [&] {
    for (;;) {
      ComPtr<IMFSample> sample;
      ComPtr<IMFMediaBuffer> buffer;
      ::MFCreateSample(sample.GetAddressOf());
      ::MFCreateMemoryBuffer(out_size, buffer.GetAddressOf());
      sample->AddBuffer(buffer.Get());
      MFT_OUTPUT_DATA_BUFFER out{};
      out.pSample = sample.Get();
      DWORD status = 0;
      if (encoder->ProcessOutput(0, 1, &out, &status) != S_OK) {
        if (out.pEvents) out.pEvents->Release();
        return;
      }
      if (out.pEvents) out.pEvents->Release();
      DWORD len = 0;
      buffer->GetCurrentLength(&len);
      encoded_bytes += len;
    }
  };

  std::uint32_t rng = 0x12345678u;
  constexpr int kFramesPerChunk = 1024;
  const int chunks = seconds * 48'000 / kFramesPerChunk;
  for (int c = 0; c < chunks; ++c) {
    ComPtr<IMFMediaBuffer> buffer;
    ::MFCreateMemoryBuffer(kFramesPerChunk * 4, buffer.GetAddressOf());
    BYTE* data = nullptr;
    buffer->Lock(&data, nullptr, nullptr);
    auto* pcm = reinterpret_cast<std::int16_t*>(data);
    for (int i = 0; i < kFramesPerChunk * 2; ++i) {
      rng = rng * 1664525u + 1013904223u;
      pcm[i] = static_cast<std::int16_t>(rng >> 16);
    }
    buffer->Unlock();
    buffer->SetCurrentLength(kFramesPerChunk * 4);
    ComPtr<IMFSample> sample;
    ::MFCreateSample(sample.GetAddressOf());
    sample->AddBuffer(buffer.Get());
    sample->SetSampleTime(static_cast<LONGLONG>(c) * kFramesPerChunk *
                          10'000'000 / 48'000);
    sample->SetSampleDuration(static_cast<LONGLONG>(kFramesPerChunk) *
                              10'000'000 / 48'000);
    if (encoder->ProcessInput(0, sample.Get(), 0) == MF_E_NOTACCEPTING) {
      drain();
      encoder->ProcessInput(0, sample.Get(), 0);
    }
    drain();
  }
  encoder->ProcessMessage(MFT_MESSAGE_COMMAND_DRAIN, 0);
  drain();
  const double encoded_seconds =
      static_cast<double>(chunks) * kFramesPerChunk / 48'000.0;
  return encoded_bytes * 8.0 / encoded_seconds;
}

class AacEncoderBitrateTest : public ::testing::Test {
 protected:
  void SetUp() override {
    com_ = SUCCEEDED(::CoInitializeEx(nullptr, COINIT_MULTITHREADED));
    if (!AacEncoderAcceptsBitrate(128'000)) {
      GTEST_SKIP() << "no in-box AAC encoder (Windows N without the Media "
                      "Feature Pack?)";
    }
  }
  void TearDown() override {
    if (com_) {
      ::CoUninitialize();
    }
  }
  bool com_ = false;
};

TEST_F(AacEncoderBitrateTest, TheDocumentedLadderIsAccepted) {
  for (const std::uint32_t bps : {96'000u, 128'000u, 160'000u, 192'000u}) {
    EXPECT_TRUE(AacEncoderAcceptsBitrate(bps)) << bps << " bps";
  }
}

TEST_F(AacEncoderBitrateTest, AnAcceptedRateIsReallyProduced) {
  // Acceptance alone proves nothing: an encoder could take the type and quietly
  // encode at 192. Encode 10 s of white noise (the worst case, so the encoder
  // spends its whole budget) and measure.
  for (const std::uint32_t bps : {192'000u, 256'000u, 320'000u}) {
    if (!AacEncoderAcceptsBitrate(bps)) {
      std::printf("AAC encoder refuses %u bps on this machine\n", bps);
      continue;
    }
    const double produced = MeasuredAacBitrate(bps, 10);
    std::printf("AAC asked %u bps -> produced %.0f bps\n", bps, produced);
    EXPECT_LT(std::fabs(produced - bps) / bps, 0.03)
        << "asked " << bps << " bps, produced " << produced;
  }
}

TEST_F(AacEncoderBitrateTest, EveryTierLandsOnARateTheEncoderTakes) {
  for (const char* quality : {"standard", "high", "best", ""}) {
    const std::uint32_t bps =
        clingfy::capture::export_::ClampAudioBitrateToEncoder(
            clingfy::capture::export_::ResolveAudioBitrateBps(quality),
            AacEncoderAcceptsBitrate);
    EXPECT_TRUE(AacEncoderAcceptsBitrate(bps))
        << "quality=" << quality << " -> " << bps << " bps";
  }
}

TEST_F(AacEncoderBitrateTest, TheProbeAnswersTheSameTwice) {
  // Cached per bitrate: the second call must agree with the first.
  for (const std::uint32_t bps : {192'000u, 320'000u, 384'000u}) {
    EXPECT_EQ(AacEncoderAcceptsBitrate(bps), AacEncoderAcceptsBitrate(bps));
  }
}

}  // namespace
}  // namespace clingfy::encoding
