#include "Bridge/method_router.h"

#include <gtest/gtest.h>

#include "Bridge/native_error_codes.h"
#include "test_support.h"

namespace clingfy::bridge {
namespace {

using test_support::MakeCall;
using test_support::MakeRecorder;
using test_support::RecordedReply;

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
}

}  // namespace
}  // namespace clingfy::bridge
