#include "Capture/wgc_display_capture_backend.h"

#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <inspectable.h>
#include <Windows.Graphics.Capture.Interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>

// C++/WinRT projection headers come AFTER the classic Win32 / interop
// headers so the projection picks up the same module definitions the
// interop interfaces use.
#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>

#include <atomic>
#include <mutex>
#include <utility>

#include "Capture/captured_video_frame.h"
#include "Graphics/d3d_device.h"

namespace clingfy::capture {

namespace {

namespace wgc = winrt::Windows::Graphics::Capture;
namespace dxd3d = winrt::Windows::Graphics::DirectX::Direct3D11;
namespace dx = winrt::Windows::Graphics::DirectX;

// Wraps an ID3D11Device into the WinRT IDirect3DDevice projection so the
// Direct3D11CaptureFramePool can allocate surfaces against it. Returns a
// `nullptr` projection on failure; the caller maps that to a structured
// `RECORDING_ERROR`.
dxd3d::IDirect3DDevice WinRTDeviceFromD3D11(ID3D11Device* d3d_device) {
  if (d3d_device == nullptr) {
    return nullptr;
  }
  winrt::com_ptr<IDXGIDevice> dxgi_device;
  if (FAILED(d3d_device->QueryInterface(
          __uuidof(IDXGIDevice),
          reinterpret_cast<void**>(dxgi_device.put())))) {
    return nullptr;
  }
  winrt::com_ptr<::IInspectable> inspectable;
  if (FAILED(::CreateDirect3D11DeviceFromDXGIDevice(
          dxgi_device.get(),
          reinterpret_cast<::IInspectable**>(inspectable.put())))) {
    return nullptr;
  }
  return inspectable.as<dxd3d::IDirect3DDevice>();
}

}  // namespace

class WgcDisplayCaptureBackend::Impl {
 public:
  std::optional<WgcCaptureError> Start(HMONITOR monitor,
                                       clingfy::graphics::D3DDevice& device,
                                       VideoFrameQueue& queue);
  void Stop();
  WgcCaptureStats Stats() const;
  bool Running() const;

 private:
  void OnFrameArrived(
      wgc::Direct3D11CaptureFramePool const& sender,
      winrt::Windows::Foundation::IInspectable const& args);

  mutable std::mutex mutex_;
  bool running_ = false;
  VideoFrameQueue* queue_ = nullptr;

  wgc::GraphicsCaptureItem item_{nullptr};
  wgc::Direct3D11CaptureFramePool pool_{nullptr};
  wgc::GraphicsCaptureSession session_{nullptr};
  winrt::event_token frame_token_{};

  std::atomic<std::uint64_t> frames_received_{0};
  std::atomic<std::uint32_t> last_width_{0};
  std::atomic<std::uint32_t> last_height_{0};
};

std::optional<WgcCaptureError> WgcDisplayCaptureBackend::Impl::Start(
    HMONITOR monitor,
    clingfy::graphics::D3DDevice& device,
    VideoFrameQueue& queue) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (running_) {
    return WgcCaptureError{"WGC backend is already running.", S_FALSE};
  }
  if (monitor == nullptr || device.device() == nullptr) {
    return WgcCaptureError{
        "Invalid HMONITOR or D3D device for WGC capture.", E_INVALIDARG};
  }

  // Resolve the GraphicsCaptureItem from HMONITOR through the interop
  // activation factory. C++/WinRT has no projected `CreateForMonitor`
  // because the API predates WinRT projection metadata, so we go through
  // the classic COM interop interface.
  try {
    auto interop_factory =
        winrt::get_activation_factory<wgc::GraphicsCaptureItem,
                                      IGraphicsCaptureItemInterop>();
    wgc::GraphicsCaptureItem item{nullptr};
    const HRESULT hr = interop_factory->CreateForMonitor(
        monitor, winrt::guid_of<wgc::GraphicsCaptureItem>(),
        winrt::put_abi(item));
    if (FAILED(hr) || item == nullptr) {
      return WgcCaptureError{
          "GraphicsCaptureItem::CreateForMonitor failed.", hr};
    }

    auto winrt_device = WinRTDeviceFromD3D11(device.device());
    if (winrt_device == nullptr) {
      return WgcCaptureError{
          "Failed to construct IDirect3DDevice from D3D11 device.", E_FAIL};
    }

    // CreateFreeThreaded dispatches FrameArrived on the WinRT thread pool
    // — no DispatcherQueue required. Two buffers is enough for the Phase
    // 3B "frames just arrive" goal; Phase 3C will retune once the encoder
    // is consuming them.
    auto pool = wgc::Direct3D11CaptureFramePool::CreateFreeThreaded(
        winrt_device, dx::DirectXPixelFormat::B8G8R8A8UIntNormalized,
        /*numberOfBuffers=*/2, item.Size());

    // Bind state BEFORE registering the handler — the handler reads
    // `running_` / `queue_` under the same mutex, and the handler can fire
    // immediately after `StartCapture`.
    item_ = item;
    pool_ = pool;
    queue_ = &queue;
    running_ = true;

    frame_token_ = pool_.FrameArrived(
        [this](wgc::Direct3D11CaptureFramePool const& sender,
               winrt::Windows::Foundation::IInspectable const& args) {
          OnFrameArrived(sender, args);
        });

    session_ = pool_.CreateCaptureSession(item_);
    session_.StartCapture();
    return std::nullopt;
  } catch (winrt::hresult_error const& ex) {
    // Reset the partial state so a follow-up `Start` is a clean retry.
    running_ = false;
    queue_ = nullptr;
    item_ = nullptr;
    pool_ = nullptr;
    session_ = nullptr;
    return WgcCaptureError{winrt::to_string(ex.message()), ex.code()};
  }
}

