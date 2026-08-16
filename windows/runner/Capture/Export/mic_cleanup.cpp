#include "Capture/Export/mic_cleanup.h"

// mfidl.h must precede mfreadwrite.h (see reorder_audio_pump.h).
#include <mfidl.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include <algorithm>
#include <cstdint>
#include <mutex>
#include <vector>

#include "Audio/EchoCancel/mic_echo_canceller.h"
#include "Audio/VoiceCleanup/rnnoise_denoiser.h"
#include "Encoding/audio_sidecar_writer.h"

namespace clingfy::capture::export_ {

namespace {

using Microsoft::WRL::ComPtr;

constexpr DWORD kNoStream = 0xFFFFFFFFu;
constexpr int kSampleRate = 48'000;

// Idempotent MF startup (matches audio_sidecar_probe / the pipeline).
void EnsureMediaFoundationStarted() {
  static std::once_flag flag;
  std::call_once(flag, [] { ::MFStartup(MF_VERSION, MFSTARTUP_LITE); });
}

// Select the first audio stream on `reader`, forced to MONO 48 kHz int16 PCM
// (RNNoise is mono; MF down-mixes a stereo sidecar for us). Returns the stream
// index, or kNoStream on failure.
DWORD SelectMonoPcmStream(IMFSourceReader* reader) {
  reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS),
                             FALSE);
  DWORD audio_index = kNoStream;
  for (DWORD i = 0;; ++i) {
    ComPtr<IMFMediaType> native;
    const HRESULT hr = reader->GetNativeMediaType(i, 0, native.GetAddressOf());
    if (hr == MF_E_INVALIDSTREAMNUMBER) {
      break;
    }
    if (FAILED(hr) || native == nullptr) {
      continue;
    }
    GUID major = GUID_NULL;
    if (SUCCEEDED(native->GetGUID(MF_MT_MAJOR_TYPE, &major)) &&
        major == MFMediaType_Audio) {
      audio_index = i;
      break;
    }
  }
  if (audio_index == kNoStream) {
    return kNoStream;
  }
  reader->SetStreamSelection(audio_index, TRUE);

  ComPtr<IMFMediaType> pcm;
  if (FAILED(::MFCreateMediaType(pcm.GetAddressOf()))) {
    return kNoStream;
  }
  pcm->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  pcm->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
  pcm->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
  pcm->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, kSampleRate);
  pcm->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 1);
  if (FAILED(reader->SetCurrentMediaType(audio_index, nullptr, pcm.Get()))) {
    return kNoStream;
  }
  return audio_index;
}

std::int16_t ClampToInt16(float v) {
  if (v > 32767.0f) return 32767;
  if (v < -32768.0f) return -32768;
  return static_cast<std::int16_t>(v);
}

// Decode the whole mono track into `out`. Returns false on a read error or
// cancel.
bool DecodeMonoInt16(IMFSourceReader* reader, DWORD audio_index,
                     const std::function<bool()>& is_cancelled,
                     std::vector<std::int16_t>* out) {
  for (;;) {
    if (is_cancelled && is_cancelled()) {
      return false;
    }
    DWORD flags = 0;
    LONGLONG timestamp = 0;
    ComPtr<IMFSample> sample;
    if (FAILED(reader->ReadSample(audio_index, 0, nullptr, &flags, &timestamp,
                                  sample.GetAddressOf()))) {
      return false;
    }
    if (sample != nullptr) {
      ComPtr<IMFMediaBuffer> buffer;
      if (SUCCEEDED(sample->ConvertToContiguousBuffer(buffer.GetAddressOf())) &&
          buffer != nullptr) {
        BYTE* data = nullptr;
        DWORD cur_len = 0;
        if (SUCCEEDED(buffer->Lock(&data, nullptr, &cur_len)) &&
            data != nullptr) {
          const auto* s16 = reinterpret_cast<const std::int16_t*>(data);
          out->insert(out->end(), s16, s16 + cur_len / sizeof(std::int16_t));
          buffer->Unlock();
        }
      }
    }
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
      return true;
    }
  }
}

}  // namespace

float VoiceCleanupWetMix(const std::string& mode) {
  return mode == "light" ? 0.5f : 1.0f;
}

