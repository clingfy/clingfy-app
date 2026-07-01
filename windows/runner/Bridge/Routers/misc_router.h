#ifndef RUNNER_BRIDGE_ROUTERS_MISC_ROUTER_H_
#define RUNNER_BRIDGE_ROUTERS_MISC_ROUTER_H_

#include <optional>
#include <string>

#include "Bridge/method_router.h"

namespace clingfy::bridge::routers::misc {

// `pickImage`, `cacheLocalizedStrings`, `checkForUpdates`,
// `debugForceNativeCrash`.
//
// Phase 1:
//   - `pickImage` returns null (treated as "user cancelled" by Dart). A real
//     IFileDialog implementation lands in Phase 6 alongside background-image
//     export support.
//   - `cacheLocalizedStrings` is no-op success. Native code does not need the
//     localized strings until it draws UI of its own.
//   - `checkForUpdates` returns `false`. WinSparkle wires in during Phase 10.
//
// Phase 10.4:
//   - `debugForceNativeCrash` deliberately crashes the process so the crash
//     pipeline (unhandled-exception capture -> minidump -> Sentry, then
//     symbolication against the Release PDBs uploaded by
//     ops/release/windows/upload_symbols.ps1) can be verified end to end.
//     Gated behind `CLINGFY_CRASH_TEST=1`; when disabled it replies with a
//     WINDOWS_NOT_IMPLEMENTED error instead of crashing.
void RegisterHandlers(HandlerTable& table);

// Pure gate decision for `debugForceNativeCrash`: the crash trigger is
// enabled only when the `CLINGFY_CRASH_TEST` process environment variable is
// exactly "1". Takes the raw environment value (`nullopt` = variable unset)
// instead of reading the environment itself so tests can pin the decision
// table without mutating process state.
inline bool CrashTestEnabled(const std::optional<std::wstring>& env_value) {
  return env_value.has_value() && *env_value == L"1";
}

}  // namespace clingfy::bridge::routers::misc

#endif  // RUNNER_BRIDGE_ROUTERS_MISC_ROUTER_H_
