#ifndef RUNNER_GRAPHICS_D3D_DEVICE_H_
#define RUNNER_GRAPHICS_D3D_DEVICE_H_

#include <d3d11.h>
#include <wrl/client.h>

#include <optional>
#include <string>

// Owning wrapper around the `ID3D11Device` + immediate context that backs
// every Windows.Graphics.Capture frame pool. Two reasons for the dedicated
// type instead of inline `D3D11CreateDevice` calls:
//
//   1. WGC requires the device be created with the
//      `D3D11_CREATE_DEVICE_BGRA_SUPPORT` flag; forgetting that produces a
//      mysterious E_FAIL when the frame pool tries to allocate surfaces.
//      Centralizing creation keeps the flag honest.
//
//   2. The encoder (Phase 3C) needs the same device the capture frames
//      live on — handing both phases a `D3DDevice&` makes the shared
//      ownership obvious and lets the engine tear everything down in the
//      right order.
namespace clingfy::graphics {

struct D3DError {
  std::string message;
  HRESULT hr = 0;
};

class D3DDevice {
 public:
  // Creates the D3D11 device. Returns std::nullopt on success; otherwise a
  // D3DError the engine maps to a `RECORDING_ERROR` reply on the bridge.
  std::optional<D3DError> Create();

  ID3D11Device* device() const { return device_.Get(); }
  ID3D11DeviceContext* context() const { return context_.Get(); }
  D3D_FEATURE_LEVEL feature_level() const { return feature_level_; }

  bool ready() const { return device_ != nullptr; }

  void Reset();

 private:
  Microsoft::WRL::ComPtr<ID3D11Device> device_;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;
  D3D_FEATURE_LEVEL feature_level_ = static_cast<D3D_FEATURE_LEVEL>(0);
};

}  // namespace clingfy::graphics

#endif  // RUNNER_GRAPHICS_D3D_DEVICE_H_
