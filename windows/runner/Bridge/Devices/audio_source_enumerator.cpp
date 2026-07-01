#include "Bridge/Devices/audio_source_enumerator.h"

#include <windows.h>
#include <combaseapi.h>
#include <mmdeviceapi.h>
#include <propsys.h>
#include <propvarutil.h>

#include <cstdio>
#include <string>

#include "Bridge/Devices/device_probe_log.h"

namespace clingfy::bridge::devices {

namespace {

// PROPERTYKEYs we need for friendly-name resolution. We do NOT include
// `<functiondiscoverykeys_devpkey.h>` — that header lacks include guards and
// collides with `<propsys.h>`'s transitive inclusion on recent Windows SDKs,
// producing a wall of `DEFINE_PROPERTYKEY` redefinition errors. Declaring
// the two keys locally with their published GUIDs is the standard workaround.
const PROPERTYKEY kPkeyDeviceFriendlyName = {
    {0xa45c254e, 0xdf1c, 0x4efd,
     {0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0}},
    14};
const PROPERTYKEY kPkeyDeviceInterfaceFriendlyName = {
    {0x026e516e, 0xb814, 0x414b,
     {0x83, 0xcd, 0x85, 0x6d, 0x6f, 0xef, 0x48, 0x22}},
    2};

std::string Utf8FromWide(LPCWSTR wide) {
  if (wide == nullptr || *wide == L'\0') {
    return {};
  }
  const int needed = ::WideCharToMultiByte(CP_UTF8, 0, wide, -1, nullptr, 0,
                                            nullptr, nullptr);
  if (needed <= 1) {
    return {};
  }
  std::string out(static_cast<size_t>(needed - 1), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, wide, -1, out.data(), needed, nullptr,
                        nullptr);
  return out;
}

// RAII wrapper that initializes COM on the calling thread if it has not
// already been initialized and balances the call in the destructor. The
// `RPC_E_CHANGED_MODE` case (COM already initialized in another mode) is
// treated as success — Flutter's host thread already initialized COM in
// APARTMENTTHREADED, so on the typical call path we simply re-use that.
class ScopedComInit {
 public:
  ScopedComInit() {
    const HRESULT hr = ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    owns_ = SUCCEEDED(hr);
    // S_FALSE means COM was already initialized; we did not "own" the init.
    if (hr == S_FALSE || hr == RPC_E_CHANGED_MODE) {
      owns_ = false;
    }
  }
  ~ScopedComInit() {
    if (owns_) {
      ::CoUninitialize();
    }
  }
  ScopedComInit(const ScopedComInit&) = delete;
  ScopedComInit& operator=(const ScopedComInit&) = delete;

 private:
  bool owns_ = false;
};

// Minimal scoped COM pointer — avoids pulling in <wrl/client.h> from the
// rest of the project. Calls Release() on destruction; does not implement
// the full ComPtr API because we only need single-ownership here.
template <typename T>
class ScopedCom {
 public:
  ScopedCom() = default;
  ~ScopedCom() { Reset(); }
  ScopedCom(const ScopedCom&) = delete;
  ScopedCom& operator=(const ScopedCom&) = delete;

  T** ReleaseAndGetAddressOf() {
    Reset();
    return &ptr_;
  }
  T* Get() const { return ptr_; }
  T* operator->() const { return ptr_; }
  explicit operator bool() const { return ptr_ != nullptr; }

  void Reset() {
    if (ptr_ != nullptr) {
      ptr_->Release();
      ptr_ = nullptr;
    }
  }