bool ProduceCleanedMic(const std::wstring& mic_path,
                       const std::string& output_path,
                       const std::function<bool()>& is_cancelled,
                       float wet_mix) {
  if (mic_path.empty() || output_path.empty()) {
    return false;
  }
  EnsureMediaFoundationStarted();

  clingfy::audio::voice_cleanup::RnnoiseDenoiser denoiser;
  if (!denoiser.ok()) {
    return false;
  }
  const int frame_size =
      clingfy::audio::voice_cleanup::RnnoiseDenoiser::FrameSize();  // 480
  // RNNoise's algorithmic latency is a whole 2 frames (20 ms); the denoised
  // stream must be shifted back by this to stay sample-aligned with the source.
  const int latency = 2 * frame_size;
  const float wet = std::clamp(wet_mix, 0.0f, 1.0f);

  ComPtr<IMFSourceReader> reader;
  if (FAILED(::MFCreateSourceReaderFromURL(mic_path.c_str(), nullptr,
                                           reader.GetAddressOf())) ||
      reader == nullptr) {
    return false;
  }
  const DWORD audio_index = SelectMonoPcmStream(reader.Get());
  if (audio_index == kNoStream) {
    return false;
  }

  // Decode the whole mono track: the delay realignment writes frame f's output
  // at f*frame_size - latency, and a partial mix reads the aligned original at
  // the same index, so the full buffer must be materialized (macOS parity).
  std::vector<std::int16_t> src;
  if (!DecodeMonoInt16(reader.Get(), audio_index, is_cancelled, &src)) {
    return false;
  }
  const std::size_t n = src.size();

  clingfy::encoding::AudioSidecarWriter writer;
  if (writer.Open(output_path).has_value()) {
    return false;
  }

  // Denoise into a source-aligned float buffer.
  std::vector<float> output(n, 0.0f);
  if (n > 0) {
    std::vector<float> in_f(frame_size);
    std::vector<float> den_f(frame_size);
    const std::size_t frame_count =
        (n + latency + frame_size - 1) / frame_size;
    const std::size_t prime_frames = latency / frame_size;
    for (std::size_t f = 0; f < frame_count; ++f) {
      if (is_cancelled && is_cancelled()) {
        writer.Cancel();
        return false;
      }
      const std::size_t read = f * frame_size;
      for (int i = 0; i < frame_size; ++i) {
        const std::size_t idx = read + static_cast<std::size_t>(i);
        in_f[i] = idx < n ? static_cast<float>(src[idx]) : 0.0f;
      }
      denoiser.ProcessFrame(in_f.data(), den_f.data());
      if (f < prime_frames) {
        continue;  // priming frames (the lookahead) are dropped
      }
      const std::size_t write = read - static_cast<std::size_t>(latency);
      const std::size_t count = write < n ? std::min<std::size_t>(
                                                frame_size, n - write)
                                          : 0;
      for (std::size_t i = 0; i < count; ++i) {
        output[write + i] = den_f[i];
      }
    }
    // out = wet * denoised + (1 - wet) * original.
    if (wet < 0.9999f) {
      const float dry = 1.0f - wet;
      for (std::size_t i = 0; i < n; ++i) {
        output[i] = wet * output[i] + dry * static_cast<float>(src[i]);
      }
    }
  }

  // Write the aligned mono result as stereo (mono duplicated to L/R), in
  // ~100 ms blocks with monotonic timestamps.
  constexpr std::size_t kBlock = 4'800;
  std::vector<std::int16_t> stereo(kBlock * 2);
  std::size_t written = 0;
  while (written < n) {
    const std::size_t count = std::min(kBlock, n - written);
    for (std::size_t i = 0; i < count; ++i) {
      const std::int16_t s = ClampToInt16(output[written + i]);
      stereo[i * 2] = s;
      stereo[i * 2 + 1] = s;
    }
    const std::int64_t ts =
        static_cast<std::int64_t>(written) * 10'000'000 / kSampleRate;
    if (writer
            .WriteSamples(stereo.data(), static_cast<std::uint32_t>(count), ts)
            .has_value()) {
      writer.Cancel();
      return false;
    }
    written += count;
  }

  return !writer.Finalize().has_value();
}

