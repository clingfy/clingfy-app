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
#include <functional>
#include <memory>
#include <mutex>
#include <utility>

#include "Capture/captured_video_frame.h"
#include "Graphics/d3d_device.h"

// `IDirect3DDxgiInterfaceAccess` lets us pull the underlying
// ID3D11Texture2D out of the WinRT IDirect3DSurface that
// `Direct3D11CaptureFrame::Surface` returns. Microsoft's SDK header
// `Windows.Graphics.DirectX.Direct3D11.Interop.h` is supposed to declare
// this — and on most build configurations it does — but in some
// compiler / pre-processor combinations the C++ block stays guarded out
// and the symbol is missing. Forward-declaring it inline with the
// canonical IID (stable since Windows 8) keeps the build self-contained
// without forcing every consumer of this file to fight a
// platform-toolset version.
extern "C++" {
struct __declspec(uuid("A9B3D012-3DF2-4EE3-B8D1-8695F457D3C1"))
    IDirect3DDxgiInterfaceAccess : public IUnknown {
  virtual HRESULT __stdcall GetInterface(REFIID iid, void** p) = 0;
};
}

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
  std::optional<WgcCaptureError> StartForWindow(
      HWND window, clingfy::graphics::D3DDevice& device,
      VideoFrameQueue& queue);
  std::optional<WgcCaptureError> StartForArea(
      HMONITOR monitor, CaptureCropBox crop,
      clingfy::graphics::D3DDevice& device, VideoFrameQueue& queue);
  void Stop();
  void Pause();
  void Resume();
  bool Paused() const;
  WgcCaptureStats Stats() const;
  bool Running() const;
  void SetTargetLostCallback(std::function<void()> callback);
  std::function<void()> GetTargetLostCallbackForTesting();

 private:
  // Shared tail of both Start paths: builds the WinRT device + frame pool from
  // an already-resolved capture item, binds state, registers FrameArrived,
  // enables cursor capture (Phase 7 MVP), and starts the session. Assumes
  // `mutex_` is held and `running_ == false`. On a thrown WinRT error the
  // caller's catch resets the partial state.
  std::optional<WgcCaptureError> StartWithItem(
      wgc::GraphicsCaptureItem item, clingfy::graphics::D3DDevice& device,
      VideoFrameQueue& queue);

  // Reset partial state so a follow-up Start is a clean retry. Assumes the
  // mutex is held.
  void ResetPartialState();

  void OnFrameArrived(
      wgc::Direct3D11CaptureFramePool const& sender,
      winrt::Windows::Foundation::IInspectable const& args);

  // Copies a WGC frame's texture into a freshly-allocated staging texture
  // that the encoder can hold past the WGC frame's auto-close. Returns
  // nullptr if any of the COM calls fail; the FrameArrived handler treats
  // that as "drop this frame" rather than failing the recording.
  Microsoft::WRL::ComPtr<ID3D11Texture2D> CopyIntoStagingTexture(
      ID3D11Texture2D* source);

  mutable std::mutex mutex_;
  bool running_ = false;
  std::atomic<bool> paused_{false};
  // Phase 7.2: when set, every captured frame is cropped to this box (area
  // recording). Unset for full display / window capture.
  std::optional<CaptureCropBox> crop_;
  VideoFrameQueue* queue_ = nullptr;
  Microsoft::WRL::ComPtr<ID3D11Device> d3d_device_;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> d3d_context_;

  wgc::GraphicsCaptureItem item_{nullptr};
  wgc::Direct3D11CaptureFramePool pool_{nullptr};
  wgc::GraphicsCaptureSession session_{nullptr};
  winrt::event_token frame_token_{};

  // Phase 7.4: GraphicsCaptureItem.Closed handling. The Closed event raises a
  // hard re-entrancy problem the FrameArrived path does not have: closing the
  // target is what INITIATES teardown, so a naive "revoke the token in Stop"
  // would block forever — revoking a WinRT event waits for the in-flight
  // handler, and that handler is the one driving the teardown (directly when the
  // marshal runs inline, e.g. an uninitialized dispatcher or a saturated message
  // queue). It also can't safely capture a raw `this`: a Start that throws after
  // registration could destroy the Impl while a Closed delivery is still in
  // flight (use-after-free on the Impl mutex).
  //
  // So the handler captures a lifetime-independent shared guard instead of
  // `this`, and we NEVER revoke the token. A Closed delivery locks the guard,
  // bails if `alive` is false (Stop / failed-Start cleared it), else copies and
  // invokes the callback OUTSIDE the guard lock. The guard outlives the Impl via
  // the lambda's shared_ptr copy, so any late delivery is a safe no-op and there
  // is nothing to self-join. `target_lost_cb_` is the value installed before
  // Start; it is copied into the per-session guard in StartWithItem.
  struct ClosedHandlerState {
    std::mutex mutex;
    bool alive = false;
    std::function<void()> cb;
  };
  std::shared_ptr<ClosedHandlerState> closed_state_;
  std::function<void()> target_lost_cb_;

  // Phase 7.4: the fixed, even-clamped capture size resolved from the item at
  // Start. The non-crop (display / window) copy path pins the staging texture to
  // THIS size rather than the live surface size, so a window resized mid-
  // recording can never change the encoder input dims (the frame pool is fixed-
  // size — never Recreate()'d — so the surface stays this size anyway; pinning
  // makes "keep the original capture size" robust against driver variance and
  // never silently corrupts the output). Unused for area capture (crop_ wins).
  std::uint32_t capture_w_ = 0;
  std::uint32_t capture_h_ = 0;

  std::atomic<std::uint64_t> frames_received_{0};
  std::atomic<std::uint32_t> last_width_{0};
  std::atomic<std::uint32_t> last_height_{0};
};

