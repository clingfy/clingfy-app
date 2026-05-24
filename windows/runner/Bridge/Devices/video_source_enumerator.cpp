#include "Bridge/Devices/video_source_enumerator.h"

#include <windows.h>
#include <combaseapi.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfobjects.h>

#include <atomic>
#include <mutex>
#include <string>

namespace clingfy::bridge::devices {

namespace {

std::string Utf8FromWide(LPCWSTR wide, UINT32 length) {
  if (wide == nullptr || length == 0) {
    return {};
  }
  const int needed =
      ::WideCharToMultiByte(CP_UTF8, 0, wide, static_cast<int>(length),
                            nullptr, 0, nullptr, nullptr);
  if (needed <= 0) {
    return {};
  }
  std::string out(static_cast<size_t>(needed), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, wide, static_cast<int>(length), out.data(),
                        needed, nullptr, nullptr);
  return out;
}

// `MFStartup` is called exactly once per process. `MFShutdown` is left to
// process teardown — the MF docs explicitly permit a single non-balanced
// startup, and balancing each enumeration would churn MF state every time
// the user opens the device picker.
void EnsureMediaFoundationStarted() {
  static std::once_flag flag;
  static std::atomic<bool> ok{false};
  std::call_once(flag, [] {
    const HRESULT hr = ::MFStartup(MF_VERSION, MFSTARTUP_LITE);
    ok.store(SUCCEEDED(hr));
  });
}

// Minimal scoped COM pointer — see audio_source_enumerator.cpp for the
// matching helper. Duplicated rather than shared because the two files have
// disjoint interface universes (WASAPI vs. MF) and a shared header would
// have to pull both header trees into every translation unit.
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

std::string ReadStringAttribute(IMFActivate& activate, REFGUID key) {
  UINT32 length = 0;
  WCHAR* raw = nullptr;
  if (FAILED(activate.GetAllocatedString(key, &raw, &length)) ||
      raw == nullptr) {
    return {};
  }
  std::string value = Utf8FromWide(raw, length);
  ::CoTaskMemFree(raw);
  return value;
}

}  // namespace

std::vector<VideoSourceRecord> EnumerateVideoInputs() {
  std::vector<VideoSourceRecord> sources;
  EnsureMediaFoundationStarted();

  ScopedCom<IMFAttributes> config;
  if (FAILED(::MFCreateAttributes(config.ReleaseAndGetAddressOf(), 1)) ||
      !config) {
    return sources;
  }
  if (FAILED(config->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
                             MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID))) {
    return sources;
  }

  IMFActivate** raw_devices = nullptr;
  UINT32 count = 0;
  const HRESULT hr =
      ::MFEnumDeviceSources(config.Get(), &raw_devices, &count);
  if (FAILED(hr) || raw_devices == nullptr) {
    return sources;
  }

  for (UINT32 i = 0; i < count; ++i) {
    IMFActivate* device = raw_devices[i];
    if (device == nullptr) {
      continue;
    }

    VideoSourceRecord record;
    record.id = ReadStringAttribute(
        *device, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK);
    record.name =
        ReadStringAttribute(*device, MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME);

    device->Release();

    if (record.id.empty()) {
      // Without a stable identifier the entry is useless to Phase 9, which
      // re-opens the device by symbolic link. Skip.
      continue;
    }
    if (record.name.empty()) {
      record.name = "Camera";
    }
    sources.push_back(std::move(record));
  }
  ::CoTaskMemFree(raw_devices);

  return sources;
}

}  // namespace clingfy::bridge::devices
