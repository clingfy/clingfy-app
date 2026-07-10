// Round-trip integration test for the Slice 2 export pipeline
// (`RenderComposedExport`). It synthesizes a tiny source .mov with the
// real `MfSinkWriterEncoder`, runs the decode → composite → re-encode
// pass, and re-opens the result to assert the output dimensions, frame
// presence, and audio carry-through.
//
// This is a heavy, GPU + Media-Foundation-encoder test by nature: it
// allocates a D3D11 device and drives the hardware H.264 MFT. On a box
// with no usable GPU / MF encoder (some CI runners), device or encoder
// setup fails up front and the test GTEST_SKIPs rather than reporting a
// false failure. It does NOT verify visual correctness (orientation,
// letterbox placement, color) — that is the human smoke-test's job.

#include "Capture/Export/export_pipeline.h"

#include <d3d11.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <gtest/gtest.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "Audio/audio_mixer.h"
#include "Capture/Camera/camera_export_layout.h"
#include "Capture/captured_video_frame.h"
#include "Encoding/mf_encoder_config.h"
#include "Encoding/mf_sink_writer_encoder.h"
#include "Graphics/d3d_device.h"

namespace clingfy::capture::export_ {
namespace {

namespace fs = std::filesystem;
using Microsoft::WRL::ComPtr;

constexpr UINT kSourceWidth = 64;
constexpr UINT kSourceHeight = 48;
constexpr int kFrameCount = 8;
constexpr UINT kFps = 30;

// Solid-color BGRA texture matching the bind flags / format the encoder
// accepts. Color is irrelevant — the test asserts shape, not pixels.
ComPtr<ID3D11Texture2D> MakeSolidTexture(ID3D11Device* dev, std::uint32_t bgra) {
  std::vector<std::uint32_t> pixels(
      static_cast<size_t>(kSourceWidth) * kSourceHeight, bgra);
  D3D11_TEXTURE2D_DESC desc{};
  desc.Width = kSourceWidth;
  desc.Height = kSourceHeight;
  desc.MipLevels = 1;
  desc.ArraySize = 1;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  D3D11_SUBRESOURCE_DATA init{};
  init.pSysMem = pixels.data();
  init.SysMemPitch = kSourceWidth * 4u;
  ComPtr<ID3D11Texture2D> tex;
  if (FAILED(dev->CreateTexture2D(&desc, &init, tex.GetAddressOf()))) {
    return nullptr;
  }
  return tex;
}

// Sized variant of MakeSolidTexture for sources whose dimensions differ from the
// shared 64x48 fixture (e.g. a canvas large enough to hold the camera bubble).
ComPtr<ID3D11Texture2D> MakeSolidTextureSized(ID3D11Device* dev, UINT width,
                                              UINT height, std::uint32_t bgra) {
  std::vector<std::uint32_t> pixels(
      static_cast<size_t>(width) * height, bgra);
  D3D11_TEXTURE2D_DESC desc{};
  desc.Width = width;
  desc.Height = height;
  desc.MipLevels = 1;
  desc.ArraySize = 1;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  D3D11_SUBRESOURCE_DATA init{};
  init.pSysMem = pixels.data();
  init.SysMemPitch = width * 4u;
  ComPtr<ID3D11Texture2D> tex;
  if (FAILED(dev->CreateTexture2D(&desc, &init, tex.GetAddressOf()))) {
    return nullptr;
  }
  return tex;
}

// Write a small source recording. Returns false (with skip_reason set)
// when the environment can't encode, so the caller can GTEST_SKIP.
// `audio_amplitude` (default 0 = silent, preserving existing callers) writes
// a continuous 1 kHz sine at that int16 amplitude across packets so the AAC
// encoder sees a real tone, not DC (which encoders high-pass away) — used by
// the Slice 4 gain/normalize round-trips to measure output level.
bool SynthesizeSource(clingfy::graphics::D3DDevice* device,
                      const std::string& path, bool with_audio,
                      std::string* skip_reason,
                      std::int16_t audio_amplitude = 0) {
  clingfy::encoding::EncoderConfig cfg;
  cfg.output_path = path;
  cfg.width = kSourceWidth;
  cfg.height = kSourceHeight;
  cfg.fps = kFps;

  std::optional<clingfy::encoding::AudioEncoderConfig> audio_cfg;
  if (with_audio) {
    audio_cfg = clingfy::encoding::AudioEncoderConfig{};
  }

  clingfy::encoding::MfSinkWriterEncoder encoder;
  if (auto err = encoder.Open(cfg, *device, audio_cfg)) {
    *skip_reason = "source encoder open failed: " + err->message;
    return false;
  }

  const std::int64_t frame_dur_hns = 10'000'000 / kFps;
  constexpr std::uint32_t kAudioFramesPerPacket = 1024;
  const std::int64_t audio_dur_hns =
      static_cast<std::int64_t>(kAudioFramesPerPacket) * 10'000'000 / 48'000;
  std::uint64_t audio_frame_index = 0;  // for a continuous sine across packets

  for (int i = 0; i < kFrameCount; ++i) {
    clingfy::capture::CapturedVideoFrame frame;
    frame.texture = MakeSolidTexture(device->device(), 0xFF3366CCu);
    if (frame.texture == nullptr) {
      *skip_reason = "could not allocate a source frame texture";
      return false;
    }
    frame.width = kSourceWidth;
    frame.height = kSourceHeight;
    frame.timestamp_hns = static_cast<std::int64_t>(i) * frame_dur_hns;
    if (auto err = encoder.WriteVideoFrame(frame)) {
      *skip_reason = "source WriteVideoFrame failed: " + err->message;
      return false;
    }

    if (with_audio) {
      clingfy::audio::MixedPacket packet;
      packet.frame_count = kAudioFramesPerPacket;
      packet.samples.resize(static_cast<size_t>(kAudioFramesPerPacket) * 2u);
      constexpr double kPi = 3.14159265358979323846;
      for (std::uint32_t f = 0; f < kAudioFramesPerPacket; ++f) {
        const double t =
            static_cast<double>(audio_frame_index + f) / 48'000.0;
        const double sine = std::sin(2.0 * kPi * 1000.0 * t);
        const auto v = static_cast<std::int16_t>(audio_amplitude * sine);
        packet.samples[f * 2u] = v;       // L
        packet.samples[f * 2u + 1u] = v;  // R
      }
      audio_frame_index += kAudioFramesPerPacket;
      packet.timestamp_hns = static_cast<std::int64_t>(i) * audio_dur_hns;
      if (auto err = encoder.WriteAudioPacket(packet)) {
        *skip_reason = "source WriteAudioPacket failed: " + err->message;
        return false;
      }
    }
  }

  if (auto err = encoder.Finalize()) {
    *skip_reason = "source finalize failed: " + err->message;
    return false;
  }
  return true;
}

// Re-open an exported file and report its first video stream's frame size
// plus whether an audio stream is present.
struct ProbeResult {
  bool ok = false;
  UINT32 width = 0;
  UINT32 height = 0;
  bool has_audio = false;
};

ProbeResult ProbeOutput(const std::wstring& path) {
  ProbeResult out;
  ComPtr<IMFSourceReader> reader;
  if (FAILED(::MFCreateSourceReaderFromURL(path.c_str(), nullptr,
                                           reader.GetAddressOf())) ||
      reader == nullptr) {
    return out;
  }
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
    native->GetGUID(MF_MT_MAJOR_TYPE, &major);
    if (major == MFMediaType_Video) {
      ::MFGetAttributeSize(native.Get(), MF_MT_FRAME_SIZE, &out.width,
                           &out.height);
      out.ok = true;
    } else if (major == MFMediaType_Audio) {
      out.has_audio = true;
    }
  }
  return out;
}

fs::path UniqueDir(const std::string& tag) {
  const auto dir = fs::temp_directory_path() / ("clingfy_export_pipeline_" + tag);
  std::error_code ec;
  fs::remove_all(dir, ec);
  fs::create_directories(dir);
  return dir;
}

// Decode the first video frame of `path` to top-down BGRA so a test can
// sample rendered pixels (background color, video placement). Honors the
// 2D-buffer stride sign (RGB32 output can be bottom-up). Returns false when
// the environment can't decode, so the caller GTEST_SKIPs rather than fails.
bool ReadFirstFrameBgra(const std::wstring& path, UINT* out_w, UINT* out_h,
                        std::vector<std::uint32_t>* out_pixels) {
  ComPtr<IMFAttributes> attrs;
  if (FAILED(::MFCreateAttributes(attrs.GetAddressOf(), 1))) {
    return false;
  }
  attrs->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
  ComPtr<IMFSourceReader> reader;
  if (FAILED(::MFCreateSourceReaderFromURL(path.c_str(), attrs.Get(),
                                           reader.GetAddressOf())) ||
      reader == nullptr) {
    return false;
  }

  DWORD video_index = 0xFFFFFFFFu;
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
  if (video_index == 0xFFFFFFFFu) {
    return false;
  }
  reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS),
                             FALSE);
  reader->SetStreamSelection(video_index, TRUE);

  ComPtr<IMFMediaType> rgb;
  if (FAILED(::MFCreateMediaType(rgb.GetAddressOf()))) {
    return false;
  }
  rgb->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  rgb->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
  if (FAILED(reader->SetCurrentMediaType(video_index, nullptr, rgb.Get()))) {
    return false;
  }

  ComPtr<IMFMediaType> current;
  UINT32 w = 0;
  UINT32 h = 0;
  if (FAILED(reader->GetCurrentMediaType(video_index, current.GetAddressOf())) ||
      FAILED(::MFGetAttributeSize(current.Get(), MF_MT_FRAME_SIZE, &w, &h)) ||
      w == 0 || h == 0) {
    return false;
  }

  for (int guard = 0; guard < 64; ++guard) {
    DWORD actual = 0;
    DWORD flags = 0;
    LONGLONG ts = 0;
    ComPtr<IMFSample> sample;
    if (FAILED(reader->ReadSample(video_index, 0, &actual, &flags, &ts,
                                  sample.GetAddressOf()))) {
      return false;
    }
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
      return false;
    }
    if (sample == nullptr) {
      continue;
    }

    const size_t row_bytes = static_cast<size_t>(w) * 4u;
    out_pixels->assign(static_cast<size_t>(w) * h, 0u);
    auto* dest = reinterpret_cast<BYTE*>(out_pixels->data());

    ComPtr<IMFMediaBuffer> raw;
    if (FAILED(sample->GetBufferByIndex(0, raw.GetAddressOf())) ||
        raw == nullptr) {
      return false;
    }
    ComPtr<IMF2DBuffer> buffer2d;
    if (SUCCEEDED(raw.As(&buffer2d)) && buffer2d != nullptr) {
      BYTE* scan0 = nullptr;
      LONG stride = 0;
      if (FAILED(buffer2d->Lock2D(&scan0, &stride)) || scan0 == nullptr) {
        return false;
      }
      for (UINT row = 0; row < h; ++row) {
        std::memcpy(dest + row * row_bytes,
                    scan0 + static_cast<LONG>(row) * stride, row_bytes);
      }
      buffer2d->Unlock2D();
    } else {
      ComPtr<IMFMediaBuffer> contig;
      if (FAILED(sample->ConvertToContiguousBuffer(contig.GetAddressOf())) ||
          contig == nullptr) {
        return false;
      }
      BYTE* data = nullptr;
      DWORD max_len = 0;
      DWORD cur_len = 0;
      if (FAILED(contig->Lock(&data, &max_len, &cur_len)) || data == nullptr) {
        return false;
      }
      std::memcpy(dest, data, std::min<size_t>(cur_len, row_bytes * h));
      contig->Unlock();
    }
    *out_w = w;
    *out_h = h;
    return true;
  }
  return false;
}

// Editing port (clips, 3b-2a): a two-color source — the first half of the
// frames RED, the second half BLUE — so a decoded output frame's dominant
// channel reveals which SOURCE half it came from. That lets a reorder test
// prove the export read a LATER source window before an EARLIER one.
bool SynthesizeHalvesSource(clingfy::graphics::D3DDevice* device,
                            const std::string& path, std::string* skip_reason) {
  clingfy::encoding::EncoderConfig cfg;
  cfg.output_path = path;
  cfg.width = kSourceWidth;
  cfg.height = kSourceHeight;
  cfg.fps = kFps;
  clingfy::encoding::MfSinkWriterEncoder encoder;
  if (auto err = encoder.Open(cfg, *device, std::nullopt)) {
    *skip_reason = "halves source encoder open failed: " + err->message;
    return false;
  }
  const std::int64_t frame_dur_hns = 10'000'000 / kFps;
  for (int i = 0; i < kFrameCount; ++i) {
    // 0xAARRGGBB: red = 0xFFFF0000, blue = 0xFF0000FF.
    const std::uint32_t color =
        (i < kFrameCount / 2) ? 0xFFFF0000u : 0xFF0000FFu;
    clingfy::capture::CapturedVideoFrame frame;
    frame.texture = MakeSolidTexture(device->device(), color);
    if (frame.texture == nullptr) {
      *skip_reason = "could not allocate a halves source frame";
      return false;
    }
    frame.width = kSourceWidth;
    frame.height = kSourceHeight;
    frame.timestamp_hns = static_cast<std::int64_t>(i) * frame_dur_hns;
    if (auto err = encoder.WriteVideoFrame(frame)) {
      *skip_reason = "halves source WriteVideoFrame failed: " + err->message;
      return false;
    }
  }
  if (auto err = encoder.Finalize()) {
    *skip_reason = "halves source finalize failed: " + err->message;
    return false;
  }
  return true;
}

