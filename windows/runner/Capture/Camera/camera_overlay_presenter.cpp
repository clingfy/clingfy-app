#include "Capture/Camera/camera_overlay_presenter.h"

#include <windows.h>

#include <iterator>

#include "Bridge/Devices/device_probe_log.h"
#include "Capture/Camera/camera_dcomp_overlay.h"
#include "Capture/Camera/camera_floating_overlay.h"

namespace clingfy::capture {

namespace {

// Win32 read (not CRT getenv_s): SetEnvironmentVariableW at runtime — the
// convention every other env switch and test in windows/ uses — is invisible
// to the CRT's snapshotted copy. Returns 0 when unset or empty; a value
// longer than the probe buffer returns the required size, still truthy.
bool EnvSet(const wchar_t* name) {
  wchar_t buffer[8]{};
  return ::GetEnvironmentVariableW(name, buffer,
                                   static_cast<DWORD>(std::size(buffer))) > 0;
}

// P3 opt-in: the DirectComposition presenter is exercised only when explicitly
// requested, until the POC gate (renders on-screen + capture-excluded on the
// hardware matrix) flips the default in P4.
bool DcompOptIn() { return EnvSet(L"CLINGFY_OVERLAY_DCOMP"); }

}  // namespace

bool ForceGdiOverlay() { return EnvSet(L"CLINGFY_FORCE_GDI_OVERLAY"); }


std::shared_ptr<ICameraOverlayPresenter> CreateCameraOverlayPresenter() {
  const bool forced = ForceGdiOverlay();
  if (!forced && DcompOptIn()) {
    clingfy::bridge::devices::LogDeviceProbe(
        "CameraOverlayPresenter: dcomp (CLINGFY_OVERLAY_DCOMP)");
    return std::make_shared<CameraDcompOverlay>();
  }
  clingfy::bridge::devices::LogDeviceProbe(
      forced ? "CameraOverlayPresenter: gdi (forced by CLINGFY_FORCE_GDI_OVERLAY)"
             : "CameraOverlayPresenter: gdi");
  return std::make_shared<CameraFloatingOverlay>();
}

std::shared_ptr<ICameraOverlayPresenter> StartCameraOverlayPresenter(
    const FloatingPlacement& placement) {
  // Ladder: try the selected presenter; a DComp presenter that fails to START
  // (GPU stack) or fails CAPTURE EXCLUSION (documented Win11 defect that
  // clusters on DComp-presented windows — plain GDI windows often still
  // succeed there) falls back to the GDI presenter. A GDI presenter without
  // exclusion is kept but never shown (existing engine rule).
  std::shared_ptr<ICameraOverlayPresenter> presenter =
      CreateCameraOverlayPresenter();
  const bool is_dcomp =
      dynamic_cast<CameraDcompOverlay*>(presenter.get()) != nullptr;
  if (presenter->Start(placement) &&
      (!is_dcomp || presenter->wda_excluded())) {
    return presenter;
  }
  presenter->Stop();
  if (!is_dcomp) {
    return nullptr;  // GDI already failed — nothing further to try.
  }
  clingfy::bridge::devices::LogDeviceProbe(
      "CameraOverlayPresenter: dcomp failed (start or capture exclusion); "
      "falling back to gdi");
  presenter = std::make_shared<CameraFloatingOverlay>();
  if (presenter->Start(placement)) {
    return presenter;
  }
  presenter->Stop();
  return nullptr;
}

}  // namespace clingfy::capture
