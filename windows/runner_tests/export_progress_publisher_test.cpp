#include "Bridge/export_progress_publisher.h"

#include <gtest/gtest.h>

namespace clingfy::bridge {
namespace {

// The publisher borrows a method channel that the FlutterWindow clears on
// teardown. EmitProgress must be a safe no-op when no channel is attached
// (the export worker can outlive teardown) — this is the guard that keeps a
// late progress tick from dereferencing a freed channel. No messenger is
// available in unit tests, so this also covers the "no listener" path.

TEST(ExportProgressPublisherTest, EmitWithNoChannelIsANoOp) {
  auto& pub = ExportProgressPublisher::Instance();
  pub.ClearChannel();
  // Must not crash / dereference a null channel.
  pub.EmitProgress(0.0);
  pub.EmitProgress(0.5);
  pub.EmitProgress(1.0);
  SUCCEED();
}

TEST(ExportProgressPublisherTest, SetNullChannelThenEmitIsANoOp) {
  auto& pub = ExportProgressPublisher::Instance();
  pub.SetChannel(nullptr);
  pub.EmitProgress(0.42);
  pub.ClearChannel();
  SUCCEED();
}

}  // namespace
}  // namespace clingfy::bridge
