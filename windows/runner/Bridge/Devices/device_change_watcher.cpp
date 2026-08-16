#include "Bridge/Devices/device_change_watcher.h"

#include <dbt.h>
#include <ks.h>
#include <ksmedia.h>
#include <mmdeviceapi.h>
#include <wrl/client.h>

#include <atomic>
#include <future>
#include <mutex>
#include <thread>

#include "Bridge/Devices/device_probe_log.h"
#include "Bridge/device_event_publisher.h"

namespace clingfy::bridge::devices {

namespace {

using Microsoft::WRL::ComPtr;

constexpr wchar_t kWindowClass[] = L"ClingfyDeviceChangeWatcher";

// WASAPI endpoint notifications. Every method is called on a COM worker
// thread, so each one does nothing but hand the publisher a debounced request.
class EndpointNotificationClient : public IMMNotificationClient {
 public:
  // Not reference-counted in any meaningful sense: the single instance is
  // owned by Impl and outlives its registration, which is unregistered before
  // destruction. AddRef/Release are required by the interface but the object
  // is never destroyed through them.
  ULONG STDMETHODCALLTYPE AddRef() override { return 1; }
  ULONG STDMETHODCALLTYPE Release() override { return 1; }

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid,
                                           void** ppv) override {
    if (ppv == nullptr) return E_POINTER;
    if (riid == __uuidof(IUnknown) || riid == __uuidof(IMMNotificationClient)) {
      *ppv = static_cast<IMMNotificationClient*>(this);
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }

  HRESULT STDMETHODCALLTYPE OnDeviceAdded(LPCWSTR) override {
    DeviceEventPublisher::Instance().EmitAudioSourcesChanged();
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE OnDeviceRemoved(LPCWSTR) override {
    DeviceEventPublisher::Instance().EmitAudioSourcesChanged();
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE OnDeviceStateChanged(LPCWSTR, DWORD) override {
    // Covers the unplug/replug of a jack, which does not add or remove an
    // endpoint but does change whether it can be recorded from.
    DeviceEventPublisher::Instance().EmitAudioSourcesChanged();
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE OnDefaultDeviceChanged(EDataFlow flow, ERole role,
                                                   LPCWSTR) override {
    if (role != eConsole) {
      return S_OK;  // one notification per role; eConsole is the one we track
    }
    if (flow == eRender) {
      // The output route changed — this is what the speaker-bleed warning
      // needs, and it has never fired on Windows before now.
      DeviceEventPublisher::Instance().EmitAudioOutputRouteChanged();
    } else {
      DeviceEventPublisher::Instance().EmitAudioSourcesChanged();
    }
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE OnPropertyValueChanged(LPCWSTR,
                                                   const PROPERTYKEY) override {
    // Deliberately NOT forwarded. This fires for volume and every other
    // endpoint property, many times per second while a user drags a slider,
    // and none of it changes the device LIST. Forwarding it would make the
    // debouncer the only thing standing between Dart and a re-enumeration
    // storm.
    return S_OK;
  }
};

}  // namespace

class DeviceChangeWatcher::Impl {
 public:
  bool Start() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (running_) {
      return true;
    }
    bool any = false;
    any |= StartAudioLocked();
    any |= StartWindowLocked();
    running_ = any;
    return any;
  }

  void Stop() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!running_) {
      return;
    }
    if (enumerator_ != nullptr) {
      enumerator_->UnregisterEndpointNotificationCallback(&notification_client_);
      enumerator_.Reset();
    }
    if (device_notify_ != nullptr) {
      ::UnregisterDeviceNotification(device_notify_);
      device_notify_ = nullptr;
    }
    if (hwnd_ != nullptr) {
      ::PostMessageW(hwnd_, WM_CLOSE, 0, 0);
      hwnd_ = nullptr;
    }
    if (thread_.joinable()) {
      thread_.join();
    }
    running_ = false;
  }

  bool running() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return running_;
  }

  ~Impl() { Stop(); }

