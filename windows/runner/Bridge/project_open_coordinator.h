// ProjectOpenCoordinator — queue + flush of `openProjectRequest`
// workflow events. Mirrors `macos/Runner/Services/ProjectOpenCoordinator.swift`.
//
// Why a coordinator and not a direct emit:
//   * Project-open requests arrive at startup before Dart has attached
//     a workflow/events listener (the Flutter engine is still warming
//     up when `WinMain` parses argv).
//   * Without a queue, the request would race the sink installation
//     and `WorkflowEventPublisher::EmitMap` would drop it silently.
//   * Mirrors the macOS coordinator pattern so the Dart side observes
//     identical semantics on either platform.
//
// Lifecycle:
//   1. main.cpp parses argv. If a `.clingfyproj` path is present, it
//      calls `Enqueue(path)` before the FlutterWindow is created.
//   2. flutter_window.cpp registers the `WM_COPYDATA` receiver and the
//      workflow stream handler. Later (potentially seconds later) Dart
//      subscribes to `workflow/events`, which triggers the stream
//      handler's `OnListenInternal` → `OnSinkAttached()`.
//   3. `OnSinkAttached()` drains the queue: each pending path is sent
//      through `WorkflowEventPublisher::EmitOpenProjectRequest`.
//   4. After the sink is attached, `Enqueue(path)` emits directly via
//      the publisher (no queue).
//
// Thread safety: callers come from the main / platform thread for
// cold-start argv enqueues, and from a worker thread for `WM_COPYDATA`
// receives. The internal mutex serializes access.

#ifndef RUNNER_BRIDGE_PROJECT_OPEN_COORDINATOR_H_
#define RUNNER_BRIDGE_PROJECT_OPEN_COORDINATOR_H_

#include <mutex>
#include <string>
#include <vector>

namespace clingfy::bridge {

class ProjectOpenCoordinator {
 public:
  static ProjectOpenCoordinator& Instance();

  ProjectOpenCoordinator(const ProjectOpenCoordinator&) = delete;
  ProjectOpenCoordinator& operator=(const ProjectOpenCoordinator&) = delete;

  // Queue a project path (or emit immediately if the sink is attached).
  // Empty paths are ignored. Duplicate consecutive enqueues for the
  // same path are de-duplicated to keep the macOS no-redeliver contract.
  void Enqueue(const std::string& project_path);

  // Called by `WorkflowStreamHandler::OnListenInternal` once Dart has
  // subscribed. Drains the queue through
  // `WorkflowEventPublisher::EmitOpenProjectRequest`.
  void OnSinkAttached();

  // Called by `WorkflowStreamHandler::OnCancelInternal`. Subsequent
  // `Enqueue` calls will queue again until the next OnSinkAttached.
  void OnSinkDetached();

  // True after OnSinkAttached and before OnSinkDetached. Exposed for
  // tests and engine diagnostics.
  bool has_sink() const;

  // Test-only: reset internal state so each test starts clean. Not part
  // of the production lifecycle.
  void ResetForTesting();

 private:
  ProjectOpenCoordinator() = default;

  mutable std::mutex mutex_;
  std::vector<std::string> pending_;
  bool sink_attached_ = false;
};

}  // namespace clingfy::bridge

#endif  // RUNNER_BRIDGE_PROJECT_OPEN_COORDINATOR_H_