// Decode every video frame of `path` and record its CENTER pixel as 0xAARRGGBB
// (the center is video content, not letterbox). Returns false when the
// environment can't decode, so the caller GTEST_SKIPs.
bool ReadFrameCenterColors(const std::wstring& path,
                           std::vector<std::uint32_t>* out_colors) {
  out_colors->clear();
  ComPtr<IMFAttributes> attrs;
  if (FAILED(::MFCreateAttributes(attrs.GetAddressOf(), 1))) {
    return false;
  }
  attrs->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
  ComPtr<IMFSourceReader> reader;
  if (FAILED(::MFCreateSourceReaderFromURL(path.c_str(), attrs.Get(),
                                           reader.GetAddressOf())) ||
      reader == nullptr) {
    return false;
  }
  DWORD video_index = 0xFFFFFFFFu;
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
  if (video_index == 0xFFFFFFFFu) {
    return false;
  }
  reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS),
                             FALSE);
  reader->SetStreamSelection(video_index, TRUE);
  ComPtr<IMFMediaType> rgb;
  if (FAILED(::MFCreateMediaType(rgb.GetAddressOf()))) {
    return false;
  }
  rgb->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  rgb->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
  if (FAILED(reader->SetCurrentMediaType(video_index, nullptr, rgb.Get()))) {
    return false;
  }
  ComPtr<IMFMediaType> current;
  UINT32 w = 0;
  UINT32 h = 0;
  if (FAILED(reader->GetCurrentMediaType(video_index, current.GetAddressOf())) ||
      FAILED(::MFGetAttributeSize(current.Get(), MF_MT_FRAME_SIZE, &w, &h)) ||
      w == 0 || h == 0) {
    return false;
  }
  const size_t row_bytes = static_cast<size_t>(w) * 4u;
  std::vector<std::uint32_t> frame(static_cast<size_t>(w) * h, 0u);
  for (int guard = 0; guard < 256; ++guard) {
    DWORD actual = 0;
    DWORD flags = 0;
    LONGLONG ts = 0;
    ComPtr<IMFSample> sample;
    if (FAILED(reader->ReadSample(video_index, 0, &actual, &flags, &ts,
                                  sample.GetAddressOf()))) {
      return false;
    }
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
      break;
    }
    if (sample == nullptr) {
      continue;
    }
    auto* dest = reinterpret_cast<BYTE*>(frame.data());
    ComPtr<IMFMediaBuffer> raw;
    if (FAILED(sample->GetBufferByIndex(0, raw.GetAddressOf())) ||
        raw == nullptr) {
      return false;
    }
    ComPtr<IMF2DBuffer> buffer2d;
    if (SUCCEEDED(raw.As(&buffer2d)) && buffer2d != nullptr) {
      BYTE* scan0 = nullptr;
      LONG stride = 0;
      if (FAILED(buffer2d->Lock2D(&scan0, &stride)) || scan0 == nullptr) {
        return false;
      }
      for (UINT row = 0; row < h; ++row) {
        std::memcpy(dest + row * row_bytes,
                    scan0 + static_cast<LONG>(row) * stride, row_bytes);
      }
      buffer2d->Unlock2D();
    } else {
      ComPtr<IMFMediaBuffer> contig;
      if (FAILED(sample->ConvertToContiguousBuffer(contig.GetAddressOf())) ||
          contig == nullptr) {
        return false;
      }
      BYTE* data = nullptr;
      DWORD max_len = 0;
      DWORD cur_len = 0;
      if (FAILED(contig->Lock(&data, &max_len, &cur_len)) || data == nullptr) {
        return false;
      }
      std::memcpy(dest, data, std::min<size_t>(cur_len, row_bytes * h));
      contig->Unlock();
    }
    const size_t center = static_cast<size_t>(h / 2) * w + (w / 2);
    out_colors->push_back(frame[center]);
  }
  return !out_colors->empty();
}

// Decode the exported audio track to 48 kHz stereo int16 PCM and report its
// peak (0..1) and RMS (raw int16 units). Mirrors ReadFirstFrameBgra: returns
// ok=false when the environment can't decode so the caller GTEST_SKIPs. Used
// by the Slice 4 gain round-trips to compare OUTPUT-vs-OUTPUT levels (which
// cancels the shared AAC loss); never assert against the source absolutely.
struct AudioStats {
  bool ok = false;
  double peak = 0.0;  // max |sample| / 32767
  double rms = 0.0;   // sqrt(mean(sample^2)) in raw int16 units
  std::uint64_t samples = 0;
};

AudioStats ReadAudioPeakRms(const std::wstring& path) {
  AudioStats out;
  ComPtr<IMFSourceReader> reader;
  if (FAILED(::MFCreateSourceReaderFromURL(path.c_str(), nullptr,
                                           reader.GetAddressOf())) ||
      reader == nullptr) {
    return out;
  }
  DWORD audio_index = 0xFFFFFFFFu;
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
  if (audio_index == 0xFFFFFFFFu) {
    return out;
  }
  reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS),
                             FALSE);
  reader->SetStreamSelection(audio_index, TRUE);

  ComPtr<IMFMediaType> pcm;
  if (FAILED(::MFCreateMediaType(pcm.GetAddressOf()))) {
    return out;
  }
  pcm->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  pcm->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
  pcm->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
  pcm->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, 48'000);
  pcm->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2);
  if (FAILED(reader->SetCurrentMediaType(audio_index, nullptr, pcm.Get()))) {
    return out;
  }

  double sum_sq = 0.0;
  double peak = 0.0;
  std::uint64_t total = 0;
  for (;;) {
    DWORD flags = 0;
    LONGLONG ts = 0;
    ComPtr<IMFSample> sample;
    if (FAILED(reader->ReadSample(audio_index, 0, nullptr, &flags, &ts,
                                  sample.GetAddressOf()))) {
      return out;
    }
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
      break;
    }
    if (sample == nullptr) {
      continue;
    }
    ComPtr<IMFMediaBuffer> buffer;
    if (FAILED(sample->ConvertToContiguousBuffer(buffer.GetAddressOf())) ||
        buffer == nullptr) {
      continue;
    }
    BYTE* data = nullptr;
    DWORD max_len = 0;
    DWORD cur_len = 0;
    if (SUCCEEDED(buffer->Lock(&data, &max_len, &cur_len)) && data != nullptr &&
        cur_len > 0) {
      const auto* s16 = reinterpret_cast<const std::int16_t*>(data);
      const std::uint64_t n = cur_len / sizeof(std::int16_t);
      for (std::uint64_t k = 0; k < n; ++k) {
        const double v = static_cast<double>(s16[k]);
        const double a = std::abs(v);
        if (a > peak) {
          peak = a;
        }
        sum_sq += v * v;
      }
      total += n;
    }
    if (data != nullptr) {
      buffer->Unlock();
    }
  }
  if (total == 0) {
    return out;
  }
  out.ok = true;
  out.samples = total;
  out.peak = peak / 32767.0;
  out.rms = std::sqrt(sum_sq / static_cast<double>(total));
  return out;
}

// Decode the whole exported audio track to interleaved 48 kHz stereo int16 PCM.
// Lets a test measure the level of a specific EDITED-time window (frame index
// = ms * 48) to prove reorder-audio ordering + silence-fill. Returns false when
// the environment can't decode, so the caller GTEST_SKIPs.
bool ReadAllAudioPcm(const std::wstring& path,
                     std::vector<std::int16_t>* out) {
  out->clear();
  ComPtr<IMFSourceReader> reader;
  if (FAILED(::MFCreateSourceReaderFromURL(path.c_str(), nullptr,
                                           reader.GetAddressOf())) ||
      reader == nullptr) {
    return false;
  }
  DWORD audio_index = 0xFFFFFFFFu;
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
  if (audio_index == 0xFFFFFFFFu) {
    return false;
  }
  reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS),
                             FALSE);
  reader->SetStreamSelection(audio_index, TRUE);
  ComPtr<IMFMediaType> pcm;
  if (FAILED(::MFCreateMediaType(pcm.GetAddressOf()))) {
    return false;
  }
  pcm->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  pcm->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
  pcm->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
  pcm->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, 48'000);
  pcm->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2);
  if (FAILED(reader->SetCurrentMediaType(audio_index, nullptr, pcm.Get()))) {
    return false;
  }
  for (;;) {
    DWORD flags = 0;
    LONGLONG ts = 0;
    ComPtr<IMFSample> sample;
    if (FAILED(reader->ReadSample(audio_index, 0, nullptr, &flags, &ts,
                                  sample.GetAddressOf()))) {
      return false;
    }
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
      break;
    }
    if (sample == nullptr) {
      continue;
    }
    ComPtr<IMFMediaBuffer> buffer;
    if (FAILED(sample->ConvertToContiguousBuffer(buffer.GetAddressOf())) ||
        buffer == nullptr) {
      continue;
    }
    BYTE* data = nullptr;
    DWORD max_len = 0;
    DWORD cur_len = 0;
    if (SUCCEEDED(buffer->Lock(&data, &max_len, &cur_len)) && data != nullptr &&
        cur_len > 0) {
      const auto* s16 = reinterpret_cast<const std::int16_t*>(data);
      out->insert(out->end(), s16, s16 + cur_len / sizeof(std::int16_t));
    }
    if (data != nullptr) {
      buffer->Unlock();
    }
  }
  return !out->empty();
}

// RMS (raw int16 units) of an EDITED-time window [start_ms, end_ms) of an
// interleaved stereo PCM buffer (48 kHz). Frame index = ms * 48.
double AudioWindowRms(const std::vector<std::int16_t>& pcm, std::int64_t start_ms,
                      std::int64_t end_ms) {
  const std::int64_t f0 = start_ms * 48;
  const std::int64_t f1 = end_ms * 48;
  double sum_sq = 0.0;
  std::int64_t n = 0;
  for (std::int64_t f = f0; f < f1; ++f) {
    for (std::int64_t c = 0; c < 2; ++c) {
      const std::size_t idx = static_cast<std::size_t>(f * 2 + c);
      if (idx < pcm.size()) {
        const double v = static_cast<double>(pcm[idx]);
        sum_sq += v * v;
        ++n;
      }
    }
  }
  return n > 0 ? std::sqrt(sum_sq / static_cast<double>(n)) : 0.0;
}

