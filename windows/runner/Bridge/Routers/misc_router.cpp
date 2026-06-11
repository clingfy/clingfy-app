#include "Bridge/Routers/misc_router.h"

#include <windows.h>

#include <optional>
#include <string>

#include "Bridge/native_log_publisher.h"
#include "Bridge/result_helpers.h"

namespace clingfy::bridge::routers::misc {

namespace {

void HandleNull(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::Null(*result);
}

void HandleFalse(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  reply::Bool(*result, false);
}

// Raw `CLINGFY_CRASH_TEST` value: `nullopt` when the variable is unset, the
// (possibly empty) string otherwise. Mirrors the `ReadEnv` helpers in
// Services/log_locations.cpp / Services/save_folder.cpp.
std::optional<std::wstring> ReadCrashTestEnv() {
  const DWORD needed =
      ::GetEnvironmentVariableW(L"CLINGFY_CRASH_TEST", nullptr, 0);
  if (needed == 0) {
    return std::nullopt;  // Not set.
  }
  if (needed == 1) {
    return std::wstring{};  // Set but empty (just the null terminator).
  }
  std::wstring value(needed, L'\0');
  const DWORD written =
      ::GetEnvironmentVariableW(L"CLINGFY_CRASH_TEST", value.data(), needed);
  if (written == 0 || written >= needed) {
    return std::nullopt;
  }
  value.resize(written);
  return value;
}

// Phase 10.4 crash-pipeline trigger. A hidden dev button on the Dart side
// invokes this to verify that a forced native crash in a staged Release copy
// shows up in Sentry fully symbolicated. Outside of that drill (no
// `CLINGFY_CRASH_TEST=1` in the process environment) it is inert and replies
// with a structured error.
void HandleDebugForceNativeCrash(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (!CrashTestEnabled(ReadCrashTestEnv())) {
    result->Error(error::kWindowsNotImplemented,
                  "Crash test is not enabled in this build/environment.");
    return;
  }

  NativeLogPublisher::Instance().Error(
      "Diagnostics",
      "debugForceNativeCrash invoked -- crashing deliberately for "
      "crash-pipeline verification");

  // Crash via a plain access violation rather than abort() / __fastfail():
  // an AV raises a standard SEH exception that flows through the process's
  // unhandled-exception filter -- exactly the hook the crash reporter
  // (crashpad / sentry-native) installs -- so this drill exercises the same
  // capture path a real wild-pointer crash would. __fastfail (and the
  // __fastfail-backed abort() handler) terminates the process immediately
  // WITHOUT invoking the unhandled-exception filter, which would make the
  // trigger useless for verifying the pipeline. The write goes through a
  // `volatile` pointer so the optimizer cannot elide it in Release.
  //
  // NOTE: `result` is intentionally never resolved on this path -- the
  // process dies on the next statement, so there is no Dart future left to
  // answer. Do not "fix" this by adding a reply before the crash.
  volatile int* forced_access_violation = nullptr;
  *forced_access_violation = 0x104;  // 10.4 -- never executes past here.
}

}  // namespace

void RegisterHandlers(HandlerTable& table) {
  table["pickImage"] = &HandleNull;
  table["cacheLocalizedStrings"] = &HandleNull;
  table["checkForUpdates"] = &HandleFalse;
  table["debugForceNativeCrash"] = &HandleDebugForceNativeCrash;
}

}  // namespace clingfy::bridge::routers::misc
