#include "Bridge/method_router.h"

#include "Bridge/result_helpers.h"
#include "Bridge/Routers/camera_overlay_router.h"
#include "Bridge/Routers/devices_router.h"
#include "Bridge/Routers/export_router.h"
#include "Bridge/Routers/indicator_router.h"
#include "Bridge/Routers/misc_router.h"
#include "Bridge/Routers/permissions_router.h"
#include "Bridge/Routers/preview_router.h"
#include "Bridge/Routers/recording_router.h"
#include "Bridge/Routers/storage_router.h"

namespace clingfy::bridge {

MethodRouter::MethodRouter() {
  // Build the per-method handler table from each domain router. Insertion
  // order does not matter (lookup is hashed). Adding a new method means
  // adding one line in the relevant router file -- no churn to this glue.
  routers::recording::RegisterHandlers(handlers_);
  routers::devices::RegisterHandlers(handlers_);
  routers::camera_overlay::RegisterHandlers(handlers_);
  routers::indicator::RegisterHandlers(handlers_);
  routers::preview::RegisterHandlers(handlers_);
  routers::export_::RegisterHandlers(handlers_);
  routers::permissions::RegisterHandlers(handlers_);
  routers::storage::RegisterHandlers(handlers_);
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
  if (it != handlers_.end()) {
    it->second(call, std::move(result));
    return;
  }
  reply::NotImplemented(*result, call.method_name());
}

bool MethodRouter::HasHandler(const std::string& method) const {
  return handlers_.find(method) != handlers_.end();
}

}  // namespace clingfy::bridge
