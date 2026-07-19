#include "Capture/Export/audio_sidecar_probe.h"

// mfidl.h must precede mfreadwrite.h (see reorder_audio_pump.h).
#include <mfidl.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include <atomic>
#include <mutex>

namespace clingfy::capture::export_ {

namespace {

using Microsoft::WRL::ComPtr;

constexpr DWORD kNoStream = 0xFFFFFFFFu;

// Idempotent MF startup — the probe runs from export_passthrough BEFORE the
// pipeline's own EnsureMediaFoundationStarted, and from the preview open
// path, so it cannot rely on either having gone first.
void EnsureMediaFoundationStarted() {
  static std::once_flag flag;
  static std::atomic<HRESULT> result{S_OK};
  std::call_once(flag, [] {
    const HRESULT hr = ::MFStartup(MF_VERSION, MFSTARTUP_LITE);
    result.store(hr);
  });
}

}  // namespace

bool ProbeDecodableAudio(const std::wstring& path) {
  if (path.empty()) {
    return false;
  }
  EnsureMediaFoundationStarted();

  ComPtr<IMFSourceReader> reader;
  if (FAILED(::MFCreateSourceReaderFromURL(path.c_str(), nullptr,
                                           reader.GetAddressOf())) ||
      reader == nullptr) {
    return false;
  }

  // First audio stream only, forced to the pipeline's PCM layout — the same
  // negotiation every real consumer (ReorderAudioPump, MeasureSourceAudioPeak)
  // performs, so a passing probe guarantees those opens succeed too.
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
    return false;
  }
  reader->SetStreamSelection(audio_index, TRUE);

  ComPtr<IMFMediaType> pcm_type;
  if (FAILED(::MFCreateMediaType(pcm_type.GetAddressOf()))) {
    return false;
  }
  pcm_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  pcm_type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
  pcm_type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
  pcm_type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, 48'000);
  pcm_type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2);
  if (FAILED(
          reader->SetCurrentMediaType(audio_index, nullptr, pcm_type.Get()))) {
    return false;
  }

  // Decode ONE sample. Immediate EOS (an empty-but-valid container) fails
  // the gate, matching macOS's "nil first sample => not readable".
  DWORD flags = 0;
  LONGLONG timestamp = 0;
  ComPtr<IMFSample> sample;
  if (FAILED(reader->ReadSample(audio_index, 0, nullptr, &flags, &timestamp,
                                sample.GetAddressOf()))) {
    return false;
  }
  return sample != nullptr;
}

}  // namespace clingfy::capture::export_
