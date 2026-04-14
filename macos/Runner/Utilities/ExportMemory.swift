import Darwin.Mach

private let exportMemoryCheckpointInterval = 120

func currentResidentMB() -> Double? {
  var info = task_vm_info_data_t()
  var count = mach_msg_type_number_t(
    MemoryLayout.size(ofValue: info) / MemoryLayout<natural_t>.size
  )

  let result: kern_return_t = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
      task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
    }
  }

  guard result == KERN_SUCCESS else { return nil }
  return Double(info.phys_footprint) / 1024.0 / 1024.0
}

func logExportMemoryCheckpoint(stage: String, frameIndex: Int) {
  guard frameIndex % exportMemoryCheckpointInterval == 0 else { return }
  guard let residentMB = currentResidentMB() else { return }

  NativeLogger.i(
    "ExportMemory",
    "Memory checkpoint",
    context: [
      "stage": stage,
      "frame": frameIndex,
      "residentMB": residentMB,
    ]
  )
}
