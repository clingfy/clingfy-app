#include "Bridge/method_router.h"

#include <atomic>
#include <exception>
#include <memory>
#include <utility>

#include "Bridge/native_error_codes.h"
#include "Bridge/native_log_publisher.h"
#include "Bridge/result_helpers.h"
#include "Bridge/Routers/camera_overlay_router.h"
#include "Bridge/Routers/devices_router.h"
#include "Bridge/Routers/export_router.h"
#include "Bridge/Routers/indicator_router.h"
#include "Bridge/Routers/misc_router.h"
#include "Bridge/Routers/permissions_router.h"
#include "Bridge/Routers/pre_recording_bar_router.h"
#include "Bridge/Routers/preview_router.h"
#include "Bridge/Routers/recording_router.h"
#include "Bridge/Routers/storage_router.h"
#include "Bridge/Routers/updater_router.h"

namespace clingfy::bridge {

namespace {

// Phase 10.4 dispatch-barrier support: wraps the MethodResult handed to a
// handler so the barrier in `Dispatch` can (a) know whether the handler
// already replied and (b) still reach the underlying result if the handler
// threw after moving/dropping its wrapper (e.g. into a worker-thread lambda
// whose construction failed). The `replied` flag is shared with `Dispatch`;
// whichever side flips it first wins, so every code path resolves the
// result EXACTLY once — a late second reply is silently dropped instead of
// reaching the engine twice.
class GuardedResult : public flutter::MethodResult<flutter::EncodableValue> {
 public:
  GuardedResult(
      std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> inner,
      std::shared_ptr<std::atomic<bool>> replied)
      : inner_(std::move(inner)), replied_(std::move(replied)) {}

 protected:
  void SuccessInternal(const flutter::EncodableValue* result) override {
    if (replied_->exchange(true)) {
      return;
    }
    if (result != nullptr) {
      inner_->Success(*result);
    } else {
      inner_->Success();
    }
  }

  void ErrorInternal(const std::string& error_code,
                     const std::string& error_message,
                     const flutter::EncodableValue* error_details) override {
    if (replied_->exchange(true)) {
      return;
    }
    if (error_details != nullptr) {
      inner_->Error(error_code, error_message, *error_details);
    } else {
      inner_->Error(error_code, error_message);
    }
  }

  void NotImplementedInternal() override {
    if (replied_->exchange(true)) {
      return;
    }
    inner_->NotImplemented();
  }

 private:
  std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> inner_;
  std::shared_ptr<std::atomic<bool>> replied_;
};

}  // namespace

MethodRouter::MethodRouter() {
  // Build the per-method handler table from each domain router. Insertion
  // order does not matter (lookup is hashed). Adding a new method means
  // adding one line in the relevant router file -- no churn to this glue.
  routers::recording::RegisterHandlers(handlers_);
  routers::devices::RegisterHandlers(handlers_);
  routers::camera_overlay::RegisterHandlers(handlers_);
  routers::indicator::RegisterHandlers(handlers_);
  routers::pre_recording_bar::RegisterHandlers(handlers_);
  routers::preview::RegisterHandlers(handlers_);
  routers::export_::RegisterHandlers(handlers_);
  routers::permissions::RegisterHandlers(handlers_);
  routers::storage::RegisterHandlers(handlers_);
  routers::updater::RegisterHandlers(handlers_);
  routers::misc::RegisterHandlers(handlers_);
  // Note: pocStage2aStart / pocStage2aStop are now registered as
  // deprecated aliases inside preview_router.cpp — they forward into
  // the same PreviewEngine that production previewOpen / previewClose
  // will use starting in Step 5.3.
}

void MethodRouter::Dispatch(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result)
    const {
  const auto it = handlers_.find(call.method_name());
  if (it == handlers_.end()) {
    reply::NotImplemented(*result, call.method_name());
    return;
  }
  // Dispatch barrier (Phase 10.4): an uncaught C++ exception in a handler
  // would unwind out of the platform-channel callback and crash the whole
  // process. The handler gets a guarded wrapper; we keep the shared inner
  // result + replied flag so on a throw the Dart future is still resolved
  // with INTERNAL_ERROR — if and only if the handler had not already
  // replied. Overhead per call: one heap wrapper + one atomic flag.
  std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> inner(
      std::move(result));
  auto replied = std::make_shared<std::atomic<bool>>(false);
  try {
    it->second(call, std::make_unique<GuardedResult>(inner, replied));
  } catch (const std::exception& e) {
    NativeLogPublisher::Instance().Error(
        "Bridge", "Unhandled exception in handler '" + call.method_name() +
                      "': " + e.what());
    if (!replied->exchange(true)) {
      inner->Error(error::kInternalError,
                   "Unhandled native exception in '" + call.method_name() +
                       "': " + e.what());
    }
  } catch (...) {
    NativeLogPublisher::Instance().Error(
        "Bridge", "Unhandled non-standard exception in handler '" +
                      call.method_name() + "'.");
    if (!replied->exchange(true)) {
      inner->Error(error::kInternalError,
                   "Unhandled native exception in '" + call.method_name() +
                       "'.");
    }
  }
}

void MethodRouter::RegisterHandlerForTesting(const std::string& method,
                                             MethodHandler handler) {
  handlers_[method] = handler;
}

bool MethodRouter::HasHandler(const std::string& method) const {
  return handlers_.find(method) != handlers_.end();
}

std::vector<std::string> MethodRouter::RegisteredMethodNames() const {
  std::vector<std::string> names;
  names.reserve(handlers_.size());
  for (const auto& entry : handlers_) {
    names.push_back(entry.first);
  }
  return names;
}

}  // namespace clingfy::bridge