// A reorder-audio fixture: video halves (red/blue, so the reorder is visible)
// PLUS an audio tone that is LOUD only in the FIRST source half and SILENT in
// the second. `frames` at kFps → ~frames*33 ms of video; one 1024-frame audio
// packet per video frame → ~frames*21 ms of audio (audio deliberately runs
// shorter than video, exercising silence-fill). `half_ms` is the source-time
// boundary where the tone switches off.
bool SynthesizeReorderAudioSource(clingfy::graphics::D3DDevice* device,
                                  const std::string& path, int frames,
                                  std::int64_t half_ms,
                                  std::string* skip_reason) {
  clingfy::encoding::EncoderConfig cfg;
  cfg.output_path = path;
  cfg.width = kSourceWidth;
  cfg.height = kSourceHeight;
  cfg.fps = kFps;
  clingfy::encoding::MfSinkWriterEncoder encoder;
  clingfy::encoding::AudioEncoderConfig audio_cfg;
  if (auto err = encoder.Open(cfg, *device, audio_cfg)) {
    *skip_reason = "reorder-audio source encoder open failed: " + err->message;
    return false;
  }
  const std::int64_t frame_dur_hns = 10'000'000 / kFps;
  constexpr std::uint32_t kAudioFramesPerPacket = 1024;
  const std::int64_t audio_dur_hns =
      static_cast<std::int64_t>(kAudioFramesPerPacket) * 10'000'000 / 48'000;
  std::uint64_t audio_frame_index = 0;
  constexpr double kPi = 3.14159265358979323846;
  for (int i = 0; i < frames; ++i) {
    const std::uint32_t color =
        (i < frames / 2) ? 0xFFFF0000u : 0xFF0000FFu;  // red then blue
    clingfy::capture::CapturedVideoFrame frame;
    frame.texture = MakeSolidTexture(device->device(), color);
    if (frame.texture == nullptr) {
      *skip_reason = "could not allocate a reorder-audio source frame";
      return false;
    }
    frame.width = kSourceWidth;
    frame.height = kSourceHeight;
    frame.timestamp_hns = static_cast<std::int64_t>(i) * frame_dur_hns;
    if (auto err = encoder.WriteVideoFrame(frame)) {
      *skip_reason = "reorder-audio source WriteVideoFrame failed: " +
                     err->message;
      return false;
    }
    clingfy::audio::MixedPacket packet;
    packet.frame_count = kAudioFramesPerPacket;
    packet.samples.resize(static_cast<size_t>(kAudioFramesPerPacket) * 2u);
    for (std::uint32_t f = 0; f < kAudioFramesPerPacket; ++f) {
      const std::int64_t sample_ms =
          static_cast<std::int64_t>((audio_frame_index + f) * 1000 / 48'000);
      const double t =
          static_cast<double>(audio_frame_index + f) / 48'000.0;
      // Loud in the first source half, silent after `half_ms`.
      const double amp = sample_ms < half_ms ? 8000.0 : 0.0;
      const auto v =
          static_cast<std::int16_t>(amp * std::sin(2.0 * kPi * 1000.0 * t));
      packet.samples[f * 2u] = v;
      packet.samples[f * 2u + 1u] = v;
    }
    audio_frame_index += kAudioFramesPerPacket;
    packet.timestamp_hns = static_cast<std::int64_t>(i) * audio_dur_hns;
    if (auto err = encoder.WriteAudioPacket(packet)) {
      *skip_reason = "reorder-audio source WriteAudioPacket failed: " +
                     err->message;
      return false;
    }
  }
  if (auto err = encoder.Finalize()) {
    *skip_reason = "reorder-audio source finalize failed: " + err->message;
    return false;
  }
  return true;
}

// A sized, two-color halves source: the first half of the frames `color_first`,
// the second `color_second` (0xAARRGGBB). Generalizes SynthesizeHalvesSource so
// the camera-under-reorder test can use a canvas large enough for the camera
// bubble (min 96 px side) AND give the camera a time-varying color.
bool SynthesizeColorHalvesSource(clingfy::graphics::D3DDevice* device,
                                 const std::string& path, UINT width,
                                 UINT height, std::uint32_t color_first,
                                 std::uint32_t color_second,
                                 std::string* skip_reason) {
  clingfy::encoding::EncoderConfig cfg;
  cfg.output_path = path;
  cfg.width = width;
  cfg.height = height;
  cfg.fps = kFps;
  clingfy::encoding::MfSinkWriterEncoder encoder;
  if (auto err = encoder.Open(cfg, *device, std::nullopt)) {
    *skip_reason = "color-halves source encoder open failed: " + err->message;
    return false;
  }
  const std::int64_t frame_dur_hns = 10'000'000 / kFps;
  for (int i = 0; i < kFrameCount; ++i) {
    const std::uint32_t color =
        (i < kFrameCount / 2) ? color_first : color_second;
    clingfy::capture::CapturedVideoFrame frame;
    frame.texture = MakeSolidTextureSized(device->device(), width, height, color);
    if (frame.texture == nullptr) {
      *skip_reason = "could not allocate a color-halves source frame";
      return false;
    }
    frame.width = width;
    frame.height = height;
    frame.timestamp_hns = static_cast<std::int64_t>(i) * frame_dur_hns;
    if (auto err = encoder.WriteVideoFrame(frame)) {
      *skip_reason = "color-halves source WriteVideoFrame failed: " +
                     err->message;
      return false;
    }
  }
  if (auto err = encoder.Finalize()) {
    *skip_reason = "color-halves source finalize failed: " + err->message;
    return false;
  }
  return true;
}

// Decode every video frame of `path` and record the color (0xAARRGGBB) at the
// pixel nearest (`px`, `py`), clamped into the frame. Like ReadFrameCenterColors
// but samples an arbitrary point — used to read the CAMERA bubble (a corner),
// not the screen (the center). Returns false when decode fails.
bool ReadFramePixelColors(const std::wstring& path, int px, int py,
                          std::vector<std::uint32_t>* out_colors) {
  out_colors->clear();
  ComPtr<IMFAttributes> attrs;
  if (FAILED(::MFCreateAttributes(attrs.GetAddressOf(), 1))) {
    return false;
  }
  attrs->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
  ComPtr<IMFSourceReader> reader;
  if (FAILED(::MFCreateSourceReaderFromURL(path.c_str(), attrs.Get(),
                                           reader.GetAddressOf())) ||
      reader == nullptr) {
    return false;
  }
  DWORD video_index = 0xFFFFFFFFu;
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
  if (video_index == 0xFFFFFFFFu) {
    return false;
  }
  reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS),
                             FALSE);
  reader->SetStreamSelection(video_index, TRUE);
  ComPtr<IMFMediaType> rgb;
  if (FAILED(::MFCreateMediaType(rgb.GetAddressOf()))) {
    return false;
  }
  rgb->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  rgb->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
  if (FAILED(reader->SetCurrentMediaType(video_index, nullptr, rgb.Get()))) {
    return false;
  }
  ComPtr<IMFMediaType> current;
  UINT32 w = 0;
  UINT32 h = 0;
  if (FAILED(reader->GetCurrentMediaType(video_index, current.GetAddressOf())) ||
      FAILED(::MFGetAttributeSize(current.Get(), MF_MT_FRAME_SIZE, &w, &h)) ||
      w == 0 || h == 0) {
    return false;
  }
  const int sx = std::min<int>(std::max<int>(px, 0), static_cast<int>(w) - 1);
  const int sy = std::min<int>(std::max<int>(py, 0), static_cast<int>(h) - 1);
  const size_t row_bytes = static_cast<size_t>(w) * 4u;
  std::vector<std::uint32_t> frame(static_cast<size_t>(w) * h, 0u);
  for (int guard = 0; guard < 256; ++guard) {
    DWORD actual = 0;
    DWORD flags = 0;
    LONGLONG ts = 0;
    ComPtr<IMFSample> sample;
    if (FAILED(reader->ReadSample(video_index, 0, &actual, &flags, &ts,
                                  sample.GetAddressOf()))) {
      return false;
    }
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
      break;
    }
    if (sample == nullptr) {
      continue;
    }
    auto* dest = reinterpret_cast<BYTE*>(frame.data());
    ComPtr<IMFMediaBuffer> raw;
    if (FAILED(sample->GetBufferByIndex(0, raw.GetAddressOf())) ||
        raw == nullptr) {
      return false;
    }
    ComPtr<IMF2DBuffer> buffer2d;
    if (SUCCEEDED(raw.As(&buffer2d)) && buffer2d != nullptr) {
      BYTE* scan0 = nullptr;
      LONG stride = 0;
      if (FAILED(buffer2d->Lock2D(&scan0, &stride)) || scan0 == nullptr) {
        return false;
      }
      for (UINT row = 0; row < h; ++row) {
        std::memcpy(dest + row * row_bytes,
                    scan0 + static_cast<LONG>(row) * stride, row_bytes);
      }
      buffer2d->Unlock2D();
    } else {
      ComPtr<IMFMediaBuffer> contig;
      if (FAILED(sample->ConvertToContiguousBuffer(contig.GetAddressOf())) ||
          contig == nullptr) {
        return false;
      }
      BYTE* data = nullptr;
      DWORD max_len = 0;
      DWORD cur_len = 0;
      if (FAILED(contig->Lock(&data, &max_len, &cur_len)) || data == nullptr) {
        return false;
      }
      std::memcpy(dest, data, std::min<size_t>(cur_len, row_bytes * h));
      contig->Unlock();
    }
    out_colors->push_back(frame[static_cast<size_t>(sy) * w + sx]);
  }
  return !out_colors->empty();
}

// True when the file begins with a GIF signature ("GIF87a"/"GIF89a"). Media
// Foundation cannot open a .gif, so GIF output is validated with this magic-byte
// check plus the WIC probe below rather than ProbeOutput / ReadFirstFrameBgra.
bool FileStartsWithGifMagic(const std::string& path) {
  std::ifstream f(fs::u8path(path), std::ios::binary);
  char header[6] = {0};
  f.read(header, sizeof(header));
  if (f.gcount() < static_cast<std::streamsize>(sizeof(header))) {
    return false;
  }
  return std::memcmp(header, "GIF87a", 6) == 0 ||
         std::memcmp(header, "GIF89a", 6) == 0;
}

// Decode an exported .gif with WIC and report its frame count + first-frame
// size. Returns ok=false when WIC can't open the file. COM is initialized
// per-call and balanced; the WIC interfaces are released before CoUninitialize.
struct GifProbeResult {
  bool ok = false;
  UINT width = 0;
  UINT height = 0;
  UINT frame_count = 0;
};

GifProbeResult ProbeGif(const std::wstring& path) {
  GifProbeResult out;
  const HRESULT co = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const bool balance = SUCCEEDED(co);
  {
    ComPtr<IWICImagingFactory> factory;
    if (SUCCEEDED(::CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                     CLSCTX_INPROC_SERVER,
                                     IID_PPV_ARGS(factory.GetAddressOf()))) &&
        factory != nullptr) {
      ComPtr<IWICBitmapDecoder> decoder;
      if (SUCCEEDED(factory->CreateDecoderFromFilename(
              path.c_str(), nullptr, GENERIC_READ,
              WICDecodeMetadataCacheOnDemand, decoder.GetAddressOf())) &&
          decoder != nullptr) {
        UINT count = 0;
        if (SUCCEEDED(decoder->GetFrameCount(&count))) {
          out.frame_count = count;
          ComPtr<IWICBitmapFrameDecode> frame;
          if (count > 0 &&
              SUCCEEDED(decoder->GetFrame(0, frame.GetAddressOf())) &&
              frame != nullptr) {
            UINT w = 0;
            UINT h = 0;
            if (SUCCEEDED(frame->GetSize(&w, &h))) {
              out.width = w;
              out.height = h;
              out.ok = true;
            }
          }
        }
      }
    }
  }
  if (balance) {
    ::CoUninitialize();
  }
  return out;
}

TEST(ExportPipelineTest, VideoOnlyRoundTripProducesTargetResolution) {
  clingfy::graphics::D3DDevice device;
  if (device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }
  const auto dir = UniqueDir("video");
  const auto source = (dir / "source.mov").u8string();
  const auto dest = (dir / "out.mov").u8string();

  std::string skip_reason;
  if (!SynthesizeSource(&device, source, /*with_audio=*/false, &skip_reason)) {
    GTEST_SKIP() << skip_reason;
  }

  RenderRequest request;
  request.source_video_path = fs::u8path(source).wstring();
  request.destination_path = dest;
  request.layout = "square11";   // 64x48 -> 64x64 (square, auto resolution)
  request.resolution = "auto";
  request.fit = "fit";
  request.fps_hint = kFps;

  const RenderResult result = RenderComposedExport(request);
  ASSERT_TRUE(result.ok) << result.message;
  EXPECT_EQ(result.output_width, 64u);
  EXPECT_EQ(result.output_height, 64u);
  EXPECT_GT(result.video_frames_written, 0u);
  EXPECT_FALSE(result.had_audio);
  ASSERT_TRUE(fs::exists(fs::u8path(dest)));

  const ProbeResult probe = ProbeOutput(fs::u8path(dest).wstring());
  ASSERT_TRUE(probe.ok) << "exported file is not a readable video";
  EXPECT_EQ(probe.width, 64u);
  EXPECT_EQ(probe.height, 64u);

  std::error_code ec;
  fs::remove_all(dir, ec);
}

TEST(ExportPipelineTest, CarriesSourceAudioThroughTheReEncode) {
  clingfy::graphics::D3DDevice device;
  if (device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }
  const auto dir = UniqueDir("audio");
  const auto source = (dir / "source.mov").u8string();
  const auto dest = (dir / "out.mov").u8string();

  std::string skip_reason;
  if (!SynthesizeSource(&device, source, /*with_audio=*/true, &skip_reason)) {
    GTEST_SKIP() << skip_reason;
  }

  RenderRequest request;
  request.source_video_path = fs::u8path(source).wstring();
  request.destination_path = dest;
  request.layout = "youtube169";  // forces a real reframe (non-identity)
  request.resolution = "auto";
  request.fit = "fit";
  request.fps_hint = kFps;

  const RenderResult result = RenderComposedExport(request);
  ASSERT_TRUE(result.ok) << result.message;
  EXPECT_GT(result.video_frames_written, 0u);
  EXPECT_TRUE(result.had_audio);
  EXPECT_GT(result.audio_packets_written, 0u);

  const ProbeResult probe = ProbeOutput(fs::u8path(dest).wstring());
  ASSERT_TRUE(probe.ok);
  EXPECT_TRUE(probe.has_audio)
      << "audio track was dropped during the re-encode";

  std::error_code ec;
  fs::remove_all(dir, ec);
}

