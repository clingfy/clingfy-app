// Device-gated parity tests for the stitched-preview decode front-end
// (editing port step 4-2). Prove that PreviewSourceReader decodes the source to
// BGRA correctly with forward reads AND that a per-range SeekTo re-primes at a
// later window (the capability the reorder pacer needs) — the "single-range
// forward decode" parity the step-4 plan calls for. Gated on a usable D3D11
// device (needed to synthesize the fixture); GTEST_SKIPs otherwise.

#include "Preview/preview_source_reader.h"

#include <gtest/gtest.h>

#include <d3d11.h>
#include <wrl/client.h>

#include <atomic>
#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <system_error>
#include <vector>

#include "Capture/captured_video_frame.h"
#include "Encoding/mf_sink_writer_encoder.h"
#include "Graphics/d3d_device.h"

namespace clingfy::preview {
namespace {

namespace fs = std::filesystem;
using Microsoft::WRL::ComPtr;

constexpr UINT kW = 64;
constexpr UINT kH = 48;
constexpr int kFrames = 8;
constexpr UINT kFps = 30;

fs::path UniqueDir(const std::string& tag) {
  static std::atomic<int> counter{0};
  const auto dir = fs::temp_directory_path() /
                   ("clingfy_psr_" + tag + "_" +
                    std::to_string(counter.fetch_add(1)));
  std::error_code ec;
  fs::create_directories(dir, ec);
  return dir;
}

ComPtr<ID3D11Texture2D> SolidTexture(ID3D11Device* dev, std::uint32_t bgra) {
  std::vector<std::uint32_t> pixels(static_cast<size_t>(kW) * kH, bgra);
  D3D11_TEXTURE2D_DESC desc{};
  desc.Width = kW;
  desc.Height = kH;
  desc.MipLevels = 1;
  desc.ArraySize = 1;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  D3D11_SUBRESOURCE_DATA init{};
  init.pSysMem = pixels.data();
  init.SysMemPitch = kW * 4u;
  ComPtr<ID3D11Texture2D> tex;
  if (FAILED(dev->CreateTexture2D(&desc, &init, tex.GetAddressOf()))) {
    return nullptr;
  }
  return tex;
}

// An 8-frame halves recording: frames 0-3 (ms 0,33,66,100) RED, frames 4-7
// (ms 133,166,200,233) BLUE, so a decoded frame's center pixel reveals which
// source half it came from.
bool SynthesizeHalves(clingfy::graphics::D3DDevice* device,
                      const std::string& path, std::string* skip) {
  clingfy::encoding::EncoderConfig cfg;
  cfg.output_path = path;
  cfg.width = kW;
  cfg.height = kH;
  cfg.fps = kFps;
  clingfy::encoding::MfSinkWriterEncoder encoder;
  if (auto err = encoder.Open(cfg, *device, std::nullopt)) {
    *skip = "encoder open failed: " + err->message;
    return false;
  }
  const std::int64_t dur = 10'000'000 / kFps;
  for (int i = 0; i < kFrames; ++i) {
    const std::uint32_t color =
        (i < kFrames / 2) ? 0xFFFF0000u : 0xFF0000FFu;  // red then blue
    clingfy::capture::CapturedVideoFrame f;
    f.texture = SolidTexture(device->device(), color);
    if (f.texture == nullptr) {
      *skip = "texture alloc failed";
      return false;
    }
    f.width = kW;
    f.height = kH;
    f.timestamp_hns = static_cast<std::int64_t>(i) * dur;
    if (auto err = encoder.WriteVideoFrame(f)) {
      *skip = "WriteVideoFrame failed: " + err->message;
      return false;
    }
  }
  if (auto err = encoder.Finalize()) {
    *skip = "finalize failed: " + err->message;
    return false;
  }
  return true;
}

// Center-pixel channels of a top-down BGRA frame buffer.
struct Center {
  int b = 0;
  int g = 0;
  int r = 0;
};
Center CenterOf(const std::vector<BYTE>& bgra, UINT w, UINT h) {
  const size_t off = (static_cast<size_t>(h / 2) * w + (w / 2)) * 4u;
  if (off + 2 >= bgra.size()) {
    return {};
  }
  return {bgra[off + 0], bgra[off + 1], bgra[off + 2]};
}

TEST(PreviewSourceReaderTest, ForwardDecodeYieldsSourceFramesInOrder) {
  clingfy::graphics::D3DDevice device;
  if (device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }
  const auto dir = UniqueDir("forward");
  const auto source = (dir / "source.mov").u8string();
  std::string skip;
  if (!SynthesizeHalves(&device, source, &skip)) {
    GTEST_SKIP() << skip;
  }

  auto reader = PreviewSourceReader::Create(fs::u8path(source).wstring());
  ASSERT_NE(reader, nullptr);
  EXPECT_EQ(reader->width(), kW);
  EXPECT_EQ(reader->height(), kH);

  std::vector<BYTE> bgra;
  std::int64_t ts = 0;
  std::vector<Center> centers;
  std::vector<std::int64_t> stamps;
  while (reader->ReadNextFrame(&bgra, &ts)) {
    centers.push_back(CenterOf(bgra, reader->width(), reader->height()));
    stamps.push_back(ts);
  }
  ASSERT_GE(centers.size(), 6u) << "expected ~8 decoded frames";
  // First decoded frame is the RED source half (R dominant); last is BLUE.
  EXPECT_GT(centers.front().r, centers.front().b + 40)
      << "first decoded frame should be the red source half";
  EXPECT_GT(centers.back().b, centers.back().r + 40)
      << "last decoded frame should be the blue source half";
  // Timestamps advance monotonically (forward decode, no seeks).
  for (size_t i = 1; i < stamps.size(); ++i) {
    EXPECT_GE(stamps[i], stamps[i - 1]);
  }

  std::error_code ec;
  fs::remove_all(dir, ec);
}

TEST(PreviewSourceReaderTest, SeekToRePrimesAtLaterWindow) {
  // The reorder capability: seeking to the later (blue) window and reading
  // forward must yield a BLUE frame — a per-range backward/forward seek, NOT a
  // per-frame seek. Proves the pacer can start a range mid-source.
  clingfy::graphics::D3DDevice device;
  if (device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }
  const auto dir = UniqueDir("seek");
  const auto source = (dir / "source.mov").u8string();
  std::string skip;
  if (!SynthesizeHalves(&device, source, &skip)) {
    GTEST_SKIP() << skip;
  }

  auto reader = PreviewSourceReader::Create(fs::u8path(source).wstring());
  ASSERT_NE(reader, nullptr);

  // Seek into the blue half (source 133 ms) and decode forward to a frame at or
  // past it (MF lands on the prior keyframe, so skip the red lead-in).
  reader->SeekTo(133);
  std::vector<BYTE> bgra;
  std::int64_t ts = 0;
  Center blue{};
  bool found = false;
  for (int guard = 0; guard < 16 && reader->ReadNextFrame(&bgra, &ts); ++guard) {
    if (ts >= 133) {
      blue = CenterOf(bgra, reader->width(), reader->height());
      found = true;
      break;
    }
  }
  ASSERT_TRUE(found) << "no frame decoded at/after the seek target";
  EXPECT_GT(blue.b, blue.r + 40)
      << "a frame from the later (blue) window must decode blue after SeekTo";

  std::error_code ec;
  fs::remove_all(dir, ec);
}

}  // namespace
}  // namespace clingfy::preview