bool ProduceEchoCancelledMic(const std::wstring& mic_path,
                             const std::wstring& system_path,
                             const std::string& output_path,
                             const std::function<bool()>& is_cancelled,
                             EchoCancelReport* report) {
  if (report != nullptr) {
    *report = EchoCancelReport{};
  }
  if (mic_path.empty() || system_path.empty() || output_path.empty()) {
    return false;
  }
  EnsureMediaFoundationStarted();

  const auto decode = [&](const std::wstring& path,
                          std::vector<std::int16_t>* out) -> bool {
    ComPtr<IMFSourceReader> reader;
    if (FAILED(::MFCreateSourceReaderFromURL(path.c_str(), nullptr,
                                             reader.GetAddressOf())) ||
        reader == nullptr) {
      return false;
    }
    const DWORD index = SelectMonoPcmStream(reader.Get());
    if (index == kNoStream) {
      return false;
    }
    return DecodeMonoInt16(reader.Get(), index, is_cancelled, out);
  };

  std::vector<std::int16_t> mic_pcm;
  std::vector<std::int16_t> system_pcm;
  if (!decode(mic_path, &mic_pcm) || !decode(system_path, &system_pcm)) {
    return false;
  }
  if (is_cancelled && is_cancelled()) {
    return false;
  }

  // NORMALIZE to +/-1.0. Everything else in this file carries int16-VALUED
  // floats (+/-32768), but the canceller's thresholds — the correlation gate,
  // the reference-present floor, the voice floor — are all in +/-1.0 units.
  // Feeding it unnormalized samples would put every envelope thousands of
  // times over those floors and make the gates meaningless.
  constexpr float kToUnit = 1.0f / 32768.0f;
  std::vector<float> mic_unit(mic_pcm.size());
  for (std::size_t i = 0; i < mic_pcm.size(); ++i) {
    mic_unit[i] = static_cast<float>(mic_pcm[i]) * kToUnit;
  }
  std::vector<float> system_unit(system_pcm.size());
  for (std::size_t i = 0; i < system_pcm.size(); ++i) {
    system_unit[i] = static_cast<float>(system_pcm[i]) * kToUnit;
  }

  const clingfy::audio::echo::EchoCancelResult result =
      clingfy::audio::echo::CancelEcho(mic_unit, system_unit);
  if (report != nullptr) {
    report->applied = result.applied;
    report->bleed_correlation = result.bleed_correlation;
    report->delay_ms = result.delay_ms;
    report->reduction_db = result.reduction_db;
  }
  if (!result.applied) {
    // No measurable bleed. Returning false makes the caller keep the ORIGINAL
    // mic file rather than a re-encoded copy of it — cheaper, and it avoids a
    // needless AAC generation loss on the overwhelmingly common headphone
    // recording.
    return false;
  }
  if (is_cancelled && is_cancelled()) {
    return false;
  }

  clingfy::encoding::AudioSidecarWriter writer;
  if (writer.Open(output_path).has_value()) {
    return false;
  }

  const std::size_t n = result.mic.size();
  constexpr std::size_t kBlock = 4'800;
  std::vector<std::int16_t> stereo(kBlock * 2);
  std::size_t written = 0;
  while (written < n) {
    if (is_cancelled && is_cancelled()) {
      writer.Cancel();
      return false;
    }
    const std::size_t count = std::min(kBlock, n - written);
    for (std::size_t i = 0; i < count; ++i) {
      // Back to int16 scale before the shared clamp.
      const std::int16_t s =
          ClampToInt16(result.mic[written + i] * 32768.0f);
      stereo[i * 2] = s;
      stereo[i * 2 + 1] = s;
    }
    const std::int64_t ts =
        static_cast<std::int64_t>(written) * 10'000'000 / kSampleRate;
    if (writer
            .WriteSamples(stereo.data(), static_cast<std::uint32_t>(count), ts)
            .has_value()) {
      writer.Cancel();
      return false;
    }
    written += count;
  }

  return !writer.Finalize().has_value();
}

}  // namespace clingfy::capture::export_