TEST(ExportPipelineTest, FillsBackgroundColorAndDrawsVideoOverIt) {
  // Slice 3 round-trip: a square11 reframe of a 64x48 source leaves
  // letterbox bars, padding adds a margin, the background color fills both,
  // and the video is drawn with rounded corners on top. Three pixel samples
  // each pin a distinct effect so a regression in any one fails: a left
  // padding-margin pixel (red only if padding reached the composite), the
  // center (the source video over the bg), and a corner cut-away pixel (red
  // only if the rounded clip carved the corner back to the background). A
  // large corner radius makes the cut-away unambiguous, and H.264 loss is
  // absorbed by comparing dominant channels (red bg vs blue-ish source)
  // with a wide tolerance.
  clingfy::graphics::D3DDevice device;
  if (device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }
  const auto dir = UniqueDir("style");
  const auto source = (dir / "source.mov").u8string();
  const auto dest = (dir / "out.mov").u8string();

  std::string skip_reason;
  if (!SynthesizeSource(&device, source, /*with_audio=*/false, &skip_reason)) {
    GTEST_SKIP() << skip_reason;
  }

  RenderRequest request;
  request.source_video_path = fs::u8path(source).wstring();
  request.destination_path = dest;
  request.layout = "square11";  // 64x48 -> 64x64 (top/bottom letterbox bars)
  request.resolution = "auto";
  request.fit = "fit";
  request.fps_hint = kFps;
  request.padding = 6.0;
  request.corner_radius = 40.0;  // clamps to min(52,39)/2 = 19.5 px
  request.background_color = std::int64_t{0xFFFF0000};  // opaque red

  const RenderResult result = RenderComposedExport(request);
  ASSERT_TRUE(result.ok) << result.message;
  EXPECT_EQ(result.output_width, 64u);
  EXPECT_EQ(result.output_height, 64u);
  EXPECT_GT(result.video_frames_written, 0u);

  UINT w = 0;
  UINT h = 0;
  std::vector<std::uint32_t> pixels;
  if (!ReadFirstFrameBgra(fs::u8path(dest).wstring(), &w, &h, &pixels)) {
    GTEST_SKIP() << "could not decode the exported frame for pixel readback";
  }
  ASSERT_EQ(w, 64u);
  ASSERT_EQ(h, 64u);

  // BGRA-in-uint32 reads back as 0xAARRGGBB: R at bit 16, B at bit 0.
  const auto chan = [](std::uint32_t px, int shift) {
    return static_cast<int>((px >> shift) & 0xFFu);
  };
  // Padding: a mid-height pixel at x=2 is left of the padded content edge
  // (x=6), so it is background red. Without padding the content spans the
  // full width and this pixel would be the source video — so this pins that
  // request.padding actually reaches the composite, not just the geometry
  // helper.
  const std::uint32_t pad_margin = pixels[(h / 2) * w + 2u];
  EXPECT_GT(chan(pad_margin, 16) - chan(pad_margin, 0), 30)
      << "expected red background in the left padding margin "
         "(padding not applied in the pipeline?)";
  // Placement: the center is the source frame (blue-ish 0x3366CC) drawn over
  // the background — B beats R.
  const std::uint32_t center = pixels[(h / 2) * w + (w / 2)];
  EXPECT_GT(chan(center, 0) - chan(center, 16), 30)
      << "expected the source video drawn over the background at center";
  // Corner radius: (8,14) is inside the square content rect's top-left
  // corner but outside the rounded arc (content corner (6,12.5), radius
  // 19.5, arc center (25.5,32) — distance ~25px > 19.5), so the rounded clip
  // carves it back to background red. Drop the clip and this pixel becomes
  // source video blue.
  const std::uint32_t corner = pixels[14u * w + 8u];
  EXPECT_GT(chan(corner, 16) - chan(corner, 0), 30)
      << "expected the background to show through the rounded corner "
         "(corner-radius clip not applied?)";

  std::error_code ec;
  fs::remove_all(dir, ec);
}

// Slice 4 audio round-trips. Each renders the SAME synthesized source twice
// (baseline vs modified) and compares OUTPUT RMS — the shared AAC encode loss
// cancels, so a ratio assertion is robust where an absolute one would be
// flaky. Source is a ~-12 dBFS sine (amplitude 8000) with headroom so a +6 dB
// boost doesn't rail to full-scale.
TEST(ExportPipelineTest, PositiveGainIncreasesOutputRmsAndKeepsVideo) {
  clingfy::graphics::D3DDevice device;
  if (device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }
  const auto dir = UniqueDir("audio_gain");
  const auto source = (dir / "source.mov").u8string();
  std::string skip_reason;
  if (!SynthesizeSource(&device, source, /*with_audio=*/true, &skip_reason,
                        /*audio_amplitude=*/8000)) {
    GTEST_SKIP() << skip_reason;
  }

  const auto render = [&](const std::string& out, double gain, double vol) {
    RenderRequest r;
    r.source_video_path = fs::u8path(source).wstring();
    r.destination_path = out;
    r.layout = "youtube169";  // non-identity -> composition runs (64x48->86x48)
    r.resolution = "auto";
    r.fit = "fit";
    r.fps_hint = kFps;
    r.audio_gain_db = gain;
    r.audio_volume_percent = vol;
    return RenderComposedExport(r);
  };

  const auto base_out = (dir / "base.mov").u8string();
  const auto gain_out = (dir / "gain.mov").u8string();
  const RenderResult base = render(base_out, 0.0, 100.0);
  const RenderResult gained = render(gain_out, 6.0, 100.0);
  ASSERT_TRUE(base.ok) << base.message;
  ASSERT_TRUE(gained.ok) << gained.message;
  // Source audio survives the re-encode, and video dimensions are unaffected
  // by audio processing.
  EXPECT_TRUE(gained.had_audio);
  EXPECT_GT(gained.audio_packets_written, 0u);
  EXPECT_EQ(gained.output_width, 86u);
  EXPECT_EQ(gained.output_height, 48u);

  const AudioStats b = ReadAudioPeakRms(fs::u8path(base_out).wstring());
  const AudioStats g = ReadAudioPeakRms(fs::u8path(gain_out).wstring());
  if (!b.ok || !g.ok) {
    GTEST_SKIP() << "could not decode exported audio for readback";
  }
  EXPECT_GT(b.rms, 50.0) << "baseline audio unexpectedly silent";
  EXPECT_GT(b.peak, 0.0);
  // +6 dB ~= x1.995; require a clear increase (a dropped-gain regression would
  // leave the ratio ~1.0).
  EXPECT_GT(g.rms, b.rms * 1.3)
      << "expected +6 dB to raise output RMS (base=" << b.rms
      << " gained=" << g.rms << ")";

  std::error_code ec;
  fs::remove_all(dir, ec);
}

TEST(ExportPipelineTest, VolumeAttenuationDecreasesOutputRms) {
  clingfy::graphics::D3DDevice device;
  if (device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }
  const auto dir = UniqueDir("audio_vol");
  const auto source = (dir / "source.mov").u8string();
  std::string skip_reason;
  if (!SynthesizeSource(&device, source, /*with_audio=*/true, &skip_reason,
                        /*audio_amplitude=*/8000)) {
    GTEST_SKIP() << skip_reason;
  }

  const auto render = [&](const std::string& out, double vol) {
    RenderRequest r;
    r.source_video_path = fs::u8path(source).wstring();
    r.destination_path = out;
    r.layout = "youtube169";
    r.resolution = "auto";
    r.fit = "fit";
    r.fps_hint = kFps;
    r.audio_volume_percent = vol;
    return RenderComposedExport(r);
  };

  const auto base_out = (dir / "base.mov").u8string();
  const auto quiet_out = (dir / "quiet.mov").u8string();
  const RenderResult base = render(base_out, 100.0);
  const RenderResult quiet = render(quiet_out, 50.0);  // attenuation is volume
  ASSERT_TRUE(base.ok) << base.message;
  ASSERT_TRUE(quiet.ok) << quiet.message;

  const AudioStats b = ReadAudioPeakRms(fs::u8path(base_out).wstring());
  const AudioStats q = ReadAudioPeakRms(fs::u8path(quiet_out).wstring());
  if (!b.ok || !q.ok) {
    GTEST_SKIP() << "could not decode exported audio for readback";
  }
  EXPECT_GT(b.rms, 50.0) << "baseline audio unexpectedly silent";
  // 50% volume ~= x0.5; require a clear decrease.
  EXPECT_LT(q.rms, b.rms * 0.75)
      << "expected 50% volume to lower output RMS (base=" << b.rms
      << " quiet=" << q.rms << ")";

  std::error_code ec;
  fs::remove_all(dir, ec);
}

TEST(ExportPipelineTest, NormalizeRaisesQuietSourceRms) {
  clingfy::graphics::D3DDevice device;
  if (device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }
  const auto dir = UniqueDir("audio_norm");
  const auto source = (dir / "source.mov").u8string();
  std::string skip_reason;
  // Quiet source (~-20 dBFS peak) so normalize toward -16 dBFS amplifies it.
  if (!SynthesizeSource(&device, source, /*with_audio=*/true, &skip_reason,
                        /*audio_amplitude=*/3000)) {
    GTEST_SKIP() << skip_reason;
  }

  const auto render = [&](const std::string& out, bool normalize) {
    RenderRequest r;
    r.source_video_path = fs::u8path(source).wstring();
    r.destination_path = out;
    r.layout = "youtube169";
    r.resolution = "auto";
    r.fit = "fit";
    r.fps_hint = kFps;
    r.auto_normalize = normalize;
    r.target_loudness_dbfs = -16.0;
    return RenderComposedExport(r);
  };

  const auto base_out = (dir / "base.mov").u8string();
  const auto norm_out = (dir / "norm.mov").u8string();
  const RenderResult base = render(base_out, false);
  const RenderResult norm = render(norm_out, true);
  ASSERT_TRUE(base.ok) << base.message;
  ASSERT_TRUE(norm.ok) << norm.message;

  const AudioStats b = ReadAudioPeakRms(fs::u8path(base_out).wstring());
  const AudioStats n = ReadAudioPeakRms(fs::u8path(norm_out).wstring());
  if (!b.ok || !n.ok) {
    GTEST_SKIP() << "could not decode exported audio for readback";
  }
  EXPECT_GT(b.rms, 20.0) << "baseline audio unexpectedly silent";
  // peak ~0.0915 -> target 0.1585 means a ~x1.73 normalize boost.
  EXPECT_GT(n.rms, b.rms * 1.3)
      << "expected normalize to raise a quiet source's RMS (base=" << b.rms
      << " norm=" << n.rms << ")";

  std::error_code ec;
  fs::remove_all(dir, ec);
}

// Slice 5A: an .mp4 destination yields a readable MP4 (the Sink Writer picks
// the container from the extension), and a requested bitrate is plumbed in.
TEST(ExportPipelineTest, Mp4DestinationProducesReadableFile) {
  clingfy::graphics::D3DDevice device;
  if (device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }
  const auto dir = UniqueDir("mp4");
  const auto source = (dir / "source.mov").u8string();
  const auto dest = (dir / "out.mp4").u8string();

  std::string skip_reason;
  if (!SynthesizeSource(&device, source, /*with_audio=*/false, &skip_reason)) {
    GTEST_SKIP() << skip_reason;
  }

  RenderRequest request;
  request.source_video_path = fs::u8path(source).wstring();
  request.destination_path = dest;  // .mp4 -> MPEG-4 container
  request.layout = "square11";      // 64x48 -> 64x64
  request.resolution = "auto";
  request.fit = "fit";
  request.fps_hint = kFps;
  request.bitrate = "medium";

  const RenderResult result = RenderComposedExport(request);
  ASSERT_TRUE(result.ok) << result.message;
  EXPECT_EQ(result.output_width, 64u);
  EXPECT_EQ(result.output_height, 64u);
  ASSERT_TRUE(fs::exists(fs::u8path(dest)));

  const ProbeResult probe = ProbeOutput(fs::u8path(dest).wstring());
  ASSERT_TRUE(probe.ok) << "exported .mp4 is not a readable video";
  EXPECT_EQ(probe.width, 64u);
  EXPECT_EQ(probe.height, 64u);

  std::error_code ec;
  fs::remove_all(dir, ec);
}

// Slice 5A: progress is emitted as a non-decreasing 0..1 fraction and lands at
// 1.0 on completion. (Per-frame ticks depend on the container reporting a
// duration; the terminal 1.0 always fires, so the assertions hold either way.)
TEST(ExportPipelineTest, ProgressIsMonotonicAndReachesOne) {
  clingfy::graphics::D3DDevice device;
  if (device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }
  const auto dir = UniqueDir("progress");
  const auto source = (dir / "source.mov").u8string();
  const auto dest = (dir / "out.mov").u8string();

  std::string skip_reason;
  if (!SynthesizeSource(&device, source, /*with_audio=*/false, &skip_reason)) {
    GTEST_SKIP() << skip_reason;
  }

  std::vector<double> fractions;
  RenderRequest request;
  request.source_video_path = fs::u8path(source).wstring();
  request.destination_path = dest;
  request.layout = "youtube169";
  request.resolution = "auto";
  request.fit = "fit";
  request.fps_hint = kFps;
  request.on_progress = [&fractions](double f) { fractions.push_back(f); };

  const RenderResult result = RenderComposedExport(request);
  ASSERT_TRUE(result.ok) << result.message;

  ASSERT_FALSE(fractions.empty()) << "no progress emitted";
  for (double f : fractions) {
    EXPECT_GE(f, 0.0);
    EXPECT_LE(f, 1.0);
  }
  for (std::size_t i = 1; i < fractions.size(); ++i) {
    EXPECT_GE(fractions[i], fractions[i - 1]) << "progress went backwards";
  }
  EXPECT_GE(fractions.back(), 0.999) << "progress did not reach 1.0";

  std::error_code ec;
  fs::remove_all(dir, ec);
}

// Slice 5B: a .gif destination produces a real animated GIF via the WIC
// encoder, decimated from the source frame rate. (No audio; the bitrate preset
// is ignored.)
TEST(ExportPipelineTest, GifDestinationProducesReadableAnimatedGif) {
  clingfy::graphics::D3DDevice device;
  if (device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }
  const auto dir = UniqueDir("gif");
  const auto source = (dir / "source.mov").u8string();
  const auto dest = (dir / "out.gif").u8string();

  std::string skip_reason;
  if (!SynthesizeSource(&device, source, /*with_audio=*/true, &skip_reason,
                        /*audio_amplitude=*/4000)) {
    GTEST_SKIP() << skip_reason;
  }

  RenderRequest request;
  request.source_video_path = fs::u8path(source).wstring();
  request.destination_path = dest;  // .gif -> WIC GIF encoder
  request.layout = "square11";      // 64x48 -> 64x64
  request.resolution = "auto";
  request.fit = "fit";
  request.fps_hint = kFps;

  const RenderResult result = RenderComposedExport(request);
  ASSERT_TRUE(result.ok) << result.message;
  EXPECT_EQ(result.output_width, 64u);
  EXPECT_EQ(result.output_height, 64u);
  // GIF drops audio even when the source has it.
  EXPECT_FALSE(result.had_audio);
  EXPECT_EQ(result.audio_packets_written, 0u);
  ASSERT_TRUE(fs::exists(fs::u8path(dest)));
  EXPECT_TRUE(FileStartsWithGifMagic(dest)) << "output is not a GIF";

  const GifProbeResult probe = ProbeGif(fs::u8path(dest).wstring());
  ASSERT_TRUE(probe.ok) << "exported .gif is not a readable GIF";
  EXPECT_EQ(probe.width, 64u);
  EXPECT_EQ(probe.height, 64u);
  // 8 source frames at 30 fps decimate toward 15 fps -> ~4 frames. Assert a
  // tight band centered on 4 (tolerating +/-1 for decoder timestamp rounding)
  // so the test catches both under- and over-decimation, not merely "fewer".
  EXPECT_GE(probe.frame_count, 3u);
  EXPECT_LE(probe.frame_count, 5u);

  std::error_code ec;
  fs::remove_all(dir, ec);
}

