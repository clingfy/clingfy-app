import FlutterMacOS
import Foundation

final class ProjectOpenCoordinator {
  static let shared = ProjectOpenCoordinator()

  private var pendingProjectPaths: [String] = []
  private var workflowEventSink: FlutterEventSink?

  init() {}

  func attachWorkflowEventSink(_ sink: @escaping FlutterEventSink) {
    workflowEventSink = sink
    flushPending()
  }

  func detachWorkflowEventSink() {
    workflowEventSink = nil
  }

  func enqueueProjectPath(_ projectPath: String) {
    // A project being repaired at launch opens once its files are in place,
    // not before, when the editor would load the part about to be replaced.
    SalvagedTakeRepairSweep.shared.whenProjectIsFree(projectPath) { [weak self] in
      self?.deliver(projectPath)
    }
  }

  private func deliver(_ projectPath: String) {
    if let workflowEventSink {
      emit(projectPath: projectPath, sink: workflowEventSink)
      return
    }

    guard !pendingProjectPaths.contains(projectPath) else {
      return
    }
    pendingProjectPaths.append(projectPath)
  }

  private func flushPending() {
    guard let workflowEventSink else { return }
    let queuedPaths = pendingProjectPaths
    pendingProjectPaths.removeAll()
    for projectPath in queuedPaths {
      emit(projectPath: projectPath, sink: workflowEventSink)
    }
  }

  private func emit(projectPath: String, sink: @escaping FlutterEventSink) {
    sink([
      "type": "openProjectRequest",
      "projectPath": projectPath,
    ])
  }

#if DEBUG
  func _testReset() {
    pendingProjectPaths.removeAll()
    workflowEventSink = nil
  }
#endif
}