void WgcDisplayCaptureBackend::Impl::ResetPartialState() {
  running_ = false;
  queue_ = nullptr;
  item_ = nullptr;
  pool_ = nullptr;
  session_ = nullptr;
  crop_.reset();
  // Disarm the Closed guard so a delivery in flight during a throwing Start (the
  // exact moment the target vanishes) is a safe no-op and never touches this
  // Impl after it is destroyed. The lambda still holds its own shared_ptr to the
  // guard, so this is lifetime-safe without revoking the token (which would
  // block on the very handler that may be in flight).
  if (closed_state_) {
    std::lock_guard<std::mutex> guard(closed_state_->mutex);
    closed_state_->alive = false;
    closed_state_->cb = nullptr;
  }
  closed_state_.reset();
  capture_w_ = 0;
  capture_h_ = 0;
}

std::optional<WgcCaptureError> WgcDisplayCaptureBackend::Impl::StartWithItem(
    wgc::GraphicsCaptureItem item,
    clingfy::graphics::D3DDevice& device,
    VideoFrameQueue& queue) {
  auto winrt_device = WinRTDeviceFromD3D11(device.device());
  if (winrt_device == nullptr) {
    return WgcCaptureError{
        "Failed to construct IDirect3DDevice from D3D11 device.", E_FAIL};
  }

  // CreateFreeThreaded dispatches FrameArrived on the WinRT thread pool
  // — no DispatcherQueue required. Two buffers is enough for the Phase
  // 3B "frames just arrive" goal; Phase 3C retuned once the encoder
  // consumes them. The item is already sized (monitor or window), so the
  // pool / encoder pick up the right dimensions for either target.
  auto pool = wgc::Direct3D11CaptureFramePool::CreateFreeThreaded(
      winrt_device, dx::DirectXPixelFormat::B8G8R8A8UIntNormalized,
      /*numberOfBuffers=*/2, item.Size());

  // Bind state BEFORE registering the handler — the handler reads
  // `running_` / `queue_` under the same mutex, and the handler can fire
  // immediately after `StartCapture`.
  item_ = item;
  pool_ = pool;
  queue_ = &queue;
  // Keep refcounts on the D3D device / context so the FrameArrived
  // copy path stays valid even if the engine's D3DDevice wrapper is
  // released mid-flight (the encoder, which also holds a refcount,
  // owns the actual device-lifetime contract).
  d3d_device_ = device.device();
  d3d_context_ = device.context();
  // Pin the fixed, even capture size from the item now (Phase 7.4). For
  // display/window this is the surface size the non-crop copy path will use for
  // every frame, so a later resize cannot change the encoder input dims. For
  // area capture crop_ is already set and takes precedence, so this is unused.
  const auto item_size = item_.Size();
  capture_w_ = item_size.Width > 0
                   ? EvenCaptureDimension(static_cast<std::uint32_t>(item_size.Width))
                   : 0;
  capture_h_ = item_size.Height > 0
                   ? EvenCaptureDimension(static_cast<std::uint32_t>(item_size.Height))
                   : 0;
  running_ = true;

  frame_token_ = pool_.FrameArrived(
      [this](wgc::Direct3D11CaptureFramePool const& sender,
             winrt::Windows::Foundation::IInspectable const& args) {
        OnFrameArrived(sender, args);
      });

  // Phase 7.4: target-loss. GraphicsCaptureItem.Closed fires when the captured
  // window is closed or the captured monitor is unplugged. Register BEFORE
  // StartCapture so an immediate close is not missed. The handler captures a
  // lifetime-independent shared guard (NOT `this`) so a delivery that races
  // teardown — or arrives after this Impl is destroyed — is always safe: it
  // checks `alive` and copies the callback under the guard's own mutex, then
  // invokes it OUTSIDE that lock (the callback marshals to the platform thread).
  // We deliberately do not retain/revoke the token: revoking would block on the
  // in-flight handler, and the handler is exactly what initiates teardown.
  closed_state_ = std::make_shared<ClosedHandlerState>();
  closed_state_->alive = true;
  closed_state_->cb = target_lost_cb_;
  {
    auto state = closed_state_;  // shared_ptr copy keeps the guard alive.
    item_.Closed([state](wgc::GraphicsCaptureItem const&,
                         winrt::Windows::Foundation::IInspectable const&) {
      std::function<void()> cb;
      {
        std::lock_guard<std::mutex> guard(state->mutex);
        if (!state->alive) {
          return;
        }
        cb = state->cb;
      }
      if (cb) {
        cb();
      }
    });
  }

  session_ = pool_.CreateCaptureSession(item_);
  // Phase 7 MVP: keep the OS cursor in the captured video. WGC's default is
  // also cursor-on, but set it explicitly so the Phase 8 cursor-sidecar flip
  // (to false) is a single greppable change. Best-effort — the property is
  // Win10 1903+; on older hosts the default (cursor-on) already applies.
  try {
    session_.IsCursorCaptureEnabled(true);
  } catch (winrt::hresult_error const&) {
    // Older OS without the property — leave the default (cursor-on).
  }
  session_.StartCapture();
  return std::nullopt;
}

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
  crop_.reset();  // full-display capture is never cropped.

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
    return StartWithItem(std::move(item), device, queue);
  } catch (winrt::hresult_error const& ex) {
    ResetPartialState();
    return WgcCaptureError{winrt::to_string(ex.message()), ex.code()};
  }
}

