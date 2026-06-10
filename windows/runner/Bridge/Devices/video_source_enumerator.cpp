#include "Bridge/Devices/video_source_enumerator.h"

#include <windows.h>
#include <combaseapi.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfobjects.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <mutex>
#include <string>
#include <thread>

// Phase 10.1: the duplicated private LogDeviceProbe copy is gone — both
// enumerators now share Bridge/Devices/device_probe_log.h, which also owns
// the %LOCALAPPDATA% relocation. (The old duplication hid a path change
// exactly like this one.)
#include "Bridge/Devices/device_probe_log.h"

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

// The actual Media Foundation enumeration. MUST run on an MTA thread (see
// EnumerateVideoInputs). Appends discovered cameras to `sources`.
void EnumerateVideoInputsMf(std::vector<VideoSourceRecord>& sources) {
  ScopedCom<IMFAttributes> config;
  if (FAILED(::MFCreateAttributes(config.ReleaseAndGetAddressOf(), 1)) ||
      !config) {
    LogDeviceProbe("EnumerateVideoInputs: MFCreateAttributes failed");
    return;
  }
  if (FAILED(config->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
                             MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID))) {
    LogDeviceProbe("EnumerateVideoInputs: SetGUID(VIDCAP) failed");
    return;
  }

  IMFActivate** raw_devices = nullptr;
  UINT32 count = 0;
  const HRESULT hr =
      ::MFEnumDeviceSources(config.Get(), &raw_devices, &count);
  if (FAILED(hr)) {
    char buf[160];
    std::snprintf(buf, sizeof(buf),
                  "EnumerateVideoInputs: MFEnumDeviceSources FAILED hr=0x%08X",
                  static_cast<unsigned>(hr));
    LogDeviceProbe(buf);
    return;
  }
  if (raw_devices == nullptr || count == 0) {
    // S_OK with zero devices — NOT an error. The Camera Frame Server reported
    // no camera on this attempt: the device may be disabled, in use by another
    // app, blocked by privacy, or the Frame Server is still cold-starting. The
    // caller retries a few times to ride out the cold-start race.
    char buf[200];
    std::snprintf(
        buf, sizeof(buf),
        "EnumerateVideoInputs: 0 cameras (hr=0x%08X count=%u) — none "
        "enumerated this attempt (disabled / in-use / privacy / cold-start)",
        static_cast<unsigned>(hr), count);
    LogDeviceProbe(buf);
    if (raw_devices != nullptr) {
      ::CoTaskMemFree(raw_devices);
    }
    return;
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
      // re-opens the device by symbolic link. Skip — but log it, because a
      // camera the user sees in Windows but that has no symbolic link is a
      // distinct failure mode worth spotting.
      char skip[160];
      std::snprintf(skip, sizeof(skip),
                    "EnumerateVideoInputs: #%u skipped (no symbolic link)", i);
      LogDeviceProbe(skip);
      continue;
    }
    if (record.name.empty()) {
      record.name = "Camera";
    }
    char buf[256];
    std::snprintf(buf, sizeof(buf), "EnumerateVideoInputs: #%u name=%s", i,
                  record.name.c_str());
    LogDeviceProbe(buf);
    sources.push_back(std::move(record));
  }
  ::CoTaskMemFree(raw_devices);

  char summary[160];
  std::snprintf(summary, sizeof(summary),
                "EnumerateVideoInputs: MF reported %u device(s); returning %zu",
                count, sources.size());
  LogDeviceProbe(summary);
}

}  // namespace

std::vector<VideoSourceRecord> EnumerateVideoInputs(int max_attempts) {
  EnsureMediaFoundationStarted();
  std::vector<VideoSourceRecord> sources;

  // Run the enumeration on a dedicated MTA thread. MFEnumDeviceSources resolves
  // cameras through the Windows Camera Frame Server, which marshals unreliably
  // when called from the Flutter platform thread (an STA apartment) and
  // intermittently returns S_OK with zero devices even when a camera exists.
  // An MTA apartment — the same apartment the camera capture thread uses —
  // makes it reliable. We also retry a few times to ride out a Frame Server
  // cold-start (the device can take a beat to appear after the service spins
  // up). This matches the audio enumerator's reliability without forcing the
  // platform thread into MTA.
  std::thread worker([&sources, max_attempts]() {
    const HRESULT co = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    LogDeviceProbe("EnumerateVideoInputs: begin (MTA worker)");
    const int attempts_budget = max_attempts < 1 ? 1 : max_attempts;
    for (int attempt = 0; attempt < attempts_budget; ++attempt) {
      sources.clear();
      EnumerateVideoInputsMf(sources);
      if (!sources.empty()) {
        break;
      }
      if (attempt + 1 < attempts_budget) {
        LogDeviceProbe(
            "EnumerateVideoInputs: 0 cameras, retrying after 200ms");
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
      }
    }
    if (SUCCEEDED(co)) {
      ::CoUninitialize();
    }
  });
  worker.join();
  return sources;
}

}  // namespace clingfy::bridge::devices