 private:
  T* ptr_ = nullptr;
};

// Read PKEY_Device_FriendlyName from a device's property store, falling back
// to PKEY_DeviceInterface_FriendlyName if the primary key is missing.
std::string ReadFriendlyName(IMMDevice& device) {
  ScopedCom<IPropertyStore> store;
  if (FAILED(device.OpenPropertyStore(STGM_READ,
                                      store.ReleaseAndGetAddressOf()))) {
    return {};
  }

  static const PROPERTYKEY kKeys[] = {
      kPkeyDeviceFriendlyName,
      kPkeyDeviceInterfaceFriendlyName,
  };

  for (const auto& key : kKeys) {
    PROPVARIANT value{};
    ::PropVariantInit(&value);
    const HRESULT hr = store->GetValue(key, &value);
    std::string name;
    if (SUCCEEDED(hr) && value.vt == VT_LPWSTR && value.pwszVal != nullptr) {
      name = Utf8FromWide(value.pwszVal);
    }
    ::PropVariantClear(&value);
    if (!name.empty()) {
      return name;
    }
  }
  return {};
}

}  // namespace

std::vector<AudioSourceRecord> EnumerateAudioInputs() {
  std::vector<AudioSourceRecord> sources;
  ScopedComInit com_init;

  ScopedCom<IMMDeviceEnumerator> enumerator;
  HRESULT hr = ::CoCreateInstance(
      __uuidof(MMDeviceEnumerator), nullptr, CLSCTX_INPROC_SERVER,
      __uuidof(IMMDeviceEnumerator),
      reinterpret_cast<void**>(enumerator.ReleaseAndGetAddressOf()));
  if (FAILED(hr) || !enumerator) {
    char buf[160];
    std::snprintf(buf, sizeof(buf),
                  "EnumerateAudioInputs: CoCreateInstance(MMDeviceEnumerator) "
                  "failed hr=0x%08X — no mics enumerable",
                  hr);
    LogDeviceProbe(buf);
    return sources;
  }

  // Two-pass enumeration. First try ACTIVE-only — this is what every
  // user with a normal Windows audio setup expects to see in the
  // microphone dropdown. If that pass returns zero devices, widen to
  // ACTIVE|UNPLUGGED so the Realtek edge case (mic array stuck in
  // UNPLUGGED state until the first WASAPI activation) still surfaces
  // *something* the user can pick. PR #121 originally widened
  // unconditionally to fix that Realtek case; the side effect was that
  // a physically-empty 3.5 mm jack also showed up first in the dropdown
  // and selecting it silently recorded 6+ seconds of -91 dB samples.
  // Narrowing the default keeps both shapes working.
  //
  // macOS has no equivalent — AVFoundation device enumeration is
  // single-state and never reports unplugged endpoints.
  ScopedCom<IMMDeviceCollection> collection;
  hr = enumerator->EnumAudioEndpoints(
      eCapture, DEVICE_STATE_ACTIVE, collection.ReleaseAndGetAddressOf());
  if (FAILED(hr) || !collection) {
    char buf[200];
    std::snprintf(buf, sizeof(buf),
                  "EnumerateAudioInputs: EnumAudioEndpoints(eCapture, "
                  "ACTIVE) failed hr=0x%08X — trying ACTIVE|UNPLUGGED",
                  hr);
    LogDeviceProbe(buf);
  }

  UINT count = 0;
  if (collection && SUCCEEDED(collection->GetCount(&count)) && count == 0) {
    LogDeviceProbe(
        "EnumerateAudioInputs: zero ACTIVE endpoints — widening to "
        "ACTIVE|UNPLUGGED for the Realtek-stuck edge case");
    collection.Reset();
  }

  if (!collection) {
    hr = enumerator->EnumAudioEndpoints(
        eCapture, DEVICE_STATE_ACTIVE | DEVICE_STATE_UNPLUGGED,
        collection.ReleaseAndGetAddressOf());
    if (FAILED(hr) || !collection) {
      char buf[200];
      std::snprintf(buf, sizeof(buf),
                    "EnumerateAudioInputs: EnumAudioEndpoints(eCapture, "
                    "ACTIVE|UNPLUGGED) failed hr=0x%08X",
                    hr);
      LogDeviceProbe(buf);
      return sources;
    }
  }

  count = 0;
  if (FAILED(collection->GetCount(&count))) {
    LogDeviceProbe(
        "EnumerateAudioInputs: collection->GetCount failed — returning empty");
    return sources;
  }

  for (UINT i = 0; i < count; ++i) {
    ScopedCom<IMMDevice> device;
    if (FAILED(collection->Item(i, device.ReleaseAndGetAddressOf())) ||
        !device) {
      continue;
    }

    DWORD state = 0;
    device->GetState(&state);

    LPWSTR raw_id = nullptr;
    if (FAILED(device->GetId(&raw_id)) || raw_id == nullptr) {
      continue;
    }
    std::string id = Utf8FromWide(raw_id);
    ::CoTaskMemFree(raw_id);
    if (id.empty()) {
      continue;
    }

    AudioSourceRecord record;
    record.id = std::move(id);
    record.name = ReadFriendlyName(*device.Get());
    if (record.name.empty()) {
      record.name = "Microphone";
    }
    char buf[256];
    std::snprintf(buf, sizeof(buf),
                  "EnumerateAudioInputs: #%u state=0x%08lX name=%s",
                  i, state, record.name.c_str());
    LogDeviceProbe(buf);
    sources.push_back(std::move(record));
  }

  char summary[160];
  std::snprintf(summary, sizeof(summary),
                "EnumerateAudioInputs: returning %zu source(s)",
                sources.size());
  LogDeviceProbe(summary);

  return sources;
}

}  // namespace clingfy::bridge::devices