std::optional<WgcCaptureError> WgcDisplayCaptureBackend::Impl::StartForWindow(
    HWND window,
    clingfy::graphics::D3DDevice& device,
    VideoFrameQueue& queue) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (running_) {
    return WgcCaptureError{"WGC backend is already running.", S_FALSE};
  }
  if (window == nullptr || ::IsWindow(window) == 0 ||
      device.device() == nullptr) {
    return WgcCaptureError{
        "The selected window is no longer available.", E_INVALIDARG};
  }
  crop_.reset();  // window capture is not cropped.

  // The window analog of CreateForMonitor — same classic COM interop
  // interface, just CreateForWindow(HWND).
  try {
    auto interop_factory =
        winrt::get_activation_factory<wgc::GraphicsCaptureItem,
                                      IGraphicsCaptureItemInterop>();
    wgc::GraphicsCaptureItem item{nullptr};
    const HRESULT hr = interop_factory->CreateForWindow(
        window, winrt::guid_of<wgc::GraphicsCaptureItem>(),
        winrt::put_abi(item));
    if (FAILED(hr) || item == nullptr) {
      return WgcCaptureError{
          "GraphicsCaptureItem::CreateForWindow failed for the selected "
          "window.",
          hr};
    }
    return StartWithItem(std::move(item), device, queue);
  } catch (winrt::hresult_error const& ex) {
    ResetPartialState();
    return WgcCaptureError{winrt::to_string(ex.message()), ex.code()};
  }
}