 private:
  bool StartAudioLocked() {
    // MTA: these callbacks arrive on COM worker threads and the enumerator is
    // used from this thread only for registration.
    const HRESULT hr = ::CoCreateInstance(
        __uuidof(MMDeviceEnumerator), nullptr, CLSCTX_INPROC_SERVER,
        __uuidof(IMMDeviceEnumerator), &enumerator_);
    if (FAILED(hr) || enumerator_ == nullptr) {
      LogDeviceProbe(
          "DeviceChangeWatcher: MMDeviceEnumerator unavailable — audio hot-plug "
          "notifications are off for this session");
      enumerator_.Reset();
      return false;
    }
    if (FAILED(enumerator_->RegisterEndpointNotificationCallback(
            &notification_client_))) {
      LogDeviceProbe(
          "DeviceChangeWatcher: RegisterEndpointNotificationCallback failed");
      enumerator_.Reset();
      return false;
    }
    return true;
  }

  bool StartWindowLocked() {
    std::promise<HWND> ready;
    auto ready_future = ready.get_future();
    thread_ = std::thread([this, &ready] { WindowThread(ready); });
    hwnd_ = ready_future.get();
    if (hwnd_ == nullptr) {
      if (thread_.joinable()) {
        thread_.join();
      }
      return false;
    }
    return true;
  }

  void WindowThread(std::promise<HWND>& ready) {
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = &Impl::WindowProc;
    wc.hInstance = ::GetModuleHandleW(nullptr);
    wc.lpszClassName = kWindowClass;
    ::RegisterClassExW(&wc);  // benign failure if already registered

    HWND hwnd = ::CreateWindowExW(0, kWindowClass, L"", 0, 0, 0, 0, 0,
                                  HWND_MESSAGE, nullptr, wc.hInstance, this);
    if (hwnd == nullptr) {
      LogDeviceProbe(
          "DeviceChangeWatcher: message-only window creation failed — camera "
          "and display hot-plug notifications are off for this session");
      ready.set_value(nullptr);
      return;
    }

    // Cameras. WASAPI says nothing about video devices, so this is the only
    // source for "a webcam was plugged in".
    DEV_BROADCAST_DEVICEINTERFACE_W filter{};
    filter.dbcc_size = sizeof(filter);
    filter.dbcc_devicetype = DBT_DEVTYP_DEVICEINTERFACE;
    filter.dbcc_classguid = KSCATEGORY_VIDEO_CAMERA;
    device_notify_ = ::RegisterDeviceNotificationW(
        hwnd, &filter, DEVICE_NOTIFY_WINDOW_HANDLE);
    if (device_notify_ == nullptr) {
      LogDeviceProbe(
          "DeviceChangeWatcher: RegisterDeviceNotification(camera) failed — "
          "display events still active");
    }

    ready.set_value(hwnd);

    MSG msg;
    while (::GetMessageW(&msg, nullptr, 0, 0) > 0) {
      ::TranslateMessage(&msg);
      ::DispatchMessageW(&msg);
    }
    ::DestroyWindow(hwnd);
  }

  static LRESULT CALLBACK WindowProc(HWND hwnd, UINT msg, WPARAM wparam,
                                     LPARAM lparam) {
    switch (msg) {
      case WM_DEVICECHANGE:
        // Only arrival/removal matters; the many other DBT_* codes are
        // query/config chatter that does not change the camera list.
        if (wparam == DBT_DEVICEARRIVAL || wparam == DBT_DEVICEREMOVECOMPLETE) {
          DeviceEventPublisher::Instance().EmitVideoSourcesChanged();
        }
        return TRUE;
      case WM_DISPLAYCHANGE:
        DeviceEventPublisher::Instance().EmitDisplaysChanged();
        return 0;
      case WM_CLOSE:
        ::PostQuitMessage(0);
        return 0;
      default:
        break;
    }
    return ::DefWindowProcW(hwnd, msg, wparam, lparam);
  }

  mutable std::mutex mutex_;
  bool running_ = false;
  ComPtr<IMMDeviceEnumerator> enumerator_;
  EndpointNotificationClient notification_client_;
  HDEVNOTIFY device_notify_ = nullptr;
  HWND hwnd_ = nullptr;
  std::thread thread_;
};

DeviceChangeWatcher& DeviceChangeWatcher::Instance() {
  static DeviceChangeWatcher instance;
  return instance;
}

DeviceChangeWatcher::DeviceChangeWatcher() : impl_(std::make_unique<Impl>()) {}
DeviceChangeWatcher::~DeviceChangeWatcher() = default;

bool DeviceChangeWatcher::Start() { return impl_->Start(); }
void DeviceChangeWatcher::Stop() { impl_->Stop(); }
bool DeviceChangeWatcher::running() const { return impl_->running(); }

}  // namespace clingfy::bridge::devices
