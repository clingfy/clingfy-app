import AVFoundation
import Darwin.Mach

private let exportMemoryCheckpointInterval = 120
private let exportPrepassMaxInFlightBuffers = 6

enum ExportDiagnostics {
  private static let envValue: String =
    ProcessInfo.processInfo.environment["CLINGFY_EXPORT_DIAGNOSTICS"] ?? ""

  static let enabled: Bool = {
    if BuildEnvironment.isDebugBuild {
      return true
    }

    let normalized = envValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized == "1" || normalized == "true" || normalized == "yes"
  }()
}

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

func makePooledPixelBuffer(
  from pool: CVPixelBufferPool,
  maxInFlightBuffers: Int = exportPrepassMaxInFlightBuffers
) -> (pixelBuffer: CVPixelBuffer?, status: CVReturn) {
  let auxAttributes = [
    kCVPixelBufferPoolAllocationThresholdKey as String: maxInFlightBuffers
  ] as CFDictionary

  var pixelBuffer: CVPixelBuffer?
  let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
    kCFAllocatorDefault,
    pool,
    auxAttributes,
    &pixelBuffer
  )

  return (pixelBuffer, status)
}

func logExportMemoryCheckpoint(stage: String, frameIndex: Int) {
  guard ExportDiagnostics.enabled else { return }
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

func logExportBackpressure(stage: String, frameIndex: Int) {
  guard ExportDiagnostics.enabled else { return }

  NativeLogger.d(
    "ExportMemory",
    "Pixel buffer pool backpressure",
    context: [
      "stage": stage,
      "frame": frameIndex,
    ]
  )
}

func logExportStagePerformance(
  stage: String,
  frames: Int? = nil,
  startedAt: CFAbsoluteTime,
  renderPath: String? = nil
) {
  let elapsedSeconds = max(CFAbsoluteTimeGetCurrent() - startedAt, 0.0001)
  var context: [String: Any] = [
    "stage": stage,
    "elapsedSeconds": elapsedSeconds,
  ]

  if let frames {
    context["frames"] = frames
    context["fps"] = Double(frames) / elapsedSeconds
  }

  if let renderPath {
    context["renderPath"] = renderPath
  }

  NativeLogger.i(
    "ExportPerf",
    "Stage finished",
    context: context
  )
}
