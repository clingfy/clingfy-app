#include "Services/temp_orphan_scan.h"

#include <windows.h>

#include <cstdio>
#include <filesystem>
#include <system_error>
#include <thread>

#include "Bridge/Devices/device_probe_log.h"
#include "Bridge/native_log_publisher.h"
#include "Services/log_locations.h"

namespace clingfy::storage {

namespace fs = std::filesystem;

TempOrphanScanResult ScanClingfyTempOrphans(
    const std::wstring& temp_dir,
    const std::function<bool()>& should_cancel) {
  TempOrphanScanResult result;
  if (temp_dir.empty()) {
    return result;
  }
  std::error_code ec;
  fs::directory_iterator it(fs::path(temp_dir), ec);
  if (ec) {
    return result;
  }
  for (const auto& entry : it) {
    if (should_cancel && should_cancel()) {
      return result;
    }
    std::error_code entry_ec;
    if (!entry.is_regular_file(entry_ec)) {
      continue;
    }
    const std::wstring name = entry.path().filename().wstring();
    if (name.rfind(L"clingfy_", 0) != 0) {
      continue;
    }
    ++result.file_count;
    const auto size = entry.file_size(entry_ec);
    if (!entry_ec) {
      result.total_bytes += static_cast<std::uint64_t>(size);
    }
  }
  return result;
}

namespace {

// Owns the scan thread for the process lifetime. A plain .detach() raced
// CRT static destruction at fast app exit: the worker's tail touches
// function-local statics (NativeLogsDirectory's cached wstring, the
// NativeLogPublisher singleton) that the UCRT destroys before ExitProcess
// kills stray threads — open-then-close-within-seconds could read freed
// memory. The holder is a function-local static constructed AFTER those
// statics are force-initialized, so reverse destruction order joins the
// worker (with a cancel flag so a pathological %TEMP% walk can't stall
// exit) while everything it uses is still alive.
struct ScanThreadHolder {
  std::atomic<bool> cancel{false};
  std::thread thread;
  ~ScanThreadHolder() {
    cancel.store(true);
    if (thread.joinable()) {
      thread.join();
    }
  }
};

}  // namespace

void StartTempOrphanScanAsync() {
  // Force-initialize every static the worker touches BEFORE the holder is
  // constructed (see ScanThreadHolder).
  (void)NativeLogsDirectory();
  (void)clingfy::bridge::NativeLogPublisher::Instance();
  static ScanThreadHolder holder;
  if (holder.thread.joinable()) {
    return;  // already started this process
  }
  holder.thread = std::thread([] {
    wchar_t buf[MAX_PATH + 1] = {};
    const DWORD len = ::GetTempPathW(MAX_PATH + 1, buf);
    if (len == 0 || len > MAX_PATH) {
      return;
    }
    const TempOrphanScanResult result = ScanClingfyTempOrphans(
        std::wstring(buf, len), [] { return holder.cancel.load(); });
    if (holder.cancel.load()) {
      return;  // shutting down — skip the (now pointless) report
    }
    char line[256];
    std::snprintf(line, sizeof(line),
                  "TempOrphanScan: %d stranded clingfy_* temp file(s), "
                  "%llu bytes",
                  result.file_count,
                  static_cast<unsigned long long>(result.total_bytes));
    clingfy::bridge::devices::LogDeviceProbe(line);
    if (result.file_count > 0) {
      // A strand means a previous session ended without a clean Stop —
      // exactly the breadcrumb a "my recording disappeared" beta ticket
      // needs. WARNING so it lands as a Sentry breadcrumb, not an event.
      clingfy::bridge::NativeLogPublisher::Instance().Warn("Recording", line);
    }
  });
}

}  // namespace clingfy::storage
