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
/// What a hold keeps awake.
enum KeepAwakeMode {
  /// The machine keeps working; the display may still turn off. For work that
  /// reads no pixels off the screen — an export renders from files.
  case system

  /// The machine AND the display stay on. For recording: a display that turns
  /// off records black frames. Windows asks for the same split and says so in
  /// `windows/runner/Services/keep_awake.h`.
  case systemAndDisplay
}

protocol KeepAwake {
  /// Begins a hold. The returned token must be passed to [end].
  ///
  /// `reason` is user-visible: it appears in `pmset -g assertions`, which is
  /// what a support conversation reads to find out why a Mac would not sleep.
  ///
  /// `mode` is explicit at every call rather than defaulted. A default would
  /// let a later edit widen what export holds without anyone noticing, and
  /// export holding the display awake is a bug the user feels as a screen that
  /// never dims.
  func begin(reason: String, mode: KeepAwakeMode) -> Any

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
/// `.idleDisplaySleepDisabled` is added only for [KeepAwakeMode.systemAndDisplay].
/// An export reads no pixels off the screen and must not stop the display
/// turning off; a recording must, because a dark display records black frames.
struct ProcessInfoKeepAwake: KeepAwake {
  /// The option set a mode maps to.
  ///
  /// Pulled out as a pure function so the decision can be asserted directly.
  /// `ProcessInfo` offers no way to read back what an activity is holding, so
  /// a test that only checked `beginActivity` returned something would pass
  /// just as happily with the mode ignored — which is exactly the regression
  /// worth catching, since it silently drops the display hold that keeps a
  /// recording from capturing black frames.
  static func activityOptions(for mode: KeepAwakeMode)
    -> ProcessInfo.ActivityOptions
  {
    var options: ProcessInfo.ActivityOptions = [
      .userInitiated, .idleSystemSleepDisabled,
    ]
    if mode == .systemAndDisplay {
      options.insert(.idleDisplaySleepDisabled)
    }
    return options
  }

  func begin(reason: String, mode: KeepAwakeMode) -> Any {
    ProcessInfo.processInfo.beginActivity(
      options: Self.activityOptions(for: mode),
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
  func acquire(reason: String, mode: KeepAwakeMode) {
    let fresh = service.begin(reason: reason, mode: mode)
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

  /// Releases on deallocation, so the hold cannot outlive its owner.
  ///
  /// The exporter gets away without this — it is one app-lifetime instance —
  /// but a capture backend is built per recording and dropped wholesale when
  /// the next one starts (`ScreenRecorderFacade.setCaptureBackend`). A slot
  /// that still held an activity when its owner was released would leave the
  /// Mac awake with nothing left alive to call `release()`, because
  /// `ProcessInfo`'s contract is `endActivity`, not token deallocation.
  deinit {
    release()
  }
}
