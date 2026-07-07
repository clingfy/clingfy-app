#include "Capture/Camera/camera_overlay_presenter.h"

#include <windows.h>

#include <iterator>

#include "Bridge/Devices/device_probe_log.h"
#include "Capture/Camera/camera_floating_overlay.h"

namespace clingfy::capture {

bool ForceGdiOverlay() {
  // Win32 read (not CRT getenv_s): SetEnvironmentVariableW at runtime — the
  // convention every other env switch and test in windows/ uses — is invisible
  // to the CRT's snapshotted copy. Returns 0 when unset or empty; a value
  // longer than the probe buffer returns the required size, still truthy.
  wchar_t buffer[8]{};
  return ::GetEnvironmentVariableW(L"CLINGFY_FORCE_GDI_OVERLAY", buffer,
                                   static_cast<DWORD>(std::size(buffer))) > 0;
}

std::shared_ptr<ICameraOverlayPresenter> CreateCameraOverlayPresenter() {
  const bool forced = ForceGdiOverlay();
  // P2: the GDI opaque window is the only presenter; the DComp attempt (with
  // this same GDI construction as its fallback) lands in P3 behind this seam.
  clingfy::bridge::devices::LogDeviceProbe(
      forced ? "CameraOverlayPresenter: gdi (forced by CLINGFY_FORCE_GDI_OVERLAY)"
             : "CameraOverlayPresenter: gdi");
  return std::make_shared<CameraFloatingOverlay>();
}

}  // namespace clingfy::capture
