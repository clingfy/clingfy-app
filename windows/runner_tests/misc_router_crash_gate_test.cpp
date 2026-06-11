#include "Bridge/Routers/misc_router.h"

#include <windows.h>

#include <gtest/gtest.h>

#include <flutter/encodable_value.h>
#include <flutter/method_result_functions.h>

#include <memory>
#include <optional>
#include <string>

#include "Bridge/method_router.h"
#include "Bridge/native_error_codes.h"
#include "test_support.h"

namespace clingfy::bridge {
namespace {

using routers::misc::CrashTestEnabled;
using test_support::MakeCall;

// === The pure gate decision ================================================
//
// `debugForceNativeCrash` (Phase 10.4) must be inert everywhere except a
// deliberate crash-pipeline drill where the operator exports
// CLINGFY_CRASH_TEST=1. The decision is a pure function over the raw
// environment value so this table needs no env mutation.

TEST(MiscRouterCrashGateTest, CrashTestEnabledDecisionTable) {
  // Unset variable -> disabled.
  EXPECT_FALSE(CrashTestEnabled(std::nullopt));
  // Set but empty -> disabled.
  EXPECT_FALSE(CrashTestEnabled(std::wstring(L"")));
  // Explicit off -> disabled.
  EXPECT_FALSE(CrashTestEnabled(std::wstring(L"0")));
  // Only the exact literal "1" enables the trigger.
  EXPECT_TRUE(CrashTestEnabled(std::wstring(L"1")));
  // Truthy-looking strings do NOT enable it -- the gate is deliberately
  // strict so a stray CLINGFY_CRASH_TEST=true never arms a crash.
  EXPECT_FALSE(CrashTestEnabled(std::wstring(L"true")));
}

// === The disabled-path handler behavior ====================================
//
// The enabled path is intentionally NOT tested: it kills the process by
// design (that is the whole point of the method). These tests pin that the
// method is registered, that the disabled gate replies with the structured
// WINDOWS_NOT_IMPLEMENTED error, and that the MethodResult is consumed
// exactly once.

// Counting recorder: `test_support::RecordedReply` only records booleans, so
// a double-reply would be invisible there. This drill's contract is "replies
// exactly once on the disabled path", so count every callback invocation.
struct CountingReply {
  int success_count = 0;
  int error_count = 0;
  int not_implemented_count = 0;
  std::string error_code;
  std::string error_message;
};

std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
MakeCountingRecorder(CountingReply& out) {
  return std::make_unique<
      flutter::MethodResultFunctions<flutter::EncodableValue>>(
      [&out](const flutter::EncodableValue* /*value*/) {
        ++out.success_count;
      },
      [&out](const std::string& code, const std::string& message,
             const flutter::EncodableValue* /*details*/) {
        ++out.error_count;
        out.error_code = code;
        out.error_message = message;
      },
      [&out]() { ++out.not_implemented_count; });
}

CountingReply DispatchDebugForceNativeCrash() {
  MethodRouter router;
  CountingReply reply;
  router.Dispatch(MakeCall("debugForceNativeCrash"),
                  MakeCountingRecorder(reply));
  return reply;
}

TEST(MiscRouterCrashGateTest, DebugForceNativeCrashDisabledWhenEnvUnset) {
  // Make the gate state deterministic regardless of the host environment.
  ::SetEnvironmentVariableW(L"CLINGFY_CRASH_TEST", nullptr);

  const CountingReply reply = DispatchDebugForceNativeCrash();

  EXPECT_EQ(reply.error_count, 1)
      << "Disabled gate must reply with exactly one Error.";
  EXPECT_EQ(reply.success_count, 0);
  EXPECT_EQ(reply.not_implemented_count, 0);
  EXPECT_EQ(reply.error_code, error::kWindowsNotImplemented);
  // The handler-specific message also proves the method is REGISTERED in
  // misc_router -- an unregistered method would fall through to the router's
  // generic "Method '...' is not implemented on Windows yet." fallback with
  // the same error code.
  EXPECT_EQ(reply.error_message,
            "Crash test is not enabled in this build/environment.");
}

TEST(MiscRouterCrashGateTest, DebugForceNativeCrashDisabledWhenEnvZero) {
  // Exercises the real GetEnvironmentVariableW read path (set-but-disabled)
  // rather than the pure helper alone.
  ::SetEnvironmentVariableW(L"CLINGFY_CRASH_TEST", L"0");

  const CountingReply reply = DispatchDebugForceNativeCrash();

  ::SetEnvironmentVariableW(L"CLINGFY_CRASH_TEST", nullptr);

  EXPECT_EQ(reply.error_count, 1);
  EXPECT_EQ(reply.success_count, 0);
  EXPECT_EQ(reply.not_implemented_count, 0);
  EXPECT_EQ(reply.error_code, error::kWindowsNotImplemented);
  EXPECT_EQ(reply.error_message,
            "Crash test is not enabled in this build/environment.");
}

}  // namespace
}  // namespace clingfy::bridge
