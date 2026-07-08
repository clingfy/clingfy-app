// Unit tests for the DComp presenter's device-loss classifier (renderer
// redesign P4c). The rebuild integration is exercised on-screen by the armed
// SurvivesSimulatedDeviceLoss probe in camera_dcomp_overlay_poc_test.cpp; this
// pins the pure decision of WHICH HRESULTs mean "recreate the whole stack".

#include "Capture/Camera/camera_dcomp_device_loss.h"

#include <d2derr.h>
#include <dxgi.h>

#include <gtest/gtest.h>

namespace clingfy::capture {
namespace {

TEST(IsDeviceLostHResult, TrueForTheDeviceLossFamily) {
  EXPECT_TRUE(IsDeviceLostHResult(DXGI_ERROR_DEVICE_REMOVED));
  EXPECT_TRUE(IsDeviceLostHResult(DXGI_ERROR_DEVICE_RESET));
  EXPECT_TRUE(IsDeviceLostHResult(DXGI_ERROR_DEVICE_HUNG));
  EXPECT_TRUE(IsDeviceLostHResult(DXGI_ERROR_DRIVER_INTERNAL_ERROR));
  EXPECT_TRUE(IsDeviceLostHResult(D2DERR_RECREATE_TARGET));
}

TEST(IsDeviceLostHResult, FalseForSuccessAndNonLossFailures) {
  EXPECT_FALSE(IsDeviceLostHResult(S_OK));
  // A transient resize OOM is NOT device loss — it must not trigger a full
  // GPU-stack rebuild (it retries via the resize path instead).
  EXPECT_FALSE(IsDeviceLostHResult(E_OUTOFMEMORY));
  EXPECT_FALSE(IsDeviceLostHResult(E_INVALIDARG));
  EXPECT_FALSE(IsDeviceLostHResult(DXGI_ERROR_INVALID_CALL));
  EXPECT_FALSE(IsDeviceLostHResult(D2DERR_WRONG_STATE));
}

}  // namespace
}  // namespace clingfy::capture
