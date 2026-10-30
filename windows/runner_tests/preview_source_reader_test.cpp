// Device-gated parity tests for the stitched-preview decode front-end
// (editing port step 4-2). Prove that PreviewSourceReader decodes the source to
// BGRA correctly with forward reads AND that a per-range SeekTo re-primes at a
// later window (the capability the reorder pacer needs) — the "single-range
// forward decode" parity the step-4 plan calls for. Gated on a usable D3D11
// device (needed to synthesize the fixture); GTEST_SKIPs otherwise.

#include "Preview/preview_source_reader.h"

#include <gtest/gtest.h>

#include <d3d11.h>
#include <d3d11_4.h>
#include <wrl/client.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <iostream>
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

TEST(PreviewSourceReaderTest, ReportsTheSourceDuration) {
  // W13: a converged preview builds its one-clip timeline from this.
  clingfy::graphics::D3DDevice device;
  if (device.Create()) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }
  const auto dir = UniqueDir("duration");
  const auto source = (dir / "source.mov").u8string();
  std::string skip;
  if (!SynthesizeHalves(&device, source, &skip)) {
    GTEST_SKIP() << skip;
  }
  auto reader = PreviewSourceReader::Create(fs::u8path(source).wstring());
  ASSERT_NE(reader, nullptr);
  // 8 frames at 30 fps: 266.7 ms of media.
  EXPECT_NEAR(static_cast<double>(reader->duration_ms()), 266.7, 40.0);
  std::error_code ec;
  fs::remove_all(dir, ec);
}

// --- GPU path (#296): decode on the drawing device, copy surface to surface --

struct VideoDevice {
  ComPtr<ID3D11Device> device;
  ComPtr<ID3D11DeviceContext> ctx;
  // Created like the preview engine's: BGRA, VIDEO_SUPPORT when available,
  // multithread-protected (MF decodes on its own threads).
  bool Create(bool video_support) {
    const UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT |
                       (video_support ? D3D11_CREATE_DEVICE_VIDEO_SUPPORT : 0);
    if (FAILED(::D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                   flags, nullptr, 0, D3D11_SDK_VERSION,
                                   device.GetAddressOf(), nullptr,
                                   ctx.GetAddressOf()))) {
      return false;
    }
    ComPtr<ID3D11Multithread> mt;
    if (SUCCEEDED(ctx.As(&mt))) {
      mt->SetMultithreadProtected(TRUE);
    }
    return true;
  }
  ComPtr<ID3D11Texture2D> Target(UINT w, UINT h) {
    D3D11_TEXTURE2D_DESC td{};
    td.Width = w;
    td.Height = h;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    ComPtr<ID3D11Texture2D> tex;
    device->CreateTexture2D(&td, nullptr, tex.GetAddressOf());
    return tex;
  }
  // The texture's pixels, top-down tightly packed (via a staging copy).
  std::vector<BYTE> ReadBack(ID3D11Texture2D* tex, UINT w, UINT h) {
    D3D11_TEXTURE2D_DESC td{};
    tex->GetDesc(&td);
    td.Usage = D3D11_USAGE_STAGING;
    td.BindFlags = 0;
    td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ComPtr<ID3D11Texture2D> staging;
    std::vector<BYTE> out;
    if (FAILED(device->CreateTexture2D(&td, nullptr, staging.GetAddressOf()))) {
      return out;
    }
    ctx->CopyResource(staging.Get(), tex);
    D3D11_MAPPED_SUBRESOURCE mapped{};
    if (FAILED(ctx->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped))) {
      return out;
    }
    out.resize(static_cast<size_t>(w) * h * 4u);
    for (UINT row = 0; row < h; ++row) {
      std::memcpy(out.data() + row * w * 4u,
                  static_cast<const BYTE*>(mapped.pData) + row * mapped.RowPitch,
                  w * 4u);
    }
    ctx->Unmap(staging.Get(), 0);
    return out;
  }
};

// Decode every frame through ReadNextSample + UploadFrame and return the
// centre colour each one put in the target texture.
std::vector<Center> DecodeAllThroughUpload(PreviewSourceReader* reader,
                                           VideoDevice* gpu) {
  std::vector<Center> centers;
  auto target = gpu->Target(reader->width(), reader->height());
  if (target == nullptr) {
    return centers;
  }
  PreviewDecodedFrame frame;
  while (reader->ReadNextSample(&frame)) {
    if (!reader->UploadFrame(frame, gpu->ctx.Get(), target.Get())) {
      break;
    }
    centers.push_back(CenterOf(
        gpu->ReadBack(target.Get(), reader->width(), reader->height()),
        reader->width(), reader->height()));
  }
  return centers;
}

