#include "Services/keep_awake.h"

namespace clingfy::services {

KeepAwake::KeepAwake(Mode mode, const wchar_t* reason) {
  REASON_CONTEXT context{};
  context.Version = POWER_REQUEST_CONTEXT_VERSION;
  context.Flags = POWER_REQUEST_CONTEXT_SIMPLE_STRING;
  // PowerCreateRequest copies the string; the const_cast is required by the
  // (non-const) Win32 struct field only.
  context.Reason.SimpleReasonString =
      const_cast<LPWSTR>(reason != nullptr ? reason : L"Clingfy");

  request_ = ::PowerCreateRequest(&context);
  if (request_ == nullptr || request_ == INVALID_HANDLE_VALUE) {
    request_ = nullptr;
    return;
  }
  system_set_ = ::PowerSetRequest(request_, PowerRequestSystemRequired) != 0;
  if (mode == Mode::kSystemAndDisplay) {
    display_set_ =
        ::PowerSetRequest(request_, PowerRequestDisplayRequired) != 0;
  }
}

KeepAwake::~KeepAwake() {
  if (request_ == nullptr) {
    return;
  }
  if (display_set_) {
    ::PowerClearRequest(request_, PowerRequestDisplayRequired);
  }
  if (system_set_) {
    ::PowerClearRequest(request_, PowerRequestSystemRequired);
  }
  ::CloseHandle(request_);
}

}  // namespace clingfy::services
