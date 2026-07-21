#include "Capture/Export/mic_cleanup.h"

// mfidl.h must precede mfreadwrite.h (see reorder_audio_pump.h).
#include <mfidl.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include <cstdint>
#include <mutex>
#include <vector>

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

}  // namespace

bool ProduceCleanedMic(const std::wstring& mic_path,
                       const std::string& output_path,
                       const std::function<bool()>& is_cancelled) {
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

  clingfy::encoding::AudioSidecarWriter writer;
  if (writer.Open(output_path).has_value()) {
    return false;
  }

  // Decoded mono samples not yet grouped into a 480-frame window. `head` walks
  // forward as frames are consumed; `pending` is compacted when head grows so
  // this stays O(n) instead of erasing from the front each frame.
  std::vector<std::int16_t> pending;
  std::size_t head = 0;
  std::vector<float> denoise_in(frame_size);
  std::vector<float> denoise_out(frame_size);
  std::vector<std::int16_t> stereo(static_cast<std::size_t>(frame_size) * 2);
  std::int64_t frames_written = 0;

  // Denoise `valid` real mono samples starting at `src` (a zero-padded window
  // of exactly frame_size floats) and write them as stereo (mono duplicated to
  // L/R). Returns false on a writer error.
  auto emit = [&](const float* src, int valid) -> bool {
    denoiser.ProcessFrame(src, denoise_out.data());
    for (int i = 0; i < valid; ++i) {
      const std::int16_t s = ClampToInt16(denoise_out[i]);
      stereo[static_cast<std::size_t>(i) * 2] = s;
      stereo[static_cast<std::size_t>(i) * 2 + 1] = s;
    }
    const std::int64_t ts = frames_written * 10'000'000 / kSampleRate;
    if (writer
            .WriteSamples(stereo.data(), static_cast<std::uint32_t>(valid), ts)
            .has_value()) {
      return false;
    }
    frames_written += valid;
    return true;
  };

  bool eos = false;
  while (!eos) {
    if (is_cancelled && is_cancelled()) {
      writer.Cancel();
      return false;
    }
    DWORD flags = 0;
    LONGLONG timestamp = 0;
    ComPtr<IMFSample> sample;
    if (FAILED(reader->ReadSample(audio_index, 0, nullptr, &flags, &timestamp,
                                  sample.GetAddressOf()))) {
      writer.Cancel();
      return false;
    }
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
      eos = true;
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
          const std::size_t n = cur_len / sizeof(std::int16_t);
          pending.insert(pending.end(), s16, s16 + n);
          buffer->Unlock();
        }
      }
    }

    // Emit every complete frame currently buffered.
    while (pending.size() - head >= static_cast<std::size_t>(frame_size)) {
      for (int i = 0; i < frame_size; ++i) {
        denoise_in[i] = static_cast<float>(pending[head + i]);
      }
      if (!emit(denoise_in.data(), frame_size)) {
        writer.Cancel();
        return false;
      }
      head += frame_size;
    }
    // Bound the buffer: drop consumed samples once head runs ahead.
    if (head >= 65'536) {
      pending.erase(pending.begin(), pending.begin() + head);
      head = 0;
    }
  }

  // Final short frame: zero-pad to frame_size, denoise, keep only the real
  // samples so the cleaned track length matches the source.
  const std::size_t remaining = pending.size() - head;
  if (remaining > 0) {
    for (int i = 0; i < frame_size; ++i) {
      denoise_in[i] =
          (static_cast<std::size_t>(i) < remaining)
              ? static_cast<float>(pending[head + static_cast<std::size_t>(i)])
              : 0.0f;
    }
    if (!emit(denoise_in.data(), static_cast<int>(remaining))) {
      writer.Cancel();
      return false;
    }
  }

  return !writer.Finalize().has_value();
}

}  // namespace clingfy::capture::export_
