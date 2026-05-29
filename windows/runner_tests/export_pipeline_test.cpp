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

#include <cstdint>
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
