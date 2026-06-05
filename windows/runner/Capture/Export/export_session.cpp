#include "Capture/Export/export_session.h"

namespace clingfy::capture::export_ {

ExportSession& ExportSession::Instance() {
  static ExportSession instance;
  return instance;
}

bool ExportSession::BeginExport() {
  bool expected = false;
  // Atomically flip running_ false->true; fail if already running.
  if (!running_.compare_exchange_strong(expected, true)) {
    return false;
  }
  cancel_requested_.store(false);
  return true;
}

void ExportSession::EndExport() { running_.store(false); }

void ExportSession::RequestCancel() { cancel_requested_.store(true); }

bool ExportSession::IsCancelled() const { return cancel_requested_.load(); }

bool ExportSession::IsRunning() const { return running_.load(); }

void ExportSession::ResetForTesting() {
  running_.store(false);
  cancel_requested_.store(false);
}

}  // namespace clingfy::capture::export_
