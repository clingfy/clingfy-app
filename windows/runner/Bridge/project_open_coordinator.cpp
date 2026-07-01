#include "Bridge/project_open_coordinator.h"

#include <algorithm>
#include <utility>

#include "Bridge/workflow_event_publisher.h"

namespace clingfy::bridge {

ProjectOpenCoordinator& ProjectOpenCoordinator::Instance() {
  static ProjectOpenCoordinator instance;
  return instance;
}

void ProjectOpenCoordinator::Enqueue(const std::string& project_path) {
  if (project_path.empty()) return;

  bool emit_now = false;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (sink_attached_) {
      emit_now = true;
    } else {
      // Dedup against existing pending entries — matches
      // ProjectOpenCoordinator.swift's contains() guard. A user who
      // launches the same .clingfyproj twice in quick succession from
      // Explorer should not see two openProjectRequest events.
      const auto already_pending =
          std::find(pending_.begin(), pending_.end(), project_path) !=
          pending_.end();
      if (!already_pending) {
        pending_.push_back(project_path);
      }
    }
  }

  if (emit_now) {
    WorkflowEventPublisher::Instance().EmitOpenProjectRequest(project_path);
  }
}

void ProjectOpenCoordinator::OnSinkAttached() {
  std::vector<std::string> to_emit;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    sink_attached_ = true;
    to_emit.swap(pending_);
  }
  // Emit outside the lock so the publisher's PlatformThreadDispatcher
  // post can't deadlock if it ever needed to wait on this mutex.
  for (const auto& path : to_emit) {
    WorkflowEventPublisher::Instance().EmitOpenProjectRequest(path);
  }
}

void ProjectOpenCoordinator::OnSinkDetached() {
  std::lock_guard<std::mutex> lock(mutex_);
  sink_attached_ = false;
}

bool ProjectOpenCoordinator::has_sink() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return sink_attached_;
}

void ProjectOpenCoordinator::ResetForTesting() {
  std::lock_guard<std::mutex> lock(mutex_);
  pending_.clear();
  sink_attached_ = false;
}

}  // namespace clingfy::bridge
