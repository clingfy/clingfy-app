#include "Capture/Camera/camera_overlay_presenter.h"

#include <windows.h>

#include <algorithm>
#include <iterator>

#include "Bridge/Devices/device_probe_log.h"
#include "Bridge/native_log_publisher.h"
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

}  // namespace

bool ForceGdiOverlay() { return EnvSet(L"CLINGFY_FORCE_GDI_OVERLAY"); }

FloatingPlacement ComputeInitialFloatingPlacement(int work_left, int work_top,
                                                  int work_right,
                                                  int work_bottom) {
  const int work_w = work_right - work_left;
  const int work_h = work_bottom - work_top;
  FloatingPlacement place;
  place.width = std::max(160, work_w * 22 / 100);
  place.height = place.width * 9 / 16;
  const int margin = std::max(8, work_w * 3 / 100);
  place.x = work_left + std::max(0, work_w - place.width - margin);
  place.y = work_top + std::max(0, work_h - place.height - margin);
  place.rounded = true;
  return place;
}


std::shared_ptr<ICameraOverlayPresenter> CreateCameraOverlayPresenter() {
  // Renderer P4d: DirectComposition is the DEFAULT presenter — the full-style
  // live bubble (opacity / shadow / glow / chroma), WYSIWYG with the export.
  // The GDI bubble is now reached only by the kill switch below or by the
  // start-time fallback ladder (WDA-exclusion failure or the render
  // self-check), so a machine where DComp misbehaves still records with the
  // safe-mode bubble. The former CLINGFY_OVERLAY_DCOMP opt-in is retired.
  if (ForceGdiOverlay()) {
    clingfy::bridge::devices::LogDeviceProbe(
        "CameraOverlayPresenter: gdi (forced by CLINGFY_FORCE_GDI_OVERLAY)");
    return std::make_shared<CameraFloatingOverlay>();
  }
  clingfy::bridge::devices::LogDeviceProbe("CameraOverlayPresenter: dcomp");
  CameraDcompOverlay::Options options;
  // Fault injection promised by the ADR test strategy (§7), each simulating a
  // documented hardware scar so the fallback ladder is testable without
  // afflicted hardware. Test-only; never set in production:
  //  - WDA_FAIL: skip the exclusion call so wda_excluded() stays false (the
  //    Win11 SetWindowDisplayAffinity defect).
  //  - RENDER_NOTHING: the render self-check reports no pixels (the hybrid-GPU
  //    "renders nothing" scar the P4d flip has to be safe against).
  options.apply_capture_exclusion = !EnvSet(L"CLINGFY_TEST_DCOMP_WDA_FAIL");
  options.simulate_render_nothing = EnvSet(L"CLINGFY_TEST_DCOMP_RENDER_NOTHING");
  return std::make_shared<CameraDcompOverlay>(options);
}

std::shared_ptr<ICameraOverlayPresenter> StartCameraOverlayPresenter(
    const FloatingPlacement& placement) {
  // Ladder: try the selected presenter; a DComp presenter that fails to START
  // (GPU stack build OR the render self-check — the adapter rasterizes nothing)
  // or fails CAPTURE EXCLUSION (documented Win11 defect that clusters on
  // DComp-presented windows — plain GDI windows often still succeed there)
  // falls back to the GDI presenter. A GDI presenter without exclusion is kept
  // but never shown (existing engine rule). The resolved presenter is logged
  // once here — the per-recording active-presenter telemetry line (ADR §5).
  std::shared_ptr<ICameraOverlayPresenter> presenter =
      CreateCameraOverlayPresenter();
  const bool is_dcomp =
      dynamic_cast<CameraDcompOverlay*>(presenter.get()) != nullptr;
  if (presenter->Start(placement) &&
      (!is_dcomp || presenter->wda_excluded())) {
    clingfy::bridge::devices::LogDeviceProbe(
        is_dcomp ? "CameraOverlayPresenter: active = dcomp"
                 : "CameraOverlayPresenter: active = gdi");
    return presenter;
  }
  presenter->Stop();
  // The ladder's degradation steps log at WARN — they must be visible in
  // release logs/Sentry (a fleet-wide DComp regression or a bubble-less
  // recording is a support case, not verbose tracing).
  if (!is_dcomp) {
    clingfy::bridge::NativeLogPublisher::Instance().Warn(
        "Camera",
        "gdi presenter failed to start — no floating bubble");
    return nullptr;  // GDI already failed — nothing further to try.
  }
  clingfy::bridge::NativeLogPublisher::Instance().Warn(
      "Camera",
      "dcomp presenter failed (start, capture exclusion, or render "
      "self-check); falling back to gdi");
  presenter = std::make_shared<CameraFloatingOverlay>();
  if (presenter->Start(placement)) {
    clingfy::bridge::devices::LogDeviceProbe(
        "CameraOverlayPresenter: active = gdi (fallback)");
    return presenter;
  }
  presenter->Stop();
  clingfy::bridge::NativeLogPublisher::Instance().Warn(
      "Camera",
      "gdi fallback failed to start — no floating bubble");
  return nullptr;
}

}  // namespace clingfy::capture
