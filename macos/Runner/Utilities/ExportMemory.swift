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

/// How long a render will wait for the pixel-buffer pool to hand a frame back
/// before it gives up and fails the export.
///
/// Generous on purpose. Exceeding the pool's allocation threshold is ordinary
/// backpressure — the writer is behind, and buffers return as it drains — so
/// the wait should outlast any normal stall. It exists to bound a pool that is
/// never going to recover, not to police a slow one.
let exportPixelBufferWaitTimeout: TimeInterval = 10

/// Poll interval while waiting. Short enough not to add visible latency to a
/// one-off stall, long enough not to spin a core during a real one.
private let exportPixelBufferWaitPollInterval: TimeInterval = 0.002

/// Waits for a pooled pixel buffer instead of abandoning the frame.
///
/// [makePooledPixelBuffer] returns `kCVReturnWouldExceedAllocationThreshold`
/// when the pool already has its maximum in flight. Every render loop used to
/// treat that as "stop": it logged and returned out of the
/// `requestMediaDataWhenReady` block without appending a sample, without
/// `markAsFinished()` and without failing. `AVAssetWriterInput` re-invokes that
/// block on a NO -> YES transition of `isReadyForMoreMediaData`, and the loop
/// exited while it was still YES — so on the reading of the AVFoundation
/// contract that matters, nothing rescheduled it. The export then produced no
/// file, no error and no progress, and the caller's completion never fired.
///
/// Waiting is the right answer under either reading of that contract. The
/// condition is transient by construction, so the frame that could not be
/// allocated a moment ago can be allocated shortly after; and if the pool never
/// recovers, the caller gets a terminal status it can turn into a real failure
/// rather than a silent stall.
///
/// Returns the same shape as [makePooledPixelBuffer]. A caller that still sees
/// `kCVReturnWouldExceedAllocationThreshold` has waited the full timeout and
/// must fail the export — it must NOT return quietly.
func awaitPooledPixelBuffer(
  from pool: CVPixelBufferPool,
  maxInFlightBuffers: Int = exportPrepassMaxInFlightBuffers,
  timeout: TimeInterval = exportPixelBufferWaitTimeout,
  isCancelled: () -> Bool = { false }
) -> (pixelBuffer: CVPixelBuffer?, status: CVReturn) {
  var allocation = makePooledPixelBuffer(
    from: pool, maxInFlightBuffers: maxInFlightBuffers)
  guard allocation.status == kCVReturnWouldExceedAllocationThreshold else {
    return allocation
  }

  let deadline = Date().addingTimeInterval(timeout)
  while allocation.status == kCVReturnWouldExceedAllocationThreshold {
    if isCancelled() || Date() >= deadline {
      break
    }
    Thread.sleep(forTimeInterval: exportPixelBufferWaitPollInterval)
    allocation = makePooledPixelBuffer(
      from: pool, maxInFlightBuffers: maxInFlightBuffers)
  }
  return allocation
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