std::optional<WgcCaptureError> WgcDisplayCaptureBackend::Impl::StartForArea(
    HMONITOR monitor,
    CaptureCropBox crop,
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
  if (crop.width == 0 || crop.height == 0) {
    return WgcCaptureError{"Empty area crop region.", E_INVALIDARG};
  }

  // Area capture = full-monitor capture (the display path) plus a per-frame
  // crop. Capture the monitor exactly as Start(HMONITOR) does, but stamp the
  // crop box so CopyIntoStagingTexture copies only the selected region.
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
    // Set the crop BEFORE StartWithItem so a FrameArrived firing right after
    // StartCapture already crops.
    crop_ = crop;
    return StartWithItem(std::move(item), device, queue);
  } catch (winrt::hresult_error const& ex) {
    ResetPartialState();
    return WgcCaptureError{winrt::to_string(ex.message()), ex.code()};
  }
}

Microsoft::WRL::ComPtr<ID3D11Texture2D>
WgcDisplayCaptureBackend::Impl::CopyIntoStagingTexture(
    ID3D11Texture2D* source) {
  if (source == nullptr || d3d_device_ == nullptr || d3d_context_ == nullptr) {
    return nullptr;
  }
  D3D11_TEXTURE2D_DESC src_desc{};
  source->GetDesc(&src_desc);

  // Decide the source region to copy:
  //   * Area recording (crop_ set): the resolved crop box (monitor-local px,
  //     already even via ResolveCropBox). Defensively confirm it fits this
  //     frame's surface — it does when WGC delivers the monitor at its native
  //     size, which is what the engine sized the crop against.
  //   * Display / window: the full surface clamped DOWN to even (H.264 needs
  //     even; WGC window content sizes are arbitrary). The same
  //     EvenCaptureDimension drives the encoder config, so the staging surface
  //     always matches the encoder input — a 1px odd edge is cropped, never
  //     size-mismatched. For an even source this box spans the whole surface
  //     (identical to the prior CopyResource).
  UINT box_x = 0;
  UINT box_y = 0;
  UINT box_w = 0;
  UINT box_h = 0;
  if (crop_) {
    box_x = crop_->x;
    box_y = crop_->y;
    box_w = crop_->width;
    box_h = crop_->height;
    if (box_w == 0 || box_h == 0 || box_x + box_w > src_desc.Width ||
        box_y + box_h > src_desc.Height) {
      return nullptr;  // crop does not fit this surface — drop the frame.
    }
  } else {
    // Phase 7.4: pin to the fixed initial capture size so a window resized
    // mid-recording keeps the encoder's input dims constant (H.264 needs fixed,
    // even dims — a drift here corrupts the stream). Fall back to the live
    // even-clamped surface size only if the initial probe came back empty.
    box_w = capture_w_ != 0 ? capture_w_ : EvenCaptureDimension(src_desc.Width);
    box_h = capture_h_ != 0 ? capture_h_ : EvenCaptureDimension(src_desc.Height);
    if (box_w == 0 || box_h == 0 || box_x + box_w > src_desc.Width ||
        box_y + box_h > src_desc.Height) {
      // Defensive invariant. With the fixed-size pool (never Recreate()'d) the
      // surface stays at the initial size, so the pinned box always fits and this
      // guard does not normally trip — it only fires on a degenerate surface or
      // if a future change (driver variance / pool Recreate) ever delivered a
      // smaller surface. Dropping the frame is the safe outcome: never emit a
      // size-mismatched frame to the encoder.
      return nullptr;
    }
  }

  // A fresh resource the encoder can hold past the WGC frame's auto-close. We
  // strip CPU-access flags because all consumption happens on the GPU, and
  // request RenderTarget + ShaderResource bind so the H.264 MFT can attach the
  // texture as input — both bind flags are widely supported and forgiving
  // across drivers.
  D3D11_TEXTURE2D_DESC dst_desc{};
  dst_desc.Width = box_w;
  dst_desc.Height = box_h;
  dst_desc.MipLevels = 1;
  dst_desc.ArraySize = 1;
  dst_desc.Format = src_desc.Format;
  dst_desc.SampleDesc.Count = 1;
  dst_desc.SampleDesc.Quality = 0;
  dst_desc.Usage = D3D11_USAGE_DEFAULT;
  dst_desc.BindFlags =
      D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  dst_desc.CPUAccessFlags = 0;
  dst_desc.MiscFlags = 0;

  Microsoft::WRL::ComPtr<ID3D11Texture2D> staging;
  HRESULT hr = d3d_device_->CreateTexture2D(&dst_desc, nullptr,
                                             staging.GetAddressOf());
  if (FAILED(hr) || staging == nullptr) {
    return nullptr;
  }
  D3D11_BOX box{};
  box.left = box_x;
  box.top = box_y;
  box.front = 0;
  box.right = box_x + box_w;
  box.bottom = box_y + box_h;
  box.back = 1;
  d3d_context_->CopySubresourceRegion(staging.Get(), 0, 0, 0, 0, source, 0,
                                      &box);
  return staging;
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

  // Phase 4 pause path: WGC keeps producing frames (closing the pool
  // would race the GraphicsCaptureSession activation if the user
  // resumes a moment later). We just drop them here. The frame auto-
  // closes on scope exit so the pool's surface returns immediately.
  if (paused_.load()) {
    return;
  }

  const auto size = frame.ContentSize();
  const auto timestamp = frame.SystemRelativeTime();
  frames_received_.fetch_add(1);

  // Extract the underlying D3D11 texture from the WGC frame's
  // IDirect3DSurface via the interop interface, then copy it into a
  // staging texture WE own so the encoder can hold the pixels past
  // `frame`'s auto-close. The leading `::` on the COM interface name
  // disambiguates it from any C++/WinRT projection of the same name.
  Microsoft::WRL::ComPtr<ID3D11Texture2D> staging;
  bool has_crop = false;
  std::uint32_t crop_w = 0;
  std::uint32_t crop_h = 0;
  {
    auto surface = frame.Surface();
    auto access = surface.as<::IDirect3DDxgiInterfaceAccess>();
    Microsoft::WRL::ComPtr<ID3D11Texture2D> source;
    if (SUCCEEDED(access->GetInterface(
            __uuidof(ID3D11Texture2D),
            reinterpret_cast<void**>(source.GetAddressOf()))) &&
        source != nullptr) {
      std::lock_guard<std::mutex> lock(mutex_);
      // Snapshot the crop intent under the lock so the reported dimensions are
      // the cropped size even on a (defensive) dropped frame — otherwise a
      // dropped area frame would report the full-monitor size, contradicting
      // the crop-sized output the encoder is configured for.
      if (crop_) {
        has_crop = true;
        crop_w = crop_->width;
        crop_h = crop_->height;
      }
      staging = CopyIntoStagingTexture(source.Get());
    }
  }

  // Frame dimensions follow the (even-clamped) staging texture so they always
  // match the encoder's even input type. When the copy is dropped (null
  // texture, encoder skips it), fall back to the intended output size: the crop
  // box for area capture, else the raw content size.
  std::uint32_t out_width = has_crop ? crop_w : static_cast<std::uint32_t>(size.Width);
  std::uint32_t out_height =
      has_crop ? crop_h : static_cast<std::uint32_t>(size.Height);
  if (staging != nullptr) {
    D3D11_TEXTURE2D_DESC staged_desc{};
    staging->GetDesc(&staged_desc);
    out_width = staged_desc.Width;
    out_height = staged_desc.Height;
  }
  last_width_.store(out_width);
  last_height_.store(out_height);

  if (queue_snapshot != nullptr) {
    CapturedVideoFrame out;
    out.width = out_width;
    out.height = out_height;
    out.timestamp_hns = timestamp.count();
    out.texture = staging;  // null if the copy failed -> encoder skips it.
    queue_snapshot->Push(std::move(out));
  }

  // `frame` auto-closes on scope exit (Direct3D11CaptureFrame is
  // IClosable; C++/WinRT calls Close() in the destructor) so the buffer
  // returns to the pool for reuse.
}

