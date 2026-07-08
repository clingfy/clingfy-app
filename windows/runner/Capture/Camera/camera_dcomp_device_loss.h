#ifndef RUNNER_CAPTURE_CAMERA_CAMERA_DCOMP_DEVICE_LOSS_H_
#define RUNNER_CAPTURE_CAMERA_CAMERA_DCOMP_DEVICE_LOSS_H_

#include <winerror.h>

// Renderer redesign P4c — device-loss classification for the DirectComposition
// presenter. Pure (no device); unit-tested.
namespace clingfy::capture {

// True for the HRESULTs that mean "the D3D device is gone; recreate the whole
// GPU stack" — the set MSDN prescribes for handling on Present/EndDraw:
//   DXGI_ERROR_DEVICE_REMOVED / _RESET / _HUNG (adapter reset, TDR, driver
//   upgrade, external GPU unplug) and D2DERR_RECREATE_TARGET (D2D's own signal
//   that its device context must be rebuilt). Everything else (e.g. a transient
//   E_OUTOFMEMORY on a resize) is NOT device loss and must not trigger a full
//   rebuild.
bool IsDeviceLostHResult(HRESULT hr);

}  // namespace clingfy::capture

#endif  // RUNNER_CAPTURE_CAMERA_CAMERA_DCOMP_DEVICE_LOSS_H_