TEST(PreviewSourceReaderGpuTest, DecodesOnTheDrawingDeviceWithTheSameFrames) {
  clingfy::graphics::D3DDevice encode_device;
  VideoDevice gpu;
  if (encode_device.Create() || !gpu.Create(/*video_support=*/true)) {
    GTEST_SKIP() << "no usable D3D11 video device in this environment";
  }
  const auto dir = UniqueDir("gpu");
  const auto source = (dir / "source.mov").u8string();
  std::string skip;
  if (!SynthesizeHalves(&encode_device, source, &skip)) {
    GTEST_SKIP() << skip;
  }
  auto reader = PreviewSourceReader::Create(fs::u8path(source).wstring(),
                                            gpu.device.Get());
  ASSERT_NE(reader, nullptr);
  if (!reader->gpu()) {
    GTEST_SKIP() << "this device cannot decode the stream; CPU path covered "
                    "by the fallback test";
  }
  EXPECT_EQ(reader->width(), kW);
  EXPECT_EQ(reader->height(), kH);
  const auto centers = DecodeAllThroughUpload(reader.get(), &gpu);
  ASSERT_GE(centers.size(), 6u) << "the probe read must be undone (seek to 0)";
  EXPECT_GT(centers.front().r, centers.front().b + 40) << "first frame red";
  EXPECT_GT(centers.back().b, centers.back().r + 40) << "last frame blue";

  // And the reorder capability still holds on this path.
  reader->SeekTo(133);
  PreviewDecodedFrame frame;
  bool found = false;
  auto target = gpu.Target(kW, kH);
  for (int guard = 0; guard < 16 && reader->ReadNextSample(&frame); ++guard) {
    if (frame.ts_ms >= 133) {
      ASSERT_TRUE(reader->UploadFrame(frame, gpu.ctx.Get(), target.Get()));
      const Center c = CenterOf(gpu.ReadBack(target.Get(), kW, kH), kW, kH);
      EXPECT_GT(c.b, c.r + 40) << "seek into the blue window decodes blue";
      found = true;
      break;
    }
  }
  EXPECT_TRUE(found);
  std::error_code ec;
  fs::remove_all(dir, ec);
}

TEST(PreviewSourceReaderGpuTest, WithoutADeviceItDecodesOnTheCpuAndStillUploads) {
  // The fallback the engine relies on when the GPU path is refused: a CPU
  // reader whose UploadFrame fills the same texture from system memory.
  // (A device without VIDEO_SUPPORT is not a way to force this: Media
  // Foundation still decodes onto it, measured on Intel Xe.)
  clingfy::graphics::D3DDevice encode_device;
  VideoDevice plain;
  if (encode_device.Create() || !plain.Create(/*video_support=*/false)) {
    GTEST_SKIP() << "no usable D3D11 device in this environment";
  }
  const auto dir = UniqueDir("gpu_fallback");
  const auto source = (dir / "source.mov").u8string();
  std::string skip;
  if (!SynthesizeHalves(&encode_device, source, &skip)) {
    GTEST_SKIP() << skip;
  }
  auto reader = PreviewSourceReader::Create(fs::u8path(source).wstring());
  ASSERT_NE(reader, nullptr);
  EXPECT_FALSE(reader->gpu());
  const auto centers = DecodeAllThroughUpload(reader.get(), &plain);
  ASSERT_GE(centers.size(), 6u);
  EXPECT_GT(centers.front().r, centers.front().b + 40);
  EXPECT_GT(centers.back().b, centers.back().r + 40);
  std::error_code ec;
  fs::remove_all(dir, ec);
}

// Opt-in throughput probe for the stitched preview's decode front-end, the
// path every preview plays through once passthrough converges onto it.
// CLINGFY_DECODE_BENCH_SOURCE=<file> decodes for up to 5 s of wall time on
// each path (CPU system memory, GPU surface-to-surface) and prints the
// sustained frame rate, upload included; skipped without it. It asserts
// nothing: it is a measurement, recorded in docs, not a gate.
double BenchDecodeFps(PreviewSourceReader* reader, ID3D11DeviceContext* ctx,
                      ID3D11Texture2D* dst, int* frames_out) {
  PreviewDecodedFrame frame;
  int frames = 0;
  const auto start = std::chrono::steady_clock::now();
  while (std::chrono::steady_clock::now() - start < std::chrono::seconds(5)) {
    if (!reader->ReadNextSample(&frame) ||
        !reader->UploadFrame(frame, ctx, dst)) {
      break;
    }
    ++frames;
  }
  ctx->Flush();
  const double wall =
      std::chrono::duration<double>(std::chrono::steady_clock::now() - start)
          .count();
  *frames_out = frames;
  return frames / wall;
}

TEST(PreviewSourceReaderBench, SustainedDecodeRate) {
  char* source = nullptr;
  size_t len = 0;
  _dupenv_s(&source, &len, "CLINGFY_DECODE_BENCH_SOURCE");
  const std::string path = source != nullptr ? source : "";
  free(source);
  if (path.empty()) {
    GTEST_SKIP() << "set CLINGFY_DECODE_BENCH_SOURCE to measure";
  }
  ComPtr<ID3D11Device> device;
  ComPtr<ID3D11DeviceContext> ctx;
  ASSERT_TRUE(SUCCEEDED(::D3D11CreateDevice(
      nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
      D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
      nullptr, 0, D3D11_SDK_VERSION, device.GetAddressOf(), nullptr,
      ctx.GetAddressOf())));
  ComPtr<ID3D11Multithread> mt;
  if (SUCCEEDED(ctx.As(&mt))) {
    mt->SetMultithreadProtected(TRUE);
  }
  for (const bool gpu : {false, true}) {
    auto reader = PreviewSourceReader::Create(fs::path(path).wstring(),
                                              gpu ? device.Get() : nullptr);
    ASSERT_NE(reader, nullptr) << path;
    D3D11_TEXTURE2D_DESC td{};
    td.Width = reader->width();
    td.Height = reader->height();
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    ComPtr<ID3D11Texture2D> dst;
    ASSERT_TRUE(SUCCEEDED(device->CreateTexture2D(&td, nullptr, &dst)));
    int frames = 0;
    const double fps = BenchDecodeFps(reader.get(), ctx.Get(), dst.Get(),
                                      &frames);
    std::cout << "[bench] " << (reader->gpu() ? "gpu" : "cpu") << " "
              << reader->width() << "x" << reader->height() << ": " << frames
              << " frames, " << fps << " fps decoded + uploaded\n";
  }
}

}  // namespace
}  // namespace clingfy::preview
