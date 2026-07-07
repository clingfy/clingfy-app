#include "Capture/Camera/camera_overlay_presenter.h"

#include <cstdlib>

#include "Bridge/Devices/device_probe_log.h"
#include "Capture/Camera/camera_floating_overlay.h"

namespace clingfy::capture {

namespace {

// Support kill switch: any non-empty value pins the safe-mode GDI presenter,
// so a machine where the (P3) DComp path misbehaves can be unblocked without
// a new build.
bool ForceGdiOverlay() {
  char buffer[8]{};
  size_t required = 0;
  if (getenv_s(&required, buffer, sizeof(buffer), "CLINGFY_FORCE_GDI_OVERLAY") !=
      0) {
    // Value longer than the probe buffer still means "set".
    return required > 1;
  }
  return required > 1;  // required includes the terminator; >1 means non-empty.
}

}  // namespace

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
