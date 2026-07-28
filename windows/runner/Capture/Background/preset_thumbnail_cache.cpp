#include "Capture/Background/preset_thumbnail_cache.h"

#include <d2d1_1.h>
#include <shlobj.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <cstdint>
#include <filesystem>
#include <sstream>
#include <string>
#include <vector>

#include "Core/app_identity.h"
#include "Graphics/d3d_device.h"

namespace clingfy::capture::background {

namespace {

namespace fs = std::filesystem;
using Microsoft::WRL::ComPtr;

std::string Utf8FromWide(const std::wstring& wide) {
  if (wide.empty()) return {};
  const int needed = ::WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                                           static_cast<int>(wide.size()),
                                           nullptr, 0, nullptr, nullptr);
  if (needed <= 0) return {};
  std::string out(static_cast<size_t>(needed), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                        out.data(), needed, nullptr, nullptr);
  return out;
}

std::wstring WideFromUtf8(const std::string& utf8) {
  if (utf8.empty()) return {};
  const int needed = ::MultiByteToWideChar(
      CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
  if (needed <= 0) return {};
  std::wstring out(static_cast<size_t>(needed), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                        out.data(), needed);
  return out;
}

// A minimal headless D2D context. Built per render, not held: thumbnails are
// rendered a handful of times in a session (on a slider release, not per
// frame), and keeping a device alive for that would hold GPU memory for the
// entire app lifetime to save milliseconds nobody can perceive.
struct ThumbnailDevice {
  clingfy::graphics::D3DDevice d3d;
  ComPtr<ID2D1Factory1> factory;
  ComPtr<ID2D1Device> device;
  ComPtr<ID2D1DeviceContext> ctx;

  bool Create() {
    if (d3d.Create()) return false;
    if (FAILED(D2D1CreateFactory(
            D2D1_FACTORY_TYPE_SINGLE_THREADED, __uuidof(ID2D1Factory1), nullptr,
            reinterpret_cast<void**>(factory.GetAddressOf())))) {
      return false;
    }
    ComPtr<IDXGIDevice> dxgi;
    if (FAILED(d3d.device()->QueryInterface(IID_PPV_ARGS(dxgi.GetAddressOf())))) {
      return false;
    }
    if (FAILED(factory->CreateDevice(dxgi.Get(), &device))) return false;
    return SUCCEEDED(
        device->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &ctx));
  }
};

// Pulls the rendered bitmap back to the CPU. A GPU bitmap cannot be handed to
// WIC directly, and the readback is once-per-thumbnail so its cost is noise.
bool ReadBackBgra(ID2D1DeviceContext* ctx, ID2D1Bitmap1* src, UINT width,
                  UINT height, std::vector<std::uint8_t>* out) {
  const D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
      D2D1_BITMAP_OPTIONS_CPU_READ | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                        D2D1_ALPHA_MODE_PREMULTIPLIED));
  ComPtr<ID2D1Bitmap1> readable;
  if (FAILED(ctx->CreateBitmap(D2D1::SizeU(width, height), nullptr, 0, &props,
                               &readable))) {
    return false;
  }
  const D2D1_POINT_2U dest = D2D1::Point2U(0, 0);
  const D2D1_RECT_U rect = D2D1::RectU(0, 0, width, height);
  if (FAILED(readable->CopyFromBitmap(&dest, src, &rect))) return false;

  D2D1_MAPPED_RECT mapped{};
  if (FAILED(readable->Map(D2D1_MAP_OPTIONS_READ, &mapped))) return false;
  const size_t stride = static_cast<size_t>(width) * 4u;
  out->resize(stride * height);
  for (UINT row = 0; row < height; ++row) {
    std::memcpy(out->data() + stride * row,
                mapped.bits + static_cast<size_t>(row) * mapped.pitch, stride);
  }
  readable->Unmap();
  return true;
}

// COM for the WIC encoder. The app's main thread already has COM up, but this
// must not DEPEND on that: it is called from a method-channel handler, and a
// library that silently needs someone else to have initialized COM fails as an
// empty thumbnail with no explanation.
//
// RPC_E_CHANGED_MODE means the thread is already initialized in the other
// apartment model — COM is usable, and uninitializing someone else's apartment
// would be actively harmful, so that case takes no ownership.
class ScopedCom {
 public:
  ScopedCom() {
    const HRESULT hr = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    owns_ = SUCCEEDED(hr);
    usable_ = owns_ || hr == RPC_E_CHANGED_MODE;
  }
  ~ScopedCom() {
    if (owns_) ::CoUninitialize();
  }
  ScopedCom(const ScopedCom&) = delete;
  ScopedCom& operator=(const ScopedCom&) = delete;

  bool usable() const { return usable_; }

 private:
  bool owns_ = false;
  bool usable_ = false;
};

