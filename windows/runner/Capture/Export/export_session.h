// Slice 5A of Phase 6 (export) — process-level export session state.
//
// Holds the cancel + running flags shared between the `exportVideo` handler
// (which runs the export, on a worker thread in production) and the separate
// `cancelExport` handler (which can only signal the in-flight export to stop).
// A blocked synchronous export could never receive a cancel, which is why the
// export moves to a worker thread; this singleton is how the two method-channel
// handlers reach the same atomic flag.
//
// Pure (no Win32 / Media Foundation) and all-atomic, so it is unit-tested in
// `export_session_test.cpp` without a GPU or a real channel.

#ifndef RUNNER_CAPTURE_EXPORT_EXPORT_SESSION_H_
#define RUNNER_CAPTURE_EXPORT_EXPORT_SESSION_H_

#include <atomic>

namespace clingfy::capture::export_ {

class ExportSession {
 public:
  static ExportSession& Instance();

  ExportSession(const ExportSession&) = delete;
  ExportSession& operator=(const ExportSession&) = delete;

  // Claim the session for a new export. Returns false (and does nothing) when
  // an export is already running, so the caller can reject a concurrent
  // request instead of corrupting shared state. On success it marks the
  // session running and clears any stale cancel request.
  bool BeginExport();

  // Release the session after an export finishes (success, failure, or
  // cancel). Safe to call once per successful BeginExport.
  void EndExport();

  // Signal the in-flight export to stop at its next cancel check. No-op when
  // nothing is running; the flag is cleared by the next BeginExport.
  void RequestCancel();

  // True once RequestCancel was called for the current export. The export
  // loop polls this each iteration.
  bool IsCancelled() const;

  // True between BeginExport and EndExport.
  bool IsRunning() const;

  // Test-only: reset to the idle/uncancelled state.
  void ResetForTesting();

 private:
  ExportSession() = default;

  std::atomic<bool> running_{false};
  std::atomic<bool> cancel_requested_{false};
};

}  // namespace clingfy::capture::export_

#endif  // RUNNER_CAPTURE_EXPORT_EXPORT_SESSION_H_