// Slice 5B: GIF reuses the shared progress emission, so it is monotonic and
// lands at 1.0 just like the video path.
TEST(ExportPipelineTest, GifProgressIsMonotonicAndReachesOne) {
  clingfy::graphics::D3DDevice device;
  if (device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }
  const auto dir = UniqueDir("gif_progress");
  const auto source = (dir / "source.mov").u8string();
  const auto dest = (dir / "out.gif").u8string();

  std::string skip_reason;
  if (!SynthesizeSource(&device, source, /*with_audio=*/false, &skip_reason)) {
    GTEST_SKIP() << skip_reason;
  }

  std::vector<double> fractions;
  RenderRequest request;
  request.source_video_path = fs::u8path(source).wstring();
  request.destination_path = dest;
  request.layout = "youtube169";
  request.resolution = "auto";
  request.fit = "fit";
  request.fps_hint = kFps;
  request.on_progress = [&fractions](double f) { fractions.push_back(f); };

  const RenderResult result = RenderComposedExport(request);
  ASSERT_TRUE(result.ok) << result.message;

  ASSERT_FALSE(fractions.empty()) << "no progress emitted";
  for (double f : fractions) {
    EXPECT_GE(f, 0.0);
    EXPECT_LE(f, 1.0);
  }
  for (std::size_t i = 1; i < fractions.size(); ++i) {
    EXPECT_GE(fractions[i], fractions[i - 1]) << "progress went backwards";
  }
  EXPECT_GE(fractions.back(), 0.999) << "progress did not reach 1.0";

  std::error_code ec;
  fs::remove_all(dir, ec);
}

// Slice 5B: a mid-export cancel aborts the GIF cleanly and removes the partial
// .gif (the WIC stream is created on Open, so the file exists before cancel).
TEST(ExportPipelineTest, GifCancelStopsAndRemovesPartialFile) {
  clingfy::graphics::D3DDevice device;
  if (device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }
  const auto dir = UniqueDir("gif_cancel");
  const auto source = (dir / "source.mov").u8string();
  const auto dest = (dir / "out.gif").u8string();

  std::string skip_reason;
  if (!SynthesizeSource(&device, source, /*with_audio=*/false, &skip_reason)) {
    GTEST_SKIP() << skip_reason;
  }

  // is_cancelled is polled once before setup and then once per loop iteration;
  // returning true on the third poll cancels a couple of frames in.
  int polls = 0;
  RenderRequest request;
  request.source_video_path = fs::u8path(source).wstring();
  request.destination_path = dest;
  request.layout = "youtube169";
  request.resolution = "auto";
  request.fit = "fit";
  request.fps_hint = kFps;
  request.is_cancelled = [&polls]() { return ++polls >= 3; };

  const RenderResult result = RenderComposedExport(request);
  EXPECT_FALSE(result.ok);
  EXPECT_TRUE(result.cancelled);
  EXPECT_FALSE(fs::exists(fs::u8path(dest)))
      << "a cancelled GIF export left a partial file behind";

  std::error_code ec;
  fs::remove_all(dir, ec);
}

// === Phase 8.2 cursor rendering ============================================

// Write a cursor.jsonl with a constant visible cursor at (x,y) across a short
// timeline, so any decoded frame shows the cursor.
void WriteConstantCursorSidecar(const fs::path& path, int x, int y, int w,
                                int h) {
  std::ofstream o(path, std::ios::binary);
  o << "{\"type\":\"header\",\"schemaVersion\":1,\"sampleRateHz\":60,"
       "\"targetType\":\"display\",\"width\":"
    << w << ",\"height\":" << h << ",\"originX\":0,\"originY\":0}\n";
  for (int t = 0; t <= 400; t += 16) {
    o << "{\"type\":\"sample\",\"tMs\":" << t << ",\"screenX\":" << x
      << ",\"screenY\":" << y << ",\"x\":" << x << ",\"y\":" << y
      << ",\"visible\":true}\n";
  }
}

// The cursor glyph is white; the synthesized source is solid blue (0x3366CC) and
// the letterbox/background is black — so a near-white pixel exists only if the
// cursor was drawn. Pixels read back as 0xAARRGGBB.
bool HasNearWhitePixel(const std::vector<std::uint32_t>& pixels) {
  for (std::uint32_t p : pixels) {
    const int r = static_cast<int>((p >> 16) & 0xFFu);
    const int g = static_cast<int>((p >> 8) & 0xFFu);
    const int b = static_cast<int>(p & 0xFFu);
    if (r > 170 && g > 170 && b > 170) {
      return true;
    }
  }
  return false;
}

int CountNearWhite(const std::vector<std::uint32_t>& pixels) {
  int n = 0;
  for (std::uint32_t p : pixels) {
    const int r = static_cast<int>((p >> 16) & 0xFFu);
    const int g = static_cast<int>((p >> 8) & 0xFFu);
    const int b = static_cast<int>(p & 0xFFu);
    if (r > 170 && g > 170 && b > 170) {
      ++n;
    }
  }
  return n;
}

// Sidecar with a constant visible cursor and an optional click at t=0 (so the
// ripple is active on the first decoded frame).
void WriteCursorSidecarMaybeClick(const fs::path& path, int x, int y, int w,
                                  int h, bool with_click) {
  std::ofstream o(path, std::ios::binary);
  o << "{\"type\":\"header\",\"schemaVersion\":1,\"sampleRateHz\":60,"
       "\"targetType\":\"display\",\"width\":"
    << w << ",\"height\":" << h << ",\"originX\":0,\"originY\":0}\n";
  for (int t = 0; t <= 400; t += 16) {
    o << "{\"type\":\"sample\",\"tMs\":" << t << ",\"screenX\":" << x
      << ",\"screenY\":" << y << ",\"x\":" << x << ",\"y\":" << y
      << ",\"visible\":true}\n";
  }
  if (with_click) {
    o << "{\"type\":\"click\",\"tMs\":0,\"screenX\":" << x << ",\"screenY\":" << y
      << ",\"button\":\"left\",\"action\":\"down\"}\n";
  }
}

// Render one frame-0 readback for a sidecar (cursor on), returning the near-white
// pixel count, or -1 when the environment couldn't render/decode.
int RenderAndCountWhite(clingfy::graphics::D3DDevice* device,
                        const fs::path& dir, bool with_click) {
  const auto source = (dir / "source.mov").u8string();
  const auto dest = (dir / "out.mov").u8string();
  std::string skip_reason;
  if (!SynthesizeSource(device, source, /*with_audio=*/false, &skip_reason)) {
    return -1;
  }
  WriteCursorSidecarMaybeClick(dir / "cursor.jsonl", 32, 24, kSourceWidth,
                               kSourceHeight, with_click);
  RenderRequest request;
  request.source_video_path = fs::u8path(source).wstring();
  request.destination_path = dest;
  request.layout = "square11";
  request.resolution = "auto";
  request.fit = "fit";
  request.fps_hint = kFps;
  request.show_cursor = true;
  request.cursor_size = 2.0;
  request.cursor_sidecar_path = (dir / "cursor.jsonl").wstring();
  const RenderResult result = RenderComposedExport(request);
  if (!result.ok) {
    return -1;
  }
  UINT w = 0;
  UINT h = 0;
  std::vector<std::uint32_t> pixels;
  if (!ReadFirstFrameBgra(fs::u8path(dest).wstring(), &w, &h, &pixels)) {
    return -1;
  }
  return CountNearWhite(pixels);
}

TEST(ExportPipelineTest, CursorRenderedWhenShowCursorOn) {
  clingfy::graphics::D3DDevice device;
  if (device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }
  const auto dir = UniqueDir("cursor_on");
  const auto source = (dir / "source.mov").u8string();
  const auto dest = (dir / "out.mov").u8string();
  std::string skip_reason;
  if (!SynthesizeSource(&device, source, /*with_audio=*/false, &skip_reason)) {
    GTEST_SKIP() << skip_reason;
  }
  WriteConstantCursorSidecar(dir / "cursor.jsonl", 20, 20, kSourceWidth,
                             kSourceHeight);

  RenderRequest request;
  request.source_video_path = fs::u8path(source).wstring();
  request.destination_path = dest;
  request.layout = "square11";  // non-identity → composition runs
  request.resolution = "auto";
  request.fit = "fit";
  request.fps_hint = kFps;
  request.show_cursor = true;
  request.cursor_size = 3.0;  // big arrow so its white center survives H.264
  request.cursor_sidecar_path = (dir / "cursor.jsonl").wstring();

  const RenderResult result = RenderComposedExport(request);
  ASSERT_TRUE(result.ok) << result.message;

  UINT w = 0;
  UINT h = 0;
  std::vector<std::uint32_t> pixels;
  if (!ReadFirstFrameBgra(fs::u8path(dest).wstring(), &w, &h, &pixels)) {
    GTEST_SKIP() << "could not decode the exported frame for pixel readback";
  }
  EXPECT_TRUE(HasNearWhitePixel(pixels))
      << "expected the white cursor glyph in the exported frame";

  std::error_code ec;
  fs::remove_all(dir, ec);
}

TEST(ExportPipelineTest, NoCursorWhenShowCursorOff) {
  clingfy::graphics::D3DDevice device;
  if (device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }
  const auto dir = UniqueDir("cursor_off");
  const auto source = (dir / "source.mov").u8string();
  const auto dest = (dir / "out.mov").u8string();
  std::string skip_reason;
  if (!SynthesizeSource(&device, source, /*with_audio=*/false, &skip_reason)) {
    GTEST_SKIP() << skip_reason;
  }
  WriteConstantCursorSidecar(dir / "cursor.jsonl", 20, 20, kSourceWidth,
                             kSourceHeight);

  RenderRequest request;
  request.source_video_path = fs::u8path(source).wstring();
  request.destination_path = dest;
  request.layout = "square11";
  request.resolution = "auto";
  request.fit = "fit";
  request.fps_hint = kFps;
  request.show_cursor = false;  // OFF — even with a sidecar present.
  request.cursor_size = 3.0;
  request.cursor_sidecar_path = (dir / "cursor.jsonl").wstring();

  const RenderResult result = RenderComposedExport(request);
  ASSERT_TRUE(result.ok) << result.message;

  UINT w = 0;
  UINT h = 0;
  std::vector<std::uint32_t> pixels;
  if (!ReadFirstFrameBgra(fs::u8path(dest).wstring(), &w, &h, &pixels)) {
    GTEST_SKIP() << "could not decode the exported frame for pixel readback";
  }
  EXPECT_FALSE(HasNearWhitePixel(pixels))
      << "no cursor should be drawn when showCursor is false";

  std::error_code ec;
  fs::remove_all(dir, ec);
}

TEST(ExportPipelineTest, MissingCursorSidecarStillExports) {
  clingfy::graphics::D3DDevice device;
  if (device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }
  const auto dir = UniqueDir("cursor_missing");
  const auto source = (dir / "source.mov").u8string();
  const auto dest = (dir / "out.mov").u8string();
  std::string skip_reason;
  if (!SynthesizeSource(&device, source, /*with_audio=*/false, &skip_reason)) {
    GTEST_SKIP() << skip_reason;
  }

  RenderRequest request;
  request.source_video_path = fs::u8path(source).wstring();
  request.destination_path = dest;
  request.layout = "square11";
  request.resolution = "auto";
  request.fit = "fit";
  request.fps_hint = kFps;
  request.show_cursor = true;
  request.cursor_size = 1.5;
  // Points at a file that does not exist → renders no cursor, never fails.
  request.cursor_sidecar_path = (dir / "does-not-exist.jsonl").wstring();

  const RenderResult result = RenderComposedExport(request);
  EXPECT_TRUE(result.ok) << "a missing sidecar must not fail the export — "
                         << result.message;
  EXPECT_TRUE(fs::exists(fs::u8path(dest)));

  std::error_code ec;
  fs::remove_all(dir, ec);
}