void WgcDisplayCaptureBackend::Impl::OnFrameArrived(
    wgc::Direct3D11CaptureFramePool const& sender,
    winrt::Windows::Foundation::IInspectable const& /*args*/) {
  // Runs on a WinRT thread-pool thread. Keep the work in here tight — any
  // delay here translates directly into capture latency, and the frame
  // pool stalls if we hold more than `numberOfBuffers` frames open.

  VideoFrameQueue* queue_snapshot = nullptr;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!running_) {
      return;
    }
    queue_snapshot = queue_;
  }

  auto frame = sender.TryGetNextFrame();
  if (frame == nullptr) {
    return;
  }

  const auto size = frame.ContentSize();
  const auto timestamp = frame.SystemRelativeTime();
  last_width_.store(static_cast<std::uint32_t>(size.Width));
  last_height_.store(static_cast<std::uint32_t>(size.Height));
  frames_received_.fetch_add(1);

  if (queue_snapshot != nullptr) {
    CapturedVideoFrame out;
    out.width = static_cast<std::uint32_t>(size.Width);
    out.height = static_cast<std::uint32_t>(size.Height);
    out.timestamp_hns = timestamp.count();
    // Texture intentionally left null in Phase 3B — Phase 3C will copy
    // the surface into a staging texture (or use a separately-managed
    // texture pool) before pushing, since the WGC frame-pool buffer
    // gets recycled as soon as `frame` goes out of scope.
    queue_snapshot->Push(std::move(out));
  }

  // `frame` auto-closes on scope exit (Direct3D11CaptureFrame is
  // IClosable; C++/WinRT calls Close() in the destructor) so the buffer
  // returns to the pool for reuse.
}

void WgcDisplayCaptureBackend::Impl::Stop() {
  // Snapshot the WinRT objects under the lock, clear them inside the
  // lock so the FrameArrived handler sees `running_ == false`, then
  // close them OUTSIDE the lock so we don't deadlock against a callback
  // that's already running and waiting on the same mutex.
  wgc::Direct3D11CaptureFramePool pool{nullptr};
  wgc::GraphicsCaptureSession session{nullptr};
  winrt::event_token token{};
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!running_) {
      return;
    }
    running_ = false;
    queue_ = nullptr;
    pool = pool_;
    session = session_;
    token = frame_token_;
    pool_ = nullptr;
    session_ = nullptr;
    item_ = nullptr;
    frame_token_ = winrt::event_token{};
  }

  if (pool && token.value != 0) {
    pool.FrameArrived(token);
  }
  if (session) {
    session.Close();
  }
  if (pool) {
    pool.Close();
  }
}

WgcCaptureStats WgcDisplayCaptureBackend::Impl::Stats() const {
  WgcCaptureStats stats;
  stats.frame_width = last_width_.load();
  stats.frame_height = last_height_.load();
  stats.frames_received = frames_received_.load();
  return stats;
}

bool WgcDisplayCaptureBackend::Impl::Running() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return running_;
}

// ---- Public pimpl forwarding ----------------------------------------------

WgcDisplayCaptureBackend::WgcDisplayCaptureBackend()
    : impl_(std::make_unique<Impl>()) {}

WgcDisplayCaptureBackend::~WgcDisplayCaptureBackend() {
  if (impl_) {
    impl_->Stop();
  }
}

std::optional<WgcCaptureError> WgcDisplayCaptureBackend::Start(
    HMONITOR monitor,
    clingfy::graphics::D3DDevice& device,
    VideoFrameQueue& queue) {
  return impl_->Start(monitor, device, queue);
}

void WgcDisplayCaptureBackend::Stop() {
  if (impl_) {
    impl_->Stop();
  }
}

WgcCaptureStats WgcDisplayCaptureBackend::Stats() const {
  return impl_ ? impl_->Stats() : WgcCaptureStats{};
}

bool WgcDisplayCaptureBackend::running() const {
  return impl_ && impl_->Running();
}

}  // namespace clingfy::capture
