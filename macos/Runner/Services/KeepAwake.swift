import Foundation

/// Keeps the Mac out of idle sleep while long-running work is in flight.
///
/// Why this exists: nothing in the export path held a sleep assertion, so a
/// long export on battery could be killed mid-flight by idle system sleep with
/// no output file. Windows hit the same class of failure in the 55-minute
/// recording incident and fixed it in #263 with
/// `windows/runner/Services/keep_awake.{h,cpp}`; this is the macOS
/// counterpart. Before this, the only sleep-related code in the whole of
/// `macos/` was an activity held by `CursorRecorder`, which protected
/// recording only incidentally — because cursor capture happens to run
/// alongside it.
///
/// Deliberately NOT an RAII scope, which is the shape Windows uses. There,
/// `RunExportWithDeviceLossRetry` blocks its thread for the whole job so a
/// stack object's destructor lands at the right moment. Nothing on macOS
/// blocks: `LetterboxExporter.export` returns as soon as the pipeline is armed
/// (`requestMediaDataWhenReady` returns immediately), so a stack-scoped hold —
/// or a function-scope `defer` — would release milliseconds in and leave the
/// entire render unprotected, while looking exactly like a working fix. The
/// hold has to outlive the call, so it is an explicit token with the same
/// lifetime as the export's own self-retention.
protocol KeepAwake {
  /// Begins a hold. The returned token must be passed to [end].
  ///
  /// `reason` is user-visible: it appears in `pmset -g assertions`, which is
  /// what a support conversation reads to find out why a Mac would not sleep.
  func begin(reason: String) -> Any

  /// Releases a hold taken by [begin]. Ending the same token twice is a
  /// programming error; call sites take-and-nil under a lock so it cannot
  /// happen.
  func end(_ token: Any)
}

/// The real implementation, on `ProcessInfo` activities.
///
/// `ProcessInfo` rather than `IOPMAssertionCreateWithName` because it needs no
/// entitlement, works inside the sandbox, and is already the idiom this app
/// uses (`CursorRecorder`). It is also process-scoped: a crash, a force-quit
/// or an export that never completes still releases the hold when the process
/// dies, so the worst case is "awake until Clingfy quits" rather than a
/// machine that will not sleep until reboot.
///
/// `.idleSystemSleepDisabled` is spelled out even though `.userInitiated`
/// already implies it in the `NSActivityOptions` bitmask, so that a later edit
/// to the options cannot silently drop sleep protection.
///
/// No `.idleDisplaySleepDisabled`: an export reads no pixels off the screen,
/// and the display turning off must not stop it. That mirrors the Windows
/// split, where export uses `Mode::kSystem` and only recording asks for
/// `kSystemAndDisplay` — there, a dark display records black frames.
struct ProcessInfoKeepAwake: KeepAwake {
  func begin(reason: String) -> Any {
    ProcessInfo.processInfo.beginActivity(
      options: [.userInitiated, .idleSystemSleepDisabled],
      reason: reason
    )
  }

  func end(_ token: Any) {
    guard let activity = token as? NSObjectProtocol else { return }
    ProcessInfo.processInfo.endActivity(activity)
  }
}

/// Holds at most one activity, ending any previous one rather than orphaning
/// it.
///
/// The orphan is the failure this type exists to prevent, and it is
/// deterministic rather than racy. `LetterboxExporter.export` supports
/// re-entrancy on purpose — it opens by cancelling the previous export — and
/// the exporter is a single app-lifetime instance, so a second export
/// overwrites the first export's fields before the first is told to stop.
/// A plain `var token: Any?` would drop the only reference to the previous
/// token with nothing left able to end it: the Mac stays awake until the app
/// quits, and nothing logs why.
///
/// Take-and-nil on release, under the same lock, so a completion that somehow
/// fires twice cannot end the same activity twice.
final class KeepAwakeSlot {
  private let lock = NSLock()
  private let service: KeepAwake
  private var token: Any?

  init(service: KeepAwake = ProcessInfoKeepAwake()) {
    self.service = service
  }

  /// Begins a hold, ending whatever this slot held before.
  func acquire(reason: String) {
    let fresh = service.begin(reason: reason)
    lock.lock()
    let previous = token
    token = fresh
    lock.unlock()
    // Outside the lock: `end` calls into AppKit and must not run under it.
    if let previous {
      NativeLogger.d(
        "KeepAwake", "Replaced a live hold", context: ["reason": reason])
      service.end(previous)
    }
  }

  /// Releases the current hold, if any. Safe to call when nothing is held.
  func release() {
    lock.lock()
    let held = token
    token = nil
    lock.unlock()
    if let held {
      service.end(held)
    }
  }

  /// Whether a hold is currently in effect. For tests and diagnostics.
  var isHeld: Bool {
    lock.lock()
    defer { lock.unlock() }
    return token != nil
  }
}