TEST(ExportPipelineTest, GifWithCursorExports) {
  clingfy::graphics::D3DDevice device;
  if (device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }
  const auto dir = UniqueDir("cursor_gif");
  const auto source = (dir / "source.mov").u8string();
  const auto dest = (dir / "out.gif").u8string();
  std::string skip_reason;
  if (!SynthesizeSource(&device, source, /*with_audio=*/false, &skip_reason)) {
    GTEST_SKIP() << skip_reason;
  }
  WriteConstantCursorSidecar(dir / "cursor.jsonl", 20, 20, kSourceWidth,
                             kSourceHeight);

  RenderRequest request;
  request.source_video_path = fs::u8path(source).wstring();
  request.destination_path = dest;  // .gif → WIC encoder, cursor still composited
  request.layout = "square11";
  request.resolution = "auto";
  request.fit = "fit";
  request.fps_hint = kFps;
  request.show_cursor = true;
  request.cursor_size = 2.0;
  request.cursor_sidecar_path = (dir / "cursor.jsonl").wstring();

  const RenderResult result = RenderComposedExport(request);
  ASSERT_TRUE(result.ok) << result.message;
  ASSERT_TRUE(fs::exists(fs::u8path(dest)));
  EXPECT_TRUE(FileStartsWithGifMagic(dest)) << "output is not a GIF";
  const GifProbeResult probe = ProbeGif(fs::u8path(dest).wstring());
  EXPECT_TRUE(probe.ok) << "GIF-with-cursor is not a readable GIF";

  std::error_code ec;
  fs::remove_all(dir, ec);
}

// === Phase 8.3 smart zoom ==================================================

// Sidecar with a visible cursor + one click (so the zoom timeline builder
// generates a segment around the click).
void WriteCursorSidecarWithClick(const fs::path& path, int x, int y,
                                 int click_ms, int w, int h) {
  std::ofstream o(path, std::ios::binary);
  o << "{\"type\":\"header\",\"schemaVersion\":1,\"sampleRateHz\":60,"
       "\"targetType\":\"display\",\"width\":"
    << w << ",\"height\":" << h << ",\"originX\":0,\"originY\":0}\n";
  for (int t = 0; t <= 400; t += 16) {
    o << "{\"type\":\"sample\",\"tMs\":" << t << ",\"screenX\":" << x
      << ",\"screenY\":" << y << ",\"x\":" << x << ",\"y\":" << y
      << ",\"visible\":true}\n";
  }
  o << "{\"type\":\"click\",\"tMs\":" << click_ms << ",\"screenX\":" << x
    << ",\"screenY\":" << y << ",\"button\":\"left\",\"action\":\"down\"}\n";
}

TEST(ExportPipelineTest, ZoomRoundTripExports) {
  clingfy::graphics::D3DDevice device;
  if (device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }
  const auto dir = UniqueDir("zoom_mov");
  const auto source = (dir / "source.mov").u8string();
  const auto dest = (dir / "out.mov").u8string();
  std::string skip_reason;
  if (!SynthesizeSource(&device, source, /*with_audio=*/false, &skip_reason)) {
    GTEST_SKIP() << skip_reason;
  }
  WriteCursorSidecarWithClick(dir / "cursor.jsonl", 20, 20, 50, kSourceWidth,
                              kSourceHeight);

  RenderRequest request;
  request.source_video_path = fs::u8path(source).wstring();
  request.destination_path = dest;
  request.layout = "square11";
  request.resolution = "auto";
  request.fit = "fit";
  request.fps_hint = kFps;
  request.zoom_enabled = true;
  request.zoom_factor = 2.0;
  request.cursor_sidecar_path = (dir / "cursor.jsonl").wstring();

  const RenderResult result = RenderComposedExport(request);
  ASSERT_TRUE(result.ok) << result.message;
  EXPECT_GT(result.video_frames_written, 0u);
  const ProbeResult probe = ProbeOutput(fs::u8path(dest).wstring());
  ASSERT_TRUE(probe.ok) << "zoomed export is not a readable video";
  EXPECT_EQ(probe.width, 64u);
  EXPECT_EQ(probe.height, 64u);

  std::error_code ec;
  fs::remove_all(dir, ec);
}

TEST(ExportPipelineTest, ZoomGifExports) {
  clingfy::graphics::D3DDevice device;
  if (device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }
  const auto dir = UniqueDir("zoom_gif");
  const auto source = (dir / "source.mov").u8string();
  const auto dest = (dir / "out.gif").u8string();
  std::string skip_reason;
  if (!SynthesizeSource(&device, source, /*with_audio=*/false, &skip_reason)) {
    GTEST_SKIP() << skip_reason;
  }
  WriteCursorSidecarWithClick(dir / "cursor.jsonl", 20, 20, 50, kSourceWidth,
                              kSourceHeight);

  RenderRequest request;
  request.source_video_path = fs::u8path(source).wstring();
  request.destination_path = dest;
  request.layout = "square11";
  request.resolution = "auto";
  request.fit = "fit";
  request.fps_hint = kFps;
  request.zoom_enabled = true;
  request.zoom_factor = 2.0;
  request.cursor_sidecar_path = (dir / "cursor.jsonl").wstring();

  const RenderResult result = RenderComposedExport(request);
  ASSERT_TRUE(result.ok) << result.message;
  ASSERT_TRUE(fs::exists(fs::u8path(dest)));
  EXPECT_TRUE(FileStartsWithGifMagic(dest)) << "zoomed GIF output is not a GIF";

  std::error_code ec;
  fs::remove_all(dir, ec);
}

TEST(ExportPipelineTest, ZoomWithMissingSidecarSoftFails) {
  clingfy::graphics::D3DDevice device;
  if (device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }
  const auto dir = UniqueDir("zoom_nosidecar");
  const auto source = (dir / "source.mov").u8string();
  const auto dest = (dir / "out.mov").u8string();
  std::string skip_reason;
  if (!SynthesizeSource(&device, source, /*with_audio=*/false, &skip_reason)) {
    GTEST_SKIP() << skip_reason;
  }

  RenderRequest request;
  request.source_video_path = fs::u8path(source).wstring();
  request.destination_path = dest;
  request.layout = "square11";
  request.resolution = "auto";
  request.fit = "fit";
  request.fps_hint = kFps;
  request.zoom_enabled = true;  // requested, but no sidecar → no zoom, no failure
  request.zoom_factor = 2.0;
  request.cursor_sidecar_path = (dir / "missing.jsonl").wstring();

  const RenderResult result = RenderComposedExport(request);
  EXPECT_TRUE(result.ok) << "missing sidecar must soft-fail to no-zoom — "
                         << result.message;
  EXPECT_TRUE(fs::exists(fs::u8path(dest)));

  std::error_code ec;
  fs::remove_all(dir, ec);
}

TEST(ExportPipelineTest, ZoomProgressReachesOne) {
  clingfy::graphics::D3DDevice device;
  if (device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }
  const auto dir = UniqueDir("zoom_progress");
  const auto source = (dir / "source.mov").u8string();
  const auto dest = (dir / "out.mov").u8string();
  std::string skip_reason;
  if (!SynthesizeSource(&device, source, /*with_audio=*/false, &skip_reason)) {
    GTEST_SKIP() << skip_reason;
  }
  WriteCursorSidecarWithClick(dir / "cursor.jsonl", 20, 20, 50, kSourceWidth,
                              kSourceHeight);

  std::vector<double> fractions;
  RenderRequest request;
  request.source_video_path = fs::u8path(source).wstring();
  request.destination_path = dest;
  request.layout = "youtube169";
  request.resolution = "auto";
  request.fit = "fit";
  request.fps_hint = kFps;
  request.zoom_enabled = true;
  request.zoom_factor = 2.0;
  request.cursor_sidecar_path = (dir / "cursor.jsonl").wstring();
  request.on_progress = [&fractions](double f) { fractions.push_back(f); };

  const RenderResult result = RenderComposedExport(request);
  ASSERT_TRUE(result.ok) << result.message;
  ASSERT_FALSE(fractions.empty()) << "no progress emitted with zoom on";
  EXPECT_GE(fractions.back(), 0.999) << "zoom export progress did not reach 1.0";

  std::error_code ec;
  fs::remove_all(dir, ec);
}

// === Phase 8.4 click animation =============================================

TEST(ExportPipelineTest, ClickAnimationAddsVisiblePixels) {
  clingfy::graphics::D3DDevice device;
  if (device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }
  const auto dir_click = UniqueDir("click_on");
  const auto dir_none = UniqueDir("click_off");

  const int with_click = RenderAndCountWhite(&device, dir_click, true);
  const int no_click = RenderAndCountWhite(&device, dir_none, false);
  if (with_click < 0 || no_click < 0) {
    GTEST_SKIP() << "environment could not render/decode for the pixel readback";
  }
  // Same source + same cursor in both; the only difference is the click ripple,
  // which adds a white ring → strictly more near-white pixels. (Frame 0 is the
  // thinnest-ring worst case, but at 0.8 opacity over the blue source the ring
  // pixels still read ~215 > the 170 threshold with margin.)
  EXPECT_GT(with_click, no_click)
      << "click ripple should add visible pixels (with=" << with_click
      << " without=" << no_click << ")";

  std::error_code ec;
  fs::remove_all(dir_click, ec);
  fs::remove_all(dir_none, ec);
}

TEST(ExportPipelineTest, NoClicksNoAnimationStillExports) {
  clingfy::graphics::D3DDevice device;
  if (device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }
  const auto dir = UniqueDir("click_none");
  // A sidecar with samples but NO click lines → DrawClicks is a no-op; export
  // still succeeds (soft-fail to no animation).
  const int count = RenderAndCountWhite(&device, dir, /*with_click=*/false);
  EXPECT_GE(count, 0) << "export with a clickless sidecar must still succeed";

  std::error_code ec;
  fs::remove_all(dir, ec);
}

TEST(ExportPipelineTest, ClickAnimationGifExports) {
  clingfy::graphics::D3DDevice device;
  if (device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }
  const auto dir = UniqueDir("click_gif");
  const auto source = (dir / "source.mov").u8string();
  const auto dest = (dir / "out.gif").u8string();
  std::string skip_reason;
  if (!SynthesizeSource(&device, source, /*with_audio=*/false, &skip_reason)) {
    GTEST_SKIP() << skip_reason;
  }
  WriteCursorSidecarMaybeClick(dir / "cursor.jsonl", 32, 24, kSourceWidth,
                               kSourceHeight, /*with_click=*/true);

  RenderRequest request;
  request.source_video_path = fs::u8path(source).wstring();
  request.destination_path = dest;
  request.layout = "square11";
  request.resolution = "auto";
  request.fit = "fit";
  request.fps_hint = kFps;
  request.show_cursor = true;
  request.cursor_size = 2.0;
  request.cursor_sidecar_path = (dir / "cursor.jsonl").wstring();

  const RenderResult result = RenderComposedExport(request);
  ASSERT_TRUE(result.ok) << result.message;
  ASSERT_TRUE(fs::exists(fs::u8path(dest)));
  EXPECT_TRUE(FileStartsWithGifMagic(dest)) << "click-animated GIF is not a GIF";

  std::error_code ec;
  fs::remove_all(dir, ec);
}

TEST(ExportPipelineTest, MissingSourceFailsCleanly) {
  // No GPU needed for the failure path, but Create() gates the device the
  // pipeline builds internally; skip if unavailable so the assert below
  // reflects the missing-source path, not a device error.
  clingfy::graphics::D3DDevice probe_device;
  if (probe_device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }

  RenderRequest request;
  request.source_video_path = L"C:\\definitely\\not\\real\\screen.mov";
  request.destination_path =
      (fs::temp_directory_path() / "clingfy_export_missing_out.mov").u8string();
  request.layout = "square11";
  request.resolution = "p1080";
  request.fit = "fit";

  const RenderResult result = RenderComposedExport(request);
  EXPECT_FALSE(result.ok);
  EXPECT_FALSE(result.message.empty());
  // Phase 10.4: every failure outcome leaves NO file at the destination.
  EXPECT_FALSE(
      fs::exists(fs::u8path(request.destination_path)));
}

// === Phase 10.4: failure cleanup + disk-full classification =================

// Pure classifier — GPU-free. Only the two Win32 disk-full codes (mapped
// through HRESULT_FROM_WIN32) flag a mid-write disk-full; everything else
// stays a generic render failure.
TEST(ExportPipelineTest, IsDiskFullHresultClassifiesOnlyDiskFullCodes) {
  EXPECT_TRUE(IsDiskFullHresult(HRESULT_FROM_WIN32(ERROR_DISK_FULL)));
  EXPECT_TRUE(IsDiskFullHresult(HRESULT_FROM_WIN32(ERROR_HANDLE_DISK_FULL)));
  EXPECT_FALSE(IsDiskFullHresult(S_OK));
  EXPECT_FALSE(IsDiskFullHresult(E_FAIL));
  EXPECT_FALSE(IsDiskFullHresult(HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED)));
  EXPECT_FALSE(IsDiskFullHresult(HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND)));
}

// Phase 10.4 fixture: a source .mov whose video track has ZERO samples. The
// source reader opens it fine, but the export's frame loop hits EOS
// immediately and fails ("no video frames were decoded") — a failure that
// occurs AFTER the output encoder has been opened, i.e. after the
// destination file exists on disk for the GIF path (the WIC stream is
// created on Open).
bool SynthesizeEmptySource(clingfy::graphics::D3DDevice* device,
                           const std::string& path, std::string* skip_reason) {
  clingfy::encoding::EncoderConfig cfg;
  cfg.output_path = path;
  cfg.width = kSourceWidth;
  cfg.height = kSourceHeight;
  cfg.fps = kFps;
  clingfy::encoding::MfSinkWriterEncoder encoder;
  if (auto err = encoder.Open(cfg, *device)) {
    *skip_reason = "source encoder open failed: " + err->message;
    return false;
  }
  if (auto err = encoder.Finalize()) {
    *skip_reason = "zero-frame source finalize failed: " + err->message;
    return false;
  }
  return true;
}

