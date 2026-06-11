#ifndef RUNNER_SERVICES_RECOVERY_SWEEP_H_
#define RUNNER_SERVICES_RECOVERY_SWEEP_H_

#include <atomic>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <optional>
#include <string>
#include <vector>

// Phase 10.4 startup recovery sweep.
//
// A recording session leaves two kinds of artifacts when the process dies
// mid-flight:
//
//   1. A `.clingfyproj` bundle whose `project.json` still says
//      `status: "capturing"` (written provisionally at record start since
//      10.4). The sweep flips it to `status: "failed"` — macOS
//      `RecordingStore.markInterruptedProjectsAsFailed` parity.
//   2. Stranded `%TEMP%\clingfy_<sid>.{mp4,cursor.jsonl,camera.mp4}` files.
//      The MF sink writer produces NON-fragmented MP4, so a crash-stranded
//      video has no moov atom and is unplayable — salvage for these is
//      "clean up and tell the user", not media recovery (the fragmented-MP4
//      option is recorded as an open product call in docs/windows-port.md).
//
// SAFETY — dev + prod share both the recordings root and the `%TEMP%`
// namespace until Phase 10.5 splits installer identities, and pre-10.4
// builds write temp files with NO provisional manifest at all. Three
// guards keep the sweep from destroying recordings:
//   * A "capturing" bundle is only marked failed when its `ownerPid` is
//     not a live Clingfy process (unqueryable PIDs are treated as live —
//     fail safe). Our OWN pid also counts as LIVE: a capturing bundle
//     claiming it is either a recording that started while this sweep
//     walked the disk (the sweep runs on a worker thread), or a PID-reuse
//     leftover that the NEXT launch (different pid) sweeps normally.
//   * Bundles in any settled status (ready/failed/cancelled) PROTECT their
//     session's temp files: the engine deliberately keeps a finalized,
//     playable temp when bundling fails and stamps the bundle "failed" —
//     those temps are the only copy of the recording, never "strands".
//     Deleting the bundle (clearCachedRecordings) orphans the temps and
//     they age out on the following launch.
//   * An ownerless temp file is only deleted when its last write is older
//     than `min_temp_age` (a live recorder touches its files
//     continuously).
namespace clingfy::services {

struct InterruptedProject {
  std::string project_path;  // absolute path to the .clingfyproj bundle
  std::string session_id;    // manifest projectId (bundle name as fallback)
};

struct RecoverySweepResult {
  // Bundles flipped capturing/finalizing -> failed in THIS sweep. Bundles
  // that were already failed are not re-reported (no repeat notices).
  std::vector<InterruptedProject> interrupted;
  std::uint32_t cleaned_temp_files = 0;
  std::uint64_t cleaned_temp_bytes = 0;
};

struct RecoverySweepOptions {
  // Empty -> clingfy::capture::ResolveDefaultRecordingsRoot().
  std::string recordings_root;
  // Empty -> %TEMP% from the process environment.
  std::string temp_dir;
  // Injectable liveness probe: returns true when `pid` belongs to a LIVE
  // Clingfy process. Null -> the real Win32 probe (OpenProcess +
  // QueryFullProcessImageNameW image-name check; unqueryable -> live).
  std::function<bool(std::uint32_t)> pid_is_live_clingfy;
  // PID treated as "ourselves" (always dead for sweep purposes). 0 -> the
  // real GetCurrentProcessId(). Tests override.
  std::uint32_t current_pid = 0;
  // Temp files modified within this window are never deleted.
  std::chrono::seconds min_temp_age{300};
  // Injectable "now" for the temp-age check. Empty -> file clock now.
  std::optional<std::filesystem::file_time_type> now;
  // Optional cooperative-cancel flag, polled between filesystem entries.
  // The bridge handler's thread holder sets it at CRT static destruction
  // so a sweep in flight at process exit cannot touch dying singletons.
  const std::atomic<bool>* cancel = nullptr;
};

// Synchronous; walks the recordings root and %TEMP%. Callers off the
// platform thread please (the bridge handler runs it on a worker and
// marshals the reply).
RecoverySweepResult RunRecoverySweep(const RecoverySweepOptions& options);

// Pure helper, exposed for tests: replace the string VALUE of the FIRST
// `"<key>": "<value>"` pair in `json` (depth-blind — fine for the flat
// manifests this rides on). Returns std::nullopt when no such pair exists.
// Robust against lookalikes: backslash-escaped quotes inside values are
// honored, and a key-shaped string VALUE (e.g. `"displayName": "status"`)
// is skipped — the scan resumes until a real `key: "string"` pair is
// found.
std::optional<std::string> ReplaceJsonStringValue(const std::string& json,
                                                  const std::string& key,
                                                  const std::string& value);

// Phase 10.4: true when `bundle_path/project.json` says capturing/
// finalizing AND its ownerPid is a live Clingfy process other than
// `self_pid` (0 → the real current pid). clearCachedRecordings uses this to
// avoid deleting a SIBLING instance's in-flight recording — dev + prod
// share the recordings root until Phase 10.5 splits installer identities.
// `pid_is_live_clingfy` is injectable for tests (null → real probe).
bool BundleOwnedByLiveProcess(
    const std::filesystem::path& bundle_path, std::uint32_t self_pid = 0,
    const std::function<bool(std::uint32_t)>& pid_is_live_clingfy = nullptr);

}  // namespace clingfy::services

#endif  // RUNNER_SERVICES_RECOVERY_SWEEP_H_
