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
#include <wrl/client.h>

#include <gtest/gtest.h>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <filesystem>
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
bool SynthesizeSource(clingfy::graphics::D3DDevice* device,
                      const std::string& path, bool with_audio,
                      std::string* skip_reason) {
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
      packet.samples.assign(static_cast<size_t>(kAudioFramesPerPacket) * 2u, 0);
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