// A render failure must remove any partial output: previously a failed
// export left a corrupt file (truncated GIF / moov-less MP4) at the
// user-chosen destination. The destination is freshly collision-avoided, so
// deleting it is always safe.
TEST(ExportPipelineTest, RenderFailureRemovesPartialDestination) {
  clingfy::graphics::D3DDevice device;
  if (device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }
  const auto dir = UniqueDir("fail_cleanup");
  const auto source = (dir / "source.mov").u8string();
  const auto dest = (dir / "out.gif").u8string();
  std::string skip_reason;
  if (!SynthesizeEmptySource(&device, source, &skip_reason)) {
    GTEST_SKIP() << skip_reason;
  }

  RenderRequest request;
  request.source_video_path = fs::u8path(source).wstring();
  // .gif destination: the WIC encoder creates the file on Open, BEFORE the
  // frame loop — so this exercises cleanup of an actually-created output.
  request.destination_path = dest;
  request.layout = "auto";
  request.resolution = "auto";
  request.fit = "fit";
  request.fps_hint = kFps;

  const RenderResult result = RenderComposedExport(request);
  ASSERT_FALSE(result.ok) << "a zero-frame source must fail the render";
  EXPECT_FALSE(result.cancelled);
  EXPECT_FALSE(fs::exists(fs::u8path(dest)))
      << "a failed render left a partial file at the destination — "
      << result.message;

  std::error_code ec;
  fs::remove_all(dir, ec);
}

// ---- Editing port (clips, step 3a): monotonic cut bake ----------------------
//
// The pipeline drops source frames/packets in a cut gap and re-stamps the
// survivors onto a compacted timeline. RenderResult::video_frames_written is
// what the loop handed the encoder AFTER the drop gate, so the drop count is
// asserted directly (no decode needed). Sub-frame A/V origin alignment (T2) is
// verified by construction — AAC encoder priming makes it unobservable at
// sub-frame resolution through a decode round-trip — so the head-trim case
// asserts the buffer/flush path runs and preserves both streams.

TEST(ExportPipelineTest, ClipMiddleCutDropsGapFrames) {
  clingfy::graphics::D3DDevice device;
  if (device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }
  const auto dir = UniqueDir("clip_cut");
  const auto source = (dir / "source.mov").u8string();
  std::string skip_reason;
  if (!SynthesizeSource(&device, source, /*with_audio=*/false, &skip_reason)) {
    GTEST_SKIP() << skip_reason;
  }

  auto make_request = [&](const std::string& dest,
                          std::vector<clip_planner::ClipKeptRange> ranges) {
    RenderRequest r;
    r.source_video_path = fs::u8path(source).wstring();
    r.destination_path = dest;
    r.layout = "square11";
    r.resolution = "auto";
    r.fit = "fit";
    r.fps_hint = kFps;
    r.clip_ranges = std::move(ranges);
    return r;
  };

  // Source frames land at source ms 0,33,66,99,133,166,199,233 (8 frames @30).
  // Keep [0,90) (0,33,66) + [150,250) (166,199,233) → drop the two gap frames
  // at 99 ms and 133 ms.
  const auto base_dest = (dir / "base.mov").u8string();
  const auto cut_dest = (dir / "cut.mov").u8string();
  const RenderResult base = RenderComposedExport(make_request(base_dest, {}));
  const RenderResult cut = RenderComposedExport(make_request(
      cut_dest, {clip_planner::ClipKeptRange{0, 90},
                 clip_planner::ClipKeptRange{150, 250}}));
  ASSERT_TRUE(base.ok) << base.message;
  ASSERT_TRUE(cut.ok) << cut.message;
  EXPECT_GT(cut.video_frames_written, 0u);
  EXPECT_LT(cut.video_frames_written, base.video_frames_written)
      << "the cut export must drop the gap frames";
  EXPECT_EQ(base.video_frames_written - cut.video_frames_written, 2u)
      << "exactly the two frames at 99 ms and 133 ms should be dropped";

  const ProbeResult probe = ProbeOutput(fs::u8path(cut_dest).wstring());
  EXPECT_TRUE(probe.ok) << "cut export is not a readable video";

  std::error_code ec;
  fs::remove_all(dir, ec);
}

TEST(ExportPipelineTest, SingleWholeRangeKeepsAllFrames) {
  // A single range covering the whole source exercises the clipping code path
  // (clip_ranges non-empty) but must keep every frame — the re-stamp is an
  // identity mapping, so nothing is dropped.
  clingfy::graphics::D3DDevice device;
  if (device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }
  const auto dir = UniqueDir("clip_whole");
  const auto source = (dir / "source.mov").u8string();
  std::string skip_reason;
  if (!SynthesizeSource(&device, source, /*with_audio=*/false, &skip_reason)) {
    GTEST_SKIP() << skip_reason;
  }

  RenderRequest base;
  base.source_video_path = fs::u8path(source).wstring();
  base.destination_path = (dir / "base.mov").u8string();
  base.layout = "square11";
  base.resolution = "auto";
  base.fit = "fit";
  base.fps_hint = kFps;

  RenderRequest whole = base;
  whole.destination_path = (dir / "whole.mov").u8string();
  whole.clip_ranges = {clip_planner::ClipKeptRange{0, 1'000'000}};

  const RenderResult base_r = RenderComposedExport(base);
  const RenderResult whole_r = RenderComposedExport(whole);
  ASSERT_TRUE(base_r.ok) << base_r.message;
  ASSERT_TRUE(whole_r.ok) << whole_r.message;
  EXPECT_EQ(whole_r.video_frames_written, base_r.video_frames_written)
      << "a whole-covering clip range must not drop any frame";

  std::error_code ec;
  fs::remove_all(dir, ec);
}

// ---- Editing port (clips, step 3b-2a): reorder / non-monotonic bake ---------
//
// The reorder path reads each kept range's source window in TIMELINE order,
// seeking the reader BACKWARD across a boundary, and re-stamps onto a contiguous
// edited timeline. With a red-first / blue-second source, a timeline that plays
// the blue (later) half first must produce blue frames THEN red frames — which
// only happens if the backward seek + per-range re-stamp work. (This source has
// no audio; the reorder AUDIO stitch — the decoupled pump — is exercised by the
// sibling ReorderExportStitchesAudioInEditedOrder test below.)
TEST(ExportPipelineTest, ReorderExportReadsLaterSourceWindowFirst) {
  clingfy::graphics::D3DDevice device;
  if (device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }
  const auto dir = UniqueDir("clip_reorder");
  const auto source = (dir / "source.mov").u8string();
  std::string skip_reason;
  if (!SynthesizeHalvesSource(&device, source, &skip_reason)) {
    GTEST_SKIP() << skip_reason;
  }

  // Source frames 0..3 (ms 0,33,66,100) RED; 4..7 (ms 133,166,200,233) BLUE.
  // Timeline = [ blue window (133,267), red window (0,133) ] — a later source
  // window placed BEFORE an earlier one (non-monotonic). The blue range ends at
  // source EOS, so this also exercises the reorder EOS→next-range advance.
  RenderRequest r;
  r.source_video_path = fs::u8path(source).wstring();
  r.destination_path = (dir / "reorder.mov").u8string();
  r.layout = "square11";
  r.resolution = "auto";
  r.fit = "fit";
  r.fps_hint = kFps;
  r.clip_ranges = {clip_planner::ClipKeptRange{133, 267},
                   clip_planner::ClipKeptRange{0, 133}};
  ASSERT_FALSE(clip_planner::IsSourceMonotonic(r.clip_ranges))
      << "test fixture must be a genuine reorder";

  const RenderResult result = RenderComposedExport(r);
  ASSERT_TRUE(result.ok) << result.message;
  // Reorder rearranges, it does not drop: all 8 frames survive.
  EXPECT_EQ(result.video_frames_written, 8u);

  std::vector<std::uint32_t> colors;
  if (!ReadFrameCenterColors(fs::u8path(r.destination_path).wstring(),
                             &colors)) {
    GTEST_SKIP() << "could not decode the reordered output";
  }
  ASSERT_GE(colors.size(), 6u) << "expected ~8 output frames";

  auto red_of = [](std::uint32_t c) { return static_cast<int>((c >> 16) & 0xFF); };
  auto blue_of = [](std::uint32_t c) { return static_cast<int>(c & 0xFF); };
  // First output frame is the reordered-first (blue, later-in-source) half —
  // this is the backward seek proving itself.
  EXPECT_GT(blue_of(colors.front()), red_of(colors.front()) + 40)
      << "first output frame should be the reordered-first (blue) source half";
  // Last output frame is the earlier (red) half, now placed second.
  EXPECT_GT(red_of(colors.back()), blue_of(colors.back()) + 40)
      << "last output frame should be the earlier (red) source half";

  std::error_code ec;
  fs::remove_all(dir, ec);
}

// Editing port (clips, 3b-2b): the reorder AUDIO stitch. The source's tone is
// LOUD only in its first half (source ms < 300) and SILENT after. The timeline
// plays the LATER (silent) source window first and the EARLIER (loud) one
// second, so if the decoupled audio pump reads each window in timeline order,
// the OUTPUT starts silent and ends loud — the reverse of the source. The
// captured audio also runs shorter than the reordered video, so the tail is
// silence-filled; the decoded track must span the full edited duration.
TEST(ExportPipelineTest, ReorderExportStitchesAudioInEditedOrder) {
  clingfy::graphics::D3DDevice device;
  if (device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }
  const auto dir = UniqueDir("clip_reorder_audio");
  const auto source = (dir / "source.mov").u8string();
  std::string skip_reason;
  if (!SynthesizeReorderAudioSource(&device, source, /*frames=*/30,
                                    /*half_ms=*/300, &skip_reason)) {
    GTEST_SKIP() << skip_reason;
  }

  // Timeline = [ later window (320,620) — SILENT source, then earlier window
  // (0,300) — LOUD source ]. Edited duration = 600 ms.
  RenderRequest r;
  r.source_video_path = fs::u8path(source).wstring();
  r.destination_path = (dir / "reorder_audio.mov").u8string();
  r.layout = "square11";
  r.resolution = "auto";
  r.fit = "fit";
  r.fps_hint = kFps;
  r.clip_ranges = {clip_planner::ClipKeptRange{320, 620},
                   clip_planner::ClipKeptRange{0, 300}};
  ASSERT_FALSE(clip_planner::IsSourceMonotonic(r.clip_ranges))
      << "test fixture must be a genuine reorder";

  const RenderResult result = RenderComposedExport(r);
  ASSERT_TRUE(result.ok) << result.message;
  EXPECT_TRUE(result.had_audio) << "reorder audio must survive the pump";
  EXPECT_GT(result.audio_packets_written, 0u);

  std::vector<std::int16_t> pcm;
  if (!ReadAllAudioPcm(fs::u8path(r.destination_path).wstring(), &pcm)) {
    GTEST_SKIP() << "could not decode the reordered output audio";
  }
  // The captured tone is only ~300 ms of real audio; the decoded track must be
  // ~600 ms (the full edited duration), which only happens if the second slot's
  // shortfall was silence-filled (§5.2). 600 ms * 48 = 28800 frames (± AAC
  // priming); a track near ~300 ms would mean the silence-fill was skipped.
  const std::int64_t frames = static_cast<std::int64_t>(pcm.size() / 2u);
  EXPECT_GT(frames, 24000) << "silence-fill must extend the track to the edited "
                              "duration, not stop at the real audio";
  EXPECT_LT(frames, 33000) << "track ran well past the edited duration";

  // Windowed level, with guard bands around the 300 ms slot boundary and the
  // ends (AAC encoder latency shifts samples by ~20-40 ms).
  const double silent_rms = AudioWindowRms(pcm, /*start_ms=*/40, /*end_ms=*/260);
  const double loud_rms = AudioWindowRms(pcm, /*start_ms=*/340, /*end_ms=*/560);
  EXPECT_GT(loud_rms, 100.0)
      << "the LOUD source half must land in the SECOND edited slot";
  EXPECT_LT(silent_rms, loud_rms * 0.5)
      << "the SILENT source half must land in the FIRST edited slot — proving "
         "the audio was stitched in edited (reordered) order, not source order";

  std::error_code ec;
  fs::remove_all(dir, ec);
}

