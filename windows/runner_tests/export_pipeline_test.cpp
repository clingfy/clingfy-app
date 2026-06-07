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
}

}  // namespace
}  // namespace clingfy::capture::export_
