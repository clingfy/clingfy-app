#include "Capture/Export/export_session.h"

#include <gtest/gtest.h>

namespace clingfy::capture::export_ {
namespace {

// ExportSession is a process singleton shared with the real export router; each
// test resets it so order doesn't matter.

TEST(ExportSessionTest, BeginClaimsAndClearsStaleCancel) {
  auto& s = ExportSession::Instance();
  s.ResetForTesting();
  s.RequestCancel();
  EXPECT_TRUE(s.IsCancelled());

  EXPECT_TRUE(s.BeginExport());
  EXPECT_TRUE(s.IsRunning());
  EXPECT_FALSE(s.IsCancelled());  // BeginExport clears a stale cancel flag

  s.EndExport();
  EXPECT_FALSE(s.IsRunning());
  s.ResetForTesting();
}

TEST(ExportSessionTest, SecondBeginWhileRunningIsRejected) {
  auto& s = ExportSession::Instance();
  s.ResetForTesting();
  EXPECT_TRUE(s.BeginExport());
  EXPECT_FALSE(s.BeginExport());  // already running -> reject
  s.EndExport();
  EXPECT_TRUE(s.BeginExport());  // free again
  s.EndExport();
  s.ResetForTesting();
}

TEST(ExportSessionTest, RequestCancelFlagsTheRunningExport) {
  auto& s = ExportSession::Instance();
  s.ResetForTesting();
  EXPECT_TRUE(s.BeginExport());
  EXPECT_FALSE(s.IsCancelled());
  s.RequestCancel();
  EXPECT_TRUE(s.IsCancelled());
  s.EndExport();
  s.ResetForTesting();
}

TEST(ExportSessionTest, CancelDoesNotCorruptTheNextExport) {
  // A cancelled export must not leave the next export pre-cancelled.
  auto& s = ExportSession::Instance();
  s.ResetForTesting();
  EXPECT_TRUE(s.BeginExport());
  s.RequestCancel();
  s.EndExport();

  EXPECT_TRUE(s.BeginExport());
  EXPECT_FALSE(s.IsCancelled());  // fresh export starts uncancelled
  s.EndExport();
  s.ResetForTesting();
}

}  // namespace
}  // namespace clingfy::capture::export_
