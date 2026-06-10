#ifndef RUNNER_SERVICES_TEMP_ORPHAN_SCAN_H_
#define RUNNER_SERVICES_TEMP_ORPHAN_SCAN_H_

#include <cstdint>
#include <functional>
#include <string>

namespace clingfy::storage {

// Phase 10.1: crash-mid-recording surfacing.
//
// In-flight recordings live as `%TEMP%\clingfy_<sessionId>.*` (video, cursor
// sidecar, camera raw) and are bundled into the project on Stop. A crash or
// kill mid-record strands them there with zero signal — the user thinks the
// recording vanished. This scan DETECTS and reports strands at startup; it
// deletes nothing (salvage/recovery is the Phase 10.4 slice).

struct TempOrphanScanResult {
  int file_count = 0;
  std::uint64_t total_bytes = 0;
};

// Count `clingfy_*` files in `temp_dir` and sum their sizes. Pure given the
// directory — unit-testable against a fixture dir. Missing/unreadable dir →
// zero result. `should_cancel` (optional) is polled per entry so a shutdown
// can abandon a pathological %TEMP% walk; a cancelled scan returns the
// partial tally.
TempOrphanScanResult ScanClingfyTempOrphans(
    const std::wstring& temp_dir,
    const std::function<bool()>& should_cancel = {});

// Fire-and-forget startup sweep: scans %TEMP% on a short-lived background
// thread (off the startup path) and reports findings to the device-probe
// log + the native→Dart log bridge (WARNING when strands exist). Detection
// only.
void StartTempOrphanScanAsync();

}  // namespace clingfy::storage

#endif  // RUNNER_SERVICES_TEMP_ORPHAN_SCAN_H_