// Writes to a temp name and renames into place. Two pickers opening at once
// would otherwise race on the same file and one could read a half-written PNG.
bool WritePngAtomically(const std::string& path, const std::vector<std::uint8_t>& bgra,
                        UINT width, UINT height) {
  ComPtr<IWICImagingFactory> wic;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                              CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic)))) {
    return false;
  }

  const std::string temp_path = path + ".tmp";
  const std::wstring wide_temp = WideFromUtf8(temp_path);

  {
    ComPtr<IWICStream> stream;
    if (FAILED(wic->CreateStream(&stream))) return false;
    if (FAILED(stream->InitializeFromFilename(wide_temp.c_str(), GENERIC_WRITE))) {
      return false;
    }
    ComPtr<IWICBitmapEncoder> encoder;
    if (FAILED(wic->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder))) {
      return false;
    }
    if (FAILED(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache))) {
      return false;
    }
    ComPtr<IWICBitmapFrameEncode> frame;
    ComPtr<IPropertyBag2> props;
    if (FAILED(encoder->CreateNewFrame(&frame, &props))) return false;
    if (FAILED(frame->Initialize(props.Get()))) return false;
    if (FAILED(frame->SetSize(width, height))) return false;

    WICPixelFormatGUID format = GUID_WICPixelFormat32bppPBGRA;
    if (FAILED(frame->SetPixelFormat(&format))) return false;
    if (FAILED(frame->WritePixels(
            height, width * 4u, static_cast<UINT>(bgra.size()),
            const_cast<BYTE*>(bgra.data())))) {
      return false;
    }
    if (FAILED(frame->Commit())) return false;
    if (FAILED(encoder->Commit())) return false;
  }

  std::error_code ec;
  fs::rename(fs::path(temp_path), fs::path(path), ec);
  if (ec) {
    // Losing the race is fine — the winner wrote identical bytes, since the
    // filename is a hash of everything that decides the pixels.
    fs::remove(fs::path(temp_path), ec);
    return fs::exists(fs::path(path));
  }
  return true;
}

}  // namespace

std::string PresetThumbnailRoot() {
  DWORD needed = ::GetEnvironmentVariableW(L"CLINGFY_PRESET_THUMBNAIL_ROOT",
                                           nullptr, 0);
  if (needed > 0) {
    std::wstring value(needed, L'\0');
    const DWORD written = ::GetEnvironmentVariableW(
        L"CLINGFY_PRESET_THUMBNAIL_ROOT", value.data(), needed);
    if (written > 0 && written < needed) {
      value.resize(written);
      return Utf8FromWide(value);
    }
  }

  PWSTR raw = nullptr;
  std::string base;
  if (SUCCEEDED(::SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr,
                                       &raw)) &&
      raw != nullptr) {
    base = Utf8FromWide(std::wstring(raw));
    ::CoTaskMemFree(raw);
  }
  if (base.empty()) return {};
  return (fs::path(base) / clingfy::core::LocalAppDataFolderName() /
          "PresetThumbnails")
      .string();
}

std::string PresetThumbnailFileName(const CanvasPresetSpec& spec, UINT width,
                                    UINT height) {
  std::string key = CanvasPresetCacheKey(spec, width, height);
  // The key is built for comparison, not for a file system. Only these two
  // separators can appear in it, and neither is legal in a Windows filename.
  for (char& c : key) {
    if (c == '|' || c == ':') c = '_';
  }
  return key + ".png";
}

std::string PresetThumbnailPath(const CanvasPresetSpec& spec, UINT width,
                                UINT height) {
  const std::string root = PresetThumbnailRoot();
  if (root.empty()) return {};
  return (fs::path(root) / PresetThumbnailFileName(spec, width, height))
      .string();
}

std::string EnsurePresetThumbnail(const CanvasPresetSpec& spec, UINT width,
                                  UINT height) {
  if (width == 0 || height == 0) return {};
  const std::string path = PresetThumbnailPath(spec, width, height);
  if (path.empty()) return {};

  std::error_code ec;
  // Cache hit. Deliberately the FIRST thing checked: no GPU device is created,
  // so a picker that is merely rebuilding costs a stat per card.
  if (fs::exists(fs::path(path), ec) && !ec) return path;

  fs::create_directories(fs::path(path).parent_path(), ec);
  if (ec) return {};

  // Held for the whole render: the WIC factory is created under it, and the
  // encoder must not outlive the apartment.
  ScopedCom com;
  if (!com.usable()) return {};

  ThumbnailDevice gpu;
  if (!gpu.Create()) return {};

  ComPtr<ID2D1Bitmap1> bitmap =
      RenderCanvasPreset(gpu.ctx.Get(), width, height, spec);
  if (bitmap == nullptr) return {};

  std::vector<std::uint8_t> bgra;
  if (!ReadBackBgra(gpu.ctx.Get(), bitmap.Get(), width, height, &bgra)) {
    return {};
  }
  if (!WritePngAtomically(path, bgra, width, height)) return {};
  return path;
}

}  // namespace clingfy::capture::background
