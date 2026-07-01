#include "Encoding/mf_dxgi_manager.h"

#include <mfapi.h>

#include "Graphics/d3d_device.h"

namespace clingfy::encoding {

std::optional<DxgiManagerError> MfDxgiManager::Open(
    clingfy::graphics::D3DDevice& device) {
  if (device.device() == nullptr) {
    return DxgiManagerError{
        "Cannot open IMFDXGIDeviceManager without a D3D device.",
        E_INVALIDARG};
  }
  if (manager_ != nullptr) {
    return std::nullopt;
  }

  HRESULT hr = ::MFCreateDXGIDeviceManager(&reset_token_,
                                            manager_.GetAddressOf());
  if (FAILED(hr) || manager_ == nullptr) {
    manager_.Reset();
    return DxgiManagerError{"MFCreateDXGIDeviceManager failed.", hr};
  }

  hr = manager_->ResetDevice(device.device(), reset_token_);
  if (FAILED(hr)) {
    manager_.Reset();
    return DxgiManagerError{
        "IMFDXGIDeviceManager::ResetDevice failed — encoder cannot bind to "
        "the D3D device.",
        hr};
  }
  return std::nullopt;
}

void MfDxgiManager::Reset() {
  manager_.Reset();
  reset_token_ = 0;
}

}  // namespace clingfy::encoding