void WgcDisplayCaptureBackend::Impl::SetTargetLostCallback(
    std::function<void()> callback) {
  std::lock_guard<std::mutex> lock(mutex_);
  target_lost_cb_ = std::move(callback);
}

std::function<void()>
WgcDisplayCaptureBackend::Impl::GetTargetLostCallbackForTesting() {
  // Return the callback a real Closed delivery would invoke — the live guard's
  // copy when a session is running, else the pending one. The caller invokes it.
  std::lock_guard<std::mutex> lock(mutex_);
  if (closed_state_) {
    std::lock_guard<std::mutex> guard(closed_state_->mutex);
    return closed_state_->alive ? closed_state_->cb : std::function<void()>{};
  }
  return target_lost_cb_;
}

void WgcDisplayCaptureBackend::Impl::Stop() {
  // Snapshot the WinRT objects under the lock, clear them inside the
  // lock so the FrameArrived handler sees `running_ == false`, then
  // close them OUTSIDE the lock so we don't deadlock against a callback
  // that's already running and waiting on the same mutex.
  wgc::Direct3D11CaptureFramePool pool{nullptr};
  wgc::GraphicsCaptureSession session{nullptr};
  std::shared_ptr<ClosedHandlerState> closed_state;
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
    // Disarm the Closed guard INSIDE the lock: once `alive` is false (under the
    // guard's own mutex), any later Closed delivery is a no-op. We do NOT revoke
    // the Closed token — revoking blocks on the in-flight handler, and when a
    // target loss is what drove this Stop, that handler IS our caller (a self-
    // join). The guard outlives us via the lambda's shared_ptr, so dropping our
    // reference here is safe. Lock order is always Impl-mutex → guard-mutex (the
    // handler only ever takes the guard mutex), so this nested lock cannot
    // deadlock.
    closed_state = closed_state_;
    if (closed_state) {
      std::lock_guard<std::mutex> guard(closed_state->mutex);
      closed_state->alive = false;
      closed_state->cb = nullptr;
    }
    closed_state_.reset();
    target_lost_cb_ = nullptr;
    capture_w_ = 0;
    capture_h_ = 0;
    d3d_context_.Reset();
    d3d_device_.Reset();
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

void WgcDisplayCaptureBackend::Impl::Pause() {
  paused_.store(true);
}

void WgcDisplayCaptureBackend::Impl::Resume() {
  paused_.store(false);
}

bool WgcDisplayCaptureBackend::Impl::Paused() const {
  return paused_.load();
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

std::optional<WgcCaptureError> WgcDisplayCaptureBackend::StartForWindow(
    HWND window,
    clingfy::graphics::D3DDevice& device,
    VideoFrameQueue& queue) {
  return impl_->StartForWindow(window, device, queue);
}

std::optional<WgcCaptureError> WgcDisplayCaptureBackend::StartForArea(
    HMONITOR monitor,
    CaptureCropBox crop,
    clingfy::graphics::D3DDevice& device,
    VideoFrameQueue& queue) {
  return impl_->StartForArea(monitor, crop, device, queue);
}

std::optional<WgcTargetSize> ResolveWindowCaptureSize(HWND window) {
  if (window == nullptr || ::IsWindow(window) == 0) {
    return std::nullopt;
  }
  // Build a throwaway capture item just to read the size WGC will deliver for
  // this window, so the engine can size the encoder to the window before the
  // real StartForWindow item is created. (The window is assumed stable across
  // the few microseconds between this probe and StartForWindow — resize-follow
  // is Phase 7.4.)
  try {
    auto interop_factory =
        winrt::get_activation_factory<wgc::GraphicsCaptureItem,
                                      IGraphicsCaptureItemInterop>();
    wgc::GraphicsCaptureItem item{nullptr};
    const HRESULT hr = interop_factory->CreateForWindow(
        window, winrt::guid_of<wgc::GraphicsCaptureItem>(),
        winrt::put_abi(item));
    if (FAILED(hr) || item == nullptr) {
      return std::nullopt;
    }
    const auto size = item.Size();
    if (size.Width <= 0 || size.Height <= 0) {
      return std::nullopt;
    }
    return WgcTargetSize{static_cast<std::uint32_t>(size.Width),
                         static_cast<std::uint32_t>(size.Height)};
  } catch (winrt::hresult_error const&) {
    return std::nullopt;
  }
}

std::uint32_t EvenCaptureDimension(std::uint32_t value) {
  // Clamp down to the nearest even value (H.264 even-dimension requirement).
  return value & ~1u;
}

CaptureCropBox ResolveCropBox(std::uint32_t src_width, std::uint32_t src_height,
                              std::int64_t req_x, std::int64_t req_y,
                              std::int64_t req_width, std::int64_t req_height) {
  CaptureCropBox box;
  if (src_width == 0 || src_height == 0) {
    return box;  // no surface — empty box.
  }
  const std::int64_t sw = static_cast<std::int64_t>(src_width);
  const std::int64_t sh = static_cast<std::int64_t>(src_height);

  // Clamp the origin into the surface.
  std::int64_t x = req_x < 0 ? 0 : (req_x > sw ? sw : req_x);
  std::int64_t y = req_y < 0 ? 0 : (req_y > sh ? sh : req_y);
  // Clamp the size to what remains from the (clamped) origin.
  std::int64_t w = req_width < 0 ? 0 : req_width;
  std::int64_t h = req_height < 0 ? 0 : req_height;
  if (x + w > sw) {
    w = sw - x;
  }
  if (y + h > sh) {
    h = sh - y;
  }

  box.x = static_cast<std::uint32_t>(x);
  box.y = static_cast<std::uint32_t>(y);
  box.width = EvenCaptureDimension(static_cast<std::uint32_t>(w));
  box.height = EvenCaptureDimension(static_cast<std::uint32_t>(h));
  return box;
}

void WgcDisplayCaptureBackend::Stop() {
  if (impl_) {
    impl_->Stop();
  }
}

void WgcDisplayCaptureBackend::Pause() {
  if (impl_) {
    impl_->Pause();
  }
}

void WgcDisplayCaptureBackend::Resume() {
  if (impl_) {
    impl_->Resume();
  }
}

bool WgcDisplayCaptureBackend::paused() const {
  return impl_ && impl_->Paused();
}

WgcCaptureStats WgcDisplayCaptureBackend::Stats() const {
  return impl_ ? impl_->Stats() : WgcCaptureStats{};
}

bool WgcDisplayCaptureBackend::running() const {
  return impl_ && impl_->Running();
}

void WgcDisplayCaptureBackend::SetTargetLostCallback(
    std::function<void()> callback) {
  if (impl_) {
    impl_->SetTargetLostCallback(std::move(callback));
  }
}

std::function<void()> WgcDisplayCaptureBackend::GetTargetLostCallbackForTesting() {
  return impl_ ? impl_->GetTargetLostCallbackForTesting()
               : std::function<void()>{};
}

}  // namespace clingfy::capture
