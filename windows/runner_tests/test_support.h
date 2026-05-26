#ifndef RUNNER_TESTS_TEST_SUPPORT_H_
#define RUNNER_TESTS_TEST_SUPPORT_H_

#include <flutter/encodable_value.h>
#include <flutter/method_call.h>
#include <flutter/method_result.h>
#include <flutter/method_result_functions.h>

#include <memory>
#include <string>

namespace clingfy::bridge::test_support {

// Captures everything a Phase 1 handler can do with the `MethodResult` it is
// given: success (with the optional reply value), error (with code +
// message), or not-implemented.
//
// The `MethodResult<EncodableValue>` returned by `MakeRecorder` writes into
// the `RecordedReply` by reference, so the caller can inspect the result
// after the synchronous handler returns even though the result-unique_ptr
// itself has been moved into the handler and destroyed.
struct RecordedReply {
  bool success_called = false;
  bool error_called = false;
  bool not_implemented_called = false;
  flutter::EncodableValue success_value;
  std::string error_code;
  std::string error_message;
  // The `details` payload passed alongside an Error reply. Populated
  // when the handler called the 3-arg Error overload; left default-
  // constructed (kNull) otherwise. Useful for verifying contract-
  // facing fields like the projectPath echo macOS includes alongside
  // SCENE_INPUT_MISSING.
  flutter::EncodableValue error_details;
};

inline std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
MakeRecorder(RecordedReply& out) {
  return std::make_unique<
      flutter::MethodResultFunctions<flutter::EncodableValue>>(
      [&out](const flutter::EncodableValue* value) {
        out.success_called = true;
        if (value != nullptr) {
          out.success_value = *value;
        }
      },
      [&out](const std::string& code,
             const std::string& message,
             const flutter::EncodableValue* details) {
        out.error_called = true;
        out.error_code = code;
        out.error_message = message;
        if (details != nullptr) {
          out.error_details = *details;
        }
      },
      [&out]() { out.not_implemented_called = true; });
}

// Build a `MethodCall` with no arguments (the common case for Phase 1
// getters and fire-and-forget setters).
inline flutter::MethodCall<flutter::EncodableValue> MakeCall(
    const std::string& method) {
  return flutter::MethodCall<flutter::EncodableValue>(
      method, std::make_unique<flutter::EncodableValue>());
}

// Build a `MethodCall` carrying an EncodableMap argument payload.
inline flutter::MethodCall<flutter::EncodableValue> MakeCallWithArgs(
    const std::string& method,
    flutter::EncodableMap args) {
  return flutter::MethodCall<flutter::EncodableValue>(
      method,
      std::make_unique<flutter::EncodableValue>(std::move(args)));
}

}  // namespace clingfy::bridge::test_support

#endif  // RUNNER_TESTS_TEST_SUPPORT_H_
