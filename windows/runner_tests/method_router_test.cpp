#include "Bridge/method_router.h"

#include <gtest/gtest.h>

#include <flutter/method_result_functions.h>

#include <memory>
#include <stdexcept>
#include <string>
#include <variant>

#include "Bridge/native_error_codes.h"
#include "test_support.h"

namespace clingfy::bridge {
namespace {

using test_support::MakeCall;
using test_support::MakeRecorder;
using test_support::RecordedReply;

// ---- Phase 10.4 dispatch-barrier support ------------------------------------
//
// Counts every callback invocation (RecordedReply only records the latest),
// so the tests below can assert the result was resolved EXACTLY once.
struct CountedReply {
  int success_count = 0;
  int error_count = 0;
  int not_implemented_count = 0;
  flutter::EncodableValue success_value;
  std::string error_code;
  std::string error_message;
};

std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
MakeCountingRecorder(CountedReply& out) {
  return std::make_unique<
      flutter::MethodResultFunctions<flutter::EncodableValue>>(
      [&out](const flutter::EncodableValue* value) {
        ++out.success_count;
        if (value != nullptr) {
          out.success_value = *value;
        }
      },
      [&out](const std::string& code, const std::string& message,
             const flutter::EncodableValue* /*details*/) {
        ++out.error_count;
        out.error_code = code;
        out.error_message = message;
      },
      [&out]() { ++out.not_implemented_count; });
}

// Handlers must be plain function pointers (MethodHandler), so the throwing
// fixtures are free functions.
void ThrowingHandler(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
    /*result*/) {
  throw std::runtime_error("synthetic handler failure");
}

void ReplyThenThrowHandler(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  result->Success(flutter::EncodableValue(std::string("replied-before-throw")));
  throw std::runtime_error("boom after reply");
}

void ThrowNonStdHandler(
    const flutter::MethodCall<flutter::EncodableValue>& /*call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
    /*result*/) {
  throw 42;  // not derived from std::exception — exercises the catch (...)
}

TEST(MethodRouterTest, UnknownMethodFallsBackToWindowsNotImplemented) {
  MethodRouter router;
  RecordedReply reply;

  router.Dispatch(MakeCall("definitelyNotAMethod"), MakeRecorder(reply));

  EXPECT_FALSE(reply.success_called);
  EXPECT_TRUE(reply.error_called);
  EXPECT_EQ(reply.error_code, error::kWindowsNotImplemented);
  EXPECT_NE(reply.error_message.find("definitelyNotAMethod"),
            std::string::npos)
      << "Fallback error message should name the missing method so dev "
         "console logs make the drift obvious.";
}

TEST(MethodRouterTest, HasHandlerIsFalseForUnknownMethod) {
  MethodRouter router;
  EXPECT_FALSE(router.HasHandler("definitelyNotAMethod"));
}

TEST(MethodRouterTest, HasHandlerIsTrueForRegisteredMethod) {
  MethodRouter router;
  // `getDisplays` is registered by the devices router as part of Phase 1.
  EXPECT_TRUE(router.HasHandler("getDisplays"));
  EXPECT_TRUE(router.HasHandler("identifyDisplays"));
}

// ---- Phase 10.4: dispatch barrier ------------------------------------------

// A handler that throws before replying must NOT kill the process (the test
// completing at all proves that) and must resolve the Dart future with
// INTERNAL_ERROR — exactly once.
TEST(MethodRouterTest, DispatchBarrierConvertsHandlerThrowToInternalError) {
  MethodRouter router;
  router.RegisterHandlerForTesting("testThrowingMethod", &ThrowingHandler);

  CountedReply reply;
  router.Dispatch(MakeCall("testThrowingMethod"), MakeCountingRecorder(reply));

  EXPECT_EQ(reply.success_count, 0);
  EXPECT_EQ(reply.error_count, 1)
      << "the barrier must reply INTERNAL_ERROR exactly once for a handler "
         "that threw before replying";
  EXPECT_EQ(reply.error_code, error::kInternalError);
  EXPECT_NE(reply.error_message.find("testThrowingMethod"), std::string::npos)
      << "the INTERNAL_ERROR message should name the failing method";
  // NOTE: the exception's what() text is deliberately NOT asserted.
  // runner_bridge compiles with `_HAS_EXCEPTIONS=0` while this test target
  // uses default settings (GoogleTest needs exceptions), so the
  // `std::runtime_error` thrown HERE does not match runner_bridge's notion
  // of `std::exception` — the barrier's `catch (...)` arm fields it and
  // replies the generic (what()-less) message. Exceptions raised INSIDE
  // runner_bridge (one config) do carry what(); the cross-config case is an
  // artifact of the test arrangement, not a production gap.
}

// A handler that successfully replied and THEN threw keeps its original
// reply: no INTERNAL_ERROR on top, no double resolution.
TEST(MethodRouterTest, DispatchBarrierPreservesReplySentBeforeThrow) {
  MethodRouter router;
  router.RegisterHandlerForTesting("testReplyThenThrow",
                                   &ReplyThenThrowHandler);

  CountedReply reply;
  router.Dispatch(MakeCall("testReplyThenThrow"), MakeCountingRecorder(reply));

  EXPECT_EQ(reply.success_count, 1)
      << "the original reply must be delivered exactly once";
  EXPECT_EQ(reply.error_count, 0)
      << "the barrier must NOT layer an INTERNAL_ERROR over a reply the "
         "handler already sent";
  ASSERT_TRUE(std::holds_alternative<std::string>(reply.success_value));
  EXPECT_EQ(std::get<std::string>(reply.success_value),
            "replied-before-throw");
}

// Non-std exceptions (throw 42) take the catch (...) branch: still an
// INTERNAL_ERROR reply, still alive.
TEST(MethodRouterTest, DispatchBarrierHandlesNonStdException) {
  MethodRouter router;
  router.RegisterHandlerForTesting("testThrowNonStd", &ThrowNonStdHandler);

  CountedReply reply;
  router.Dispatch(MakeCall("testThrowNonStd"), MakeCountingRecorder(reply));

  EXPECT_EQ(reply.success_count, 0);
  EXPECT_EQ(reply.error_count, 1);
  EXPECT_EQ(reply.error_code, error::kInternalError);
  EXPECT_NE(reply.error_message.find("testThrowNonStd"), std::string::npos);
}

}  // namespace
}  // namespace clingfy::bridge
