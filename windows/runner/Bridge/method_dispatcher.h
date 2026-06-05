#ifndef RUNNER_BRIDGE_METHOD_DISPATCHER_H_
#define RUNNER_BRIDGE_METHOD_DISPATCHER_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

#include "Bridge/method_router.h"

namespace clingfy::bridge {

// Owns the screen-recorder method channel on the Windows side and forwards
// every call to a `MethodRouter`.
//
// The routing logic itself lives in `MethodRouter` so it can be unit-tested
// without a `BinaryMessenger`. This class is the thin glue that registers
// the channel handler and keeps the router alive for the channel's lifetime.
//
// See `MethodRouter` for the Phase 1 stub policy.
class MethodDispatcher {
 public:
  explicit MethodDispatcher(flutter::BinaryMessenger* messenger);
  ~MethodDispatcher();

  MethodDispatcher(const MethodDispatcher&) = delete;
  MethodDispatcher& operator=(const MethodDispatcher&) = delete;

  // The screen_recorder method channel, for native -> Flutter reverse calls
  // (e.g. export progress). Owned here; borrowers must not outlive the
  // dispatcher. Returns nullptr only if construction failed.
  flutter::MethodChannel<flutter::EncodableValue>* channel() const {
    return channel_.get();
  }

 private:
  MethodRouter router_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

}  // namespace clingfy::bridge

#endif  // RUNNER_BRIDGE_METHOD_DISPATCHER_H_
