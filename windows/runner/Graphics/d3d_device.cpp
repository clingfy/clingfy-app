#include "Graphics/d3d_device.h"

namespace clingfy::graphics {

std::optional<D3DError> D3DDevice::Create() {
  if (device_ != nullptr) {
    return std::nullopt;
  }

  // Feature-level fallback chain: try the modern levels first, fall back
  // to 10.0 so the same code path runs on very old or virtualized GPUs.
  // WGC requires 10.0 at minimum.
  const D3D_FEATURE_LEVEL kLevels[] = {
      D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0,
      D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0,
  };

  // D3D11_CREATE_DEVICE_BGRA_SUPPORT is non-negotiable for WGC; it lets the
  // frame pool allocate DXGI surfaces in the format the Direct3D Interop
  // layer expects. Without it, FrameArrived never fires and the call site
  // gets only an opaque E_FAIL.
  UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;

  HRESULT hr = ::D3D11CreateDevice(
      /*pAdapter=*/nullptr,
      /*DriverType=*/D3D_DRIVER_TYPE_HARDWARE,
      /*Software=*/nullptr,
      /*Flags=*/flags,
      /*pFeatureLevels=*/kLevels,
      /*FeatureLevels=*/ARRAYSIZE(kLevels),
      /*SDKVersion=*/D3D11_SDK_VERSION,
      /*ppDevice=*/device_.GetAddressOf(),
      /*pFeatureLevel=*/&feature_level_,
      /*ppImmediateContext=*/context_.GetAddressOf());

  if (FAILED(hr)) {
    // Retry once with the WARP software adapter so the recording engine
    // can still produce something on a host without a hardware D3D11
    // driver (e.g. a fresh Windows-on-ARM emulation environment, or a
    // headless VM). The encoder's quality suffers but recording remains
    // functional, which matches the "MVP recording slice" goal.
    hr = ::D3D11CreateDevice(
        nullptr, D3D_DRIVER_TYPE_WARP, nullptr, flags, kLevels,
        ARRAYSIZE(kLevels), D3D11_SDK_VERSION, device_.GetAddressOf(),
        &feature_level_, context_.GetAddressOf());
  }

  if (FAILED(hr) || device_ == nullptr) {
    device_.Reset();
    context_.Reset();
    return D3DError{"Failed to create D3D11 device for WGC capture.", hr};
  }
  return std::nullopt;
}

void D3DDevice::Reset() {
  context_.Reset();
  device_.Reset();
  feature_level_ = static_cast<D3D_FEATURE_LEVEL>(0);
}

}  // namespace clingfy::graphics
