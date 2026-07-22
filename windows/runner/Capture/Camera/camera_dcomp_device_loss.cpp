#include "Capture/Camera/camera_dcomp_device_loss.h"

#include <d2derr.h>
#include <dxgi.h>

namespace clingfy::capture {

bool IsDeviceLostHResult(HRESULT hr) {
  switch (hr) {
    case DXGI_ERROR_DEVICE_REMOVED:
    case DXGI_ERROR_DEVICE_RESET:
    case DXGI_ERROR_DEVICE_HUNG:
    case DXGI_ERROR_DRIVER_INTERNAL_ERROR:
    case D2DERR_RECREATE_TARGET:
      return true;
    default:
      return false;
  }
}

}  // namespace clingfy::capture
