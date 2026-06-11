#ifndef RUNNER_BRIDGE_METHOD_ROUTER_H_
#define RUNNER_BRIDGE_METHOD_ROUTER_H_

#include <flutter/method_call.h>
#include <flutter/method_result.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>
#include <unordered_map>

namespace clingfy::bridge {

// Function-pointer signature for a single method handler.
//
// Handlers take ownership of the `result` and MUST consume it (call
// `Success(...)` or `Error(...)`) before returning. Phase 1 handlers are all
// synchronous; once Phase 2+ introduces async work, individual handlers can
// move `result` into a callback while keeping the same signature.
using MethodHandler = void (*)(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

// Map of method name -> handler. Routers register their handlers into this
// table at construction time; the router does an O(1) lookup per call.
using HandlerTable = std::unordered_map<std::string, MethodHandler>;

// Pure routing logic for the screen-recorder method channel. Does not own a
// channel and does not depend on a `flutter::BinaryMessenger`, which means
// tests can construct one directly and exercise `Dispatch` without spinning
// up a Flutter engine.
//
// `MethodDispatcher` wraps this and bridges it to the live channel.
class MethodRouter {
 public:
  MethodRouter();

  MethodRouter(const MethodRouter&) = delete;
  MethodRouter& operator=(const MethodRouter&) = delete;

  // Look the call up in the handler table. If found, forward to the
  // registered handler. If not, reply with a structured
  // `WINDOWS_NOT_IMPLEMENTED` error so any bridge drift stays visible.
  //
  // Phase 10.4 dispatch barrier: the handler call is wrapped in try/catch.
  // An uncaught C++ exception in a handler would otherwise unwind out of the
  // platform-channel callback and kill the whole process; the barrier
  // converts it into an `INTERNAL_ERROR` reply instead — but only when the
  // handler had not already resolved the result (a reply that was sent
  // before the throw is preserved, never doubled).
  void Dispatch(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result)
      const;

  // Test-only: install (or override) a handler. Lets unit tests exercise the
  // dispatch barrier with a deliberately-throwing handler without wiring a
  // synthetic method into a production router file.
  void RegisterHandlerForTesting(const std::string& method,
                                 MethodHandler handler);

  // True when `method` has an explicit registered handler -- i.e. it would
  // not fall through to the WINDOWS_NOT_IMPLEMENTED fallback. Used by tests
  // to verify bridge-contract coverage.
  bool HasHandler(const std::string& method) const;

 private:
  HandlerTable handlers_;
};

}  // namespace clingfy::bridge

#endif  // RUNNER_BRIDGE_METHOD_ROUTER_H_
