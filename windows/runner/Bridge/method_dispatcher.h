#ifndef RUNNER_BRIDGE_METHOD_DISPATCHER_H_
#define RUNNER_BRIDGE_METHOD_DISPATCHER_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

namespace clingfy::bridge {

// Owns the screen-recorder method channel on the Windows side.
//
// Phase 0: every method returns a structured error with code
// `WINDOWS_NOT_IMPLEMENTED`. The goal is that the Flutter UI never sees a raw
// MissingPluginException at startup, and every action degrades to a clean,
// localizable error.
//
// Later phases replace the catch-all stub with real handlers (device
// enumeration in Phase 2, capture in Phase 3, export in Phase 6, etc.).
class MethodDispatcher {
 public:
  explicit MethodDispatcher(flutter::BinaryMessenger* messenger);
  ~MethodDispatcher();

  MethodDispatcher(const MethodDispatcher&) = delete;
  MethodDispatcher& operator=(const MethodDispatcher&) = delete;

 private:
  void HandleCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

}  // namespace clingfy::bridge

#endif  // RUNNER_BRIDGE_METHOD_DISPATCHER_H_
