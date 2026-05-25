#ifndef RUNNER_ENCODING_MF_DXGI_MANAGER_H_
#define RUNNER_ENCODING_MF_DXGI_MANAGER_H_

#include <mfobjects.h>
#include <wrl/client.h>

#include <optional>
#include <string>

namespace clingfy::graphics {
class D3DDevice;
}

// Tiny RAII wrapper around `IMFDXGIDeviceManager`.
//
// The Phase 3C Sink Writer needs an `IMFDXGIDeviceManager` to engage the
// hardware H.264 encoder MFT. Without it, Media Foundation silently falls
// back to a software encoder — recording still works, but at maybe a
// fifth of the throughput on a 1080p signal. The wrapper isolates the
// `MFCreateDXGIDeviceManager` + `ResetDevice` dance so the encoder file
// stays focused on the sink-writer logic.
namespace clingfy::encoding {

struct DxgiManagerError {
  std::string message;
  HRESULT hr = 0;
};

class MfDxgiManager {
 public:
  // Builds the manager against `device`. Returns std::nullopt on success.
  std::optional<DxgiManagerError> Open(clingfy::graphics::D3DDevice& device);

  IMFDXGIDeviceManager* Get() const { return manager_.Get(); }
  bool ready() const { return manager_ != nullptr; }

  void Reset();

 private:
  Microsoft::WRL::ComPtr<IMFDXGIDeviceManager> manager_;
  UINT reset_token_ = 0;
};

}  // namespace clingfy::encoding

#endif  // RUNNER_ENCODING_MF_DXGI_MANAGER_H_
