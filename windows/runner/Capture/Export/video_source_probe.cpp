#include "Capture/Export/video_source_probe.h"

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

// Idempotent MF startup. This probe runs from the bridge router, which can be
// the first thing to touch Media Foundation in a session that has not exported
// or previewed yet, so it cannot rely on anyone else having started it.
// Same shape as audio_sidecar_probe's.
void EnsureMediaFoundationStarted() {
  static std::once_flag flag;
  static std::atomic<HRESULT> result{S_OK};
  std::call_once(flag, [] {
    const HRESULT hr = ::MFStartup(MF_VERSION, MFSTARTUP_LITE);
    result.store(hr);
  });
}

}  // namespace

std::optional<PixelSize> ProbeVideoFrameSize(const std::wstring& path) {
  if (path.empty()) {
    return std::nullopt;
  }
  EnsureMediaFoundationStarted();

  ComPtr<IMFSourceReader> reader;
  if (FAILED(::MFCreateSourceReaderFromURL(path.c_str(), nullptr,
                                           reader.GetAddressOf())) ||
      reader == nullptr) {
    return std::nullopt;
  }

  // First video stream only. Deselect everything first so an audio track in
  // the same container cannot be picked up by the index scan below.
  reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS),
                             FALSE);
  DWORD video_index = kNoStream;
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
        major == MFMediaType_Video) {
      video_index = i;
      break;
    }
  }
  if (video_index == kNoStream) {
    return std::nullopt;
  }
  reader->SetStreamSelection(video_index, TRUE);

  // Force RGB32, exactly as export_pipeline does. This matters for more than
  // symmetry: the reader inserts a video processor to convert from NV12, and
  // it is the POST-conversion type whose frame size the compositor sees. Ask
  // the native type instead and a stream whose processor adjusts dimensions
  // would answer with the size nothing downstream ever uses.
  {
    ComPtr<IMFMediaType> rgb_type;
    if (FAILED(::MFCreateMediaType(rgb_type.GetAddressOf()))) {
      return std::nullopt;
    }
    rgb_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    rgb_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
    if (FAILED(reader->SetCurrentMediaType(video_index, nullptr,
                                           rgb_type.Get()))) {
      return std::nullopt;
    }
  }

  UINT32 width = 0;
  UINT32 height = 0;
  ComPtr<IMFMediaType> current;
  if (FAILED(reader->GetCurrentMediaType(video_index, current.GetAddressOf())) ||
      FAILED(::MFGetAttributeSize(current.Get(), MF_MT_FRAME_SIZE, &width,
                                  &height)) ||
      width == 0 || height == 0) {
    return std::nullopt;
  }
  return PixelSize{width, height};
}

}  // namespace clingfy::capture::export_