// Editing port (clips, 3b-3): the camera bubble under REORDER (§5.5). The camera
// is a separate synced player — its VIDEO tracks SOURCE time while the export
// re-stamps onto the edited timeline, so at a reorder boundary the source clock
// jumps BACKWARD and the forward-only camera reader must be re-primed
// (CameraExportRenderer::SeekTo, added in 3b-2a) or the bubble would freeze on a
// stale later frame. Proof: a camera colored by source time (green first source
// half, yellow second) over a reordered screen must show, in each output frame's
// bubble, the color matching that frame's SOURCE window — reversed from source
// order, exactly like the screen. A broken SeekTo leaves the bubble stuck.
TEST(ExportPipelineTest, CameraBubbleTracksSourceTimeUnderReorder) {
  clingfy::graphics::D3DDevice device;
  if (device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }
  const auto dir = UniqueDir("clip_reorder_camera");
  const auto screen = (dir / "screen.mov").u8string();
  const auto camera = (dir / "camera.mov").u8string();
  std::string skip_reason;
  // Screen 320x240 (big enough for the >=96px bubble): red first, blue second.
  if (!SynthesizeColorHalvesSource(&device, screen, 320, 240, 0xFFFF0000u,
                                   0xFF0000FFu, &skip_reason)) {
    GTEST_SKIP() << skip_reason;
  }
  // Camera: green first, yellow second — same duration so the switch lines up in
  // time with the screen's (only the RED channel differs: yellow=255, green=0).
  if (!SynthesizeColorHalvesSource(&device, camera, 160, 120, 0xFF00FF00u,
                                   0xFFFFFF00u, &skip_reason)) {
    GTEST_SKIP() << skip_reason;
  }

  RenderRequest r;
  r.source_video_path = fs::u8path(screen).wstring();
  r.destination_path = (dir / "reorder_camera.mov").u8string();
  r.layout = "square11";  // 320x240 -> 320x320 canvas
  r.resolution = "auto";
  r.fit = "fit";
  r.fps_hint = kFps;
  // Timeline = [ later window (133,267), earlier window (0,133) ] — a reorder.
  r.clip_ranges = {clip_planner::ClipKeptRange{133, 267},
                   clip_planner::ClipKeptRange{0, 133}};
  ASSERT_FALSE(clip_planner::IsSourceMonotonic(r.clip_ranges))
      << "test fixture must be a genuine reorder";
  r.draw_camera = true;
  r.camera_video_path = fs::u8path(camera).wstring();
  r.camera_start_offset_ms = 0;  // camera time == screen source time
  r.camera_has_center = true;
  r.camera_center_x = 0.80;
  r.camera_center_y = 0.80;
  r.camera_size_factor = 0.45;   // a big bubble so its center is easy to sample
  r.camera_shape = "circle";     // center is camera content for any convex shape
  r.camera_content_mode = "fill";
  r.camera_opacity = 1.0;

  const RenderResult result = RenderComposedExport(r);
  ASSERT_TRUE(result.ok) << result.message;
  EXPECT_EQ(result.video_frames_written, 8u);

  // Locate the bubble center on the 320x320 canvas (same helper the pipeline
  // uses), then read that pixel across the output frames.
  const auto bubble = clingfy::capture::ComputeCameraBubbleRect(
      320.0, 320.0, /*has_center=*/true, 0.80, 0.80, /*layout_preset=*/"",
      /*size_factor=*/0.45);
  const int bx = static_cast<int>(bubble.x + bubble.width / 2.0);
  const int by = static_cast<int>(bubble.y + bubble.height / 2.0);

  std::vector<std::uint32_t> bubble_colors;
  if (!ReadFramePixelColors(fs::u8path(r.destination_path).wstring(), bx, by,
                            &bubble_colors)) {
    GTEST_SKIP() << "could not decode the reordered camera output";
  }
  ASSERT_GE(bubble_colors.size(), 6u) << "expected ~8 output frames";
  auto red_of = [](std::uint32_t c) { return static_cast<int>((c >> 16) & 0xFF); };
  // Output slot 0 (first half of frames) plays the LATER screen window (source
  // 133-267), so the camera — synced to source time — reaches its SECOND half
  // (yellow, high red). Slot 1 (last frames) plays the EARLIER window (source
  // 0-133) → camera FIRST half (green, low red). We take the MAX red over the
  // early frames rather than the exact first frame: the boundary frame sits at
  // the truncated 133 ms while the camera's yellow half starts at 133.33 ms, so
  // yellow appears from the next frame on. If SeekTo had not re-primed the
  // reader, the forward-only pull could not rewind and this inversion (yellow
  // early, green late) would not appear.
  const std::size_t mid = bubble_colors.size() / 2u;
  int max_red_early = 0;
  for (std::size_t i = 0; i < mid; ++i) {
    max_red_early = std::max(max_red_early, red_of(bubble_colors[i]));
  }
  const int last_red = red_of(bubble_colors.back());
  EXPECT_GT(max_red_early, 120)
      << "the camera's LATER half (yellow) must appear EARLY (the reordered "
         "later-source window)";
  EXPECT_LT(last_red, 120)
      << "the camera's EARLIER half (green) must appear LATE (the earlier-source "
         "window) — proving the camera reader re-primed on the backward seek";
  EXPECT_GT(max_red_early, last_red + 60)
      << "camera color must track SOURCE time across the reorder backward seek";

  std::error_code ec;
  fs::remove_all(dir, ec);
}

TEST(ExportPipelineTest, HeadTrimWithAudioExportsDualStream) {
  // Head-trim [50,250): the first decoded frames (0,33 ms) fall before the kept
  // range and are dropped, so the FIRST kept video frame is not at edited 0 —
  // exercising the A/V origin anchor + the buffered-audio flush (T2). Assert the
  // export succeeds with both streams and the expected kept-frame count.
  clingfy::graphics::D3DDevice device;
  if (device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }
  const auto dir = UniqueDir("clip_headtrim");
  const auto source = (dir / "source.mov").u8string();
  const auto dest = (dir / "out.mov").u8string();
  std::string skip_reason;
  if (!SynthesizeSource(&device, source, /*with_audio=*/true, &skip_reason,
                        /*audio_amplitude=*/8000)) {
    GTEST_SKIP() << skip_reason;
  }

  RenderRequest request;
  request.source_video_path = fs::u8path(source).wstring();
  request.destination_path = dest;
  request.layout = "square11";
  request.resolution = "auto";
  request.fit = "fit";
  request.fps_hint = kFps;
  request.clip_ranges = {clip_planner::ClipKeptRange{50, 250}};

  const RenderResult result = RenderComposedExport(request);
  ASSERT_TRUE(result.ok) << result.message;
  EXPECT_TRUE(result.had_audio);
  EXPECT_EQ(result.video_frames_written, 6u)
      << "frames at 66,99,133,166,199,233 ms are kept; 0 and 33 ms are trimmed";
  EXPECT_GT(result.audio_packets_written, 0u)
      << "kept audio must survive the buffer/flush + origin alignment";

  const ProbeResult probe = ProbeOutput(fs::u8path(dest).wstring());
  EXPECT_TRUE(probe.ok);
  EXPECT_TRUE(probe.has_audio) << "head-trim export lost its audio stream";

  std::error_code ec;
  fs::remove_all(dir, ec);
}

// ---- Editing port (color): the export bakes the grade -----------------------

// H.264 tolerance for graded-pixel comparisons: the synthesized source is
// itself H.264 (lossy once), the export re-encodes (lossy twice), and the
// color pass adds float→8bpc rounding. 18/255 absorbs all three while still
// failing loudly on a missing/misapplied grade (which moves channels by 50+).
constexpr int kGradedPixelTolerance = 18;

TEST(ExportPipelineTest, BakesSaturationGradeIntoExportedPixels) {
  // saturation -1 fully desaturates: the blue-ish source (0x3366CC) must come
  // out GRAY at the center — R≈G≈B. Before this slice the grade was silently
  // ignored, so the blue signature (B beats R by 100+) is the regression
  // fingerprint this test kills.
  clingfy::graphics::D3DDevice device;
  if (device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }
  const auto dir = UniqueDir("grade-sat");
  const auto source = (dir / "source.mov").u8string();
  const auto dest = (dir / "out.mov").u8string();

  std::string skip_reason;
  if (!SynthesizeSource(&device, source, /*with_audio=*/false, &skip_reason)) {
    GTEST_SKIP() << skip_reason;
  }

  RenderRequest request;
  request.source_video_path = fs::u8path(source).wstring();
  request.destination_path = dest;
  request.layout = "auto";
  request.resolution = "auto";
  request.fit = "fit";
  request.fps_hint = kFps;
  request.color_grade.saturation = -1.0;

  const RenderResult result = RenderComposedExport(request);
  ASSERT_TRUE(result.ok) << result.message;
  EXPECT_GT(result.video_frames_written, 0u);

  UINT w = 0;
  UINT h = 0;
  std::vector<std::uint32_t> pixels;
  if (!ReadFirstFrameBgra(fs::u8path(dest).wstring(), &w, &h, &pixels)) {
    GTEST_SKIP() << "could not decode the exported frame for pixel readback";
  }
  const auto chan = [](std::uint32_t px, int shift) {
    return static_cast<int>((px >> shift) & 0xFFu);
  };
  const std::uint32_t center = pixels[(h / 2) * w + (w / 2)];
  const int r = chan(center, 16);
  const int g = chan(center, 8);
  const int b = chan(center, 0);
  EXPECT_LT(std::abs(r - b), 30)
      << "saturation -1 must desaturate the blue source to gray; got r=" << r
      << " g=" << g << " b=" << b << " (grade ignored by the export?)";
  EXPECT_LT(std::abs(r - g), 30)
      << "saturation -1 must desaturate to gray; got r=" << r << " g=" << g
      << " b=" << b;

  std::error_code ec;
  fs::remove_all(dir, ec);
}

TEST(ExportPipelineTest, GradedPixelsMatchCpuPrediction) {
  // End-to-end validation of the whole D2D color chain (piecewise sRGB
  // linearization → 5x4 matrix at 16bpc float → re-encode) against the pure
  // CPU reference in color_grade.h. A missing linearization, an 8bpc
  // intermediate crushing values, or a transposed matrix each push the
  // channels well past the H.264 tolerance. Uses a composite grade so every
  // leg of the chain participates.
  clingfy::graphics::D3DDevice device;
  if (device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }
  const auto dir = UniqueDir("grade-cpu");
  const auto source = (dir / "source.mov").u8string();
  const auto dest = (dir / "out.mov").u8string();

  std::string skip_reason;
  if (!SynthesizeSource(&device, source, /*with_audio=*/false, &skip_reason)) {
    GTEST_SKIP() << skip_reason;
  }

  RenderRequest request;
  request.source_video_path = fs::u8path(source).wstring();
  request.destination_path = dest;
  request.layout = "auto";
  request.resolution = "auto";
  request.fit = "fit";
  request.fps_hint = kFps;
  request.color_grade.exposure = -0.5;  // darkens — the banding-risk region
  request.color_grade.saturation = 0.5;
  request.color_grade.contrast = 0.25;

  const RenderResult result = RenderComposedExport(request);
  ASSERT_TRUE(result.ok) << result.message;

  UINT w = 0;
  UINT h = 0;
  std::vector<std::uint32_t> pixels;
  if (!ReadFirstFrameBgra(fs::u8path(dest).wstring(), &w, &h, &pixels)) {
    GTEST_SKIP() << "could not decode the exported frame for pixel readback";
  }

  // CPU reference on the nominal source color (0x3366CC). The source's own
  // H.264 pass may already have shifted it a few counts; kGradedPixelTolerance
  // absorbs that. The prediction clamps to the displayable [0,255] range:
  // this composite grade drives red to a deep-negative linear value, and the
  // real 8-bit pipeline (D2D and macOS alike) floors it at 0 — the unclamped
  // mirrored-curve value only exists in the math helpers.
  const color::ColorMatrix matrix =
      color::BuildColorMatrix(request.color_grade);
  const auto graded = matrix.Apply(color::SrgbToLinear(0x33 / 255.0),
                                   color::SrgbToLinear(0x66 / 255.0),
                                   color::SrgbToLinear(0xCC / 255.0));
  const auto encode8 = [](double linear) {
    const double srgb = color::LinearToSrgb(linear);
    return static_cast<int>(
        std::lround(std::clamp(srgb, 0.0, 1.0) * 255.0));
  };
  const int expect_r = encode8(graded[0]);
  const int expect_g = encode8(graded[1]);
  const int expect_b = encode8(graded[2]);

  const auto chan = [](std::uint32_t px, int shift) {
    return static_cast<int>((px >> shift) & 0xFFu);
  };
  const std::uint32_t center = pixels[(h / 2) * w + (w / 2)];
  EXPECT_NEAR(chan(center, 16), expect_r, kGradedPixelTolerance)
      << "red channel diverges from the CPU reference — linearization, "
         "precision, or matrix bug in the D2D chain";
  EXPECT_NEAR(chan(center, 8), expect_g, kGradedPixelTolerance);
  EXPECT_NEAR(chan(center, 0), expect_b, kGradedPixelTolerance);

  std::error_code ec;
  fs::remove_all(dir, ec);
}

TEST(ExportPipelineTest, ColorGradePixelPathCanary) {
  // The graded-pixel tests above GTEST_SKIP when the environment lacks a D3D
  // device or H.264 decode — correct for arbitrary machines, but on the
  // known-good dev/CI box a skip would silently erase ALL enforced coverage
  // of the D2D color chain while reading green. Set
  // CLINGFY_REQUIRE_PIXEL_TESTS=1 in the environment that is known to
  // support decode (the Windows dev box / CI) to turn those skips into this
  // hard failure.
  char* required = nullptr;
  size_t len = 0;
  _dupenv_s(&required, &len, "CLINGFY_REQUIRE_PIXEL_TESTS");
  const bool require = required != nullptr && std::string(required) == "1";
  free(required);
  if (!require) {
    GTEST_SKIP() << "canary disarmed (set CLINGFY_REQUIRE_PIXEL_TESTS=1 on "
                    "the known-good environment)";
  }

  clingfy::graphics::D3DDevice device;
  ASSERT_FALSE(device.Create())
      << "CANARY: no D3D11 device on an environment that promises one — the "
         "graded-pixel tests are all silently skipping";
  const auto dir = UniqueDir("grade-canary");
  const auto source = (dir / "source.mov").u8string();
  std::string skip_reason;
  ASSERT_TRUE(
      SynthesizeSource(&device, source, /*with_audio=*/false, &skip_reason))
      << "CANARY: H.264 synth/decode unavailable on an environment that "
         "promises it — the graded-pixel tests are all silently skipping: "
      << skip_reason;
  std::error_code ec;
  fs::remove_all(dir, ec);
}

}  // namespace
}  // namespace clingfy::capture::export_
