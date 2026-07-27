import AppKit
import Foundation

/// Watches the on-screen window list and reports when it actually changes.
///
/// Every other picker in the app is driven by an OS notification. The window
/// list is the one exception: `CGWindowListCopyWindowInfo` is a pull-only
/// snapshot with no observer, `SCShareableContent` is a one-shot TCC-gated
/// query, and `NSWorkspace` is process-granular — it cannot see ⌘N in an
/// already-running app, nor a window being closed or minimised. The only true
/// per-window push is an `AXObserver`, which needs Accessibility, and this app
/// only requests that opt-in for cursor highlight. So this list, and only this
/// list, is polled.
///
/// Two things keep the cost honest:
///
/// 1. **It is ref-counted and off by default.** Polling runs only while a
///    window picker is actually on screen — the Flutter sidebar dropdown and
///    the native pre-recording bar popover each take a reference. With no
///    picker open there is no timer and no wakeup.
/// 2. **It emits only on a real change.** Each tick fingerprints the list;
///    an unchanged fingerprint costs one enumeration and nothing else, so a
///    static desktop never wakes Flutter.
final class AppWindowWatcher {

  /// One second: a picker is open and being looked at, so a new window should
  /// appear about as fast as the user can glance at the list. Shorter buys no
  /// perceptible responsiveness and multiplies enumerations.
  static let defaultInterval: TimeInterval = 1.0

  private let interval: TimeInterval
  private let enumerate: () -> [[String: Any]]
  private let lock = NSLock()

  private var activations = 0
  private var timer: DispatchSourceTimer?
  private var lastFingerprint: String?
  private var workspaceObservers: [NSObjectProtocol] = []

  /// Fired on the main queue when the window list differs from the last tick.
  var onChanged: (() -> Void)?

  init(
    interval: TimeInterval = AppWindowWatcher.defaultInterval,
    enumerate: @escaping () -> [[String: Any]]
  ) {
    self.interval = interval
    self.enumerate = enumerate
  }

  deinit {
    timer?.cancel()
    for observer in workspaceObservers {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
  }

  var isActive: Bool {
    lock.lock()
    defer { lock.unlock() }
    return activations > 0
  }

  /// Ref-counted so the sidebar and the bar popover can both ask for
  /// watching without either one switching the other off.
  func retain() {
    lock.lock()
    activations += 1
    let shouldStart = activations == 1
    lock.unlock()

    guard shouldStart else { return }
    // Seed the fingerprint so the first tick reports a genuine change rather
    // than the list simply becoming known.
    lock.lock()
    lastFingerprint = Self.fingerprint(enumerate())
    lock.unlock()
    startTimer()
    observeWorkspaceHints()
  }

  func release() {
    lock.lock()
    if activations > 0 { activations -= 1 }
    let shouldStop = activations == 0
    lock.unlock()

    guard shouldStop else { return }
    stopTimer()
    stopObservingWorkspaceHints()
  }

  /// Drops every reference. Used when a recording starts — the picker is
  /// unusable then, so nothing should be polling.
  func releaseAll() {
    lock.lock()
    activations = 0
    lock.unlock()
    stopTimer()
    stopObservingWorkspaceHints()
  }

  /// Enumerates once and reports if the list changed. Exposed so callers can
  /// force a check on an `NSWorkspace` hint without waiting for the tick.
  func poll() {
    let next = Self.fingerprint(enumerate())

    lock.lock()
    let changed = next != lastFingerprint
    lastFingerprint = next
    lock.unlock()

    guard changed else { return }
    onChanged?()
  }

  /// Identity of the list as the picker presents it.
  ///
  /// Title is part of it deliberately: a browser switching tabs keeps the same
  /// window id but renames the entry the user is choosing between, and a
  /// picker showing the old title is wrong in a way the user can see.
  static func fingerprint(_ windows: [[String: Any]]) -> String {
    windows
      .map { window in
        let id = (window["windowId"] as? NSNumber)?.stringValue ?? "?"
        let app = window["appName"] as? String ?? ""
        let title = window["title"] as? String ?? ""
        return "\(id)|\(app)|\(title)"
      }
      .joined(separator: "\n")
  }

  private func startTimer() {
    let source = DispatchSource.makeTimerSource(queue: .main)
    source.schedule(deadline: .now() + interval, repeating: interval)
    source.setEventHandler { [weak self] in self?.poll() }
    source.resume()

    lock.lock()
    timer?.cancel()
    timer = source
    lock.unlock()
  }

  private func stopTimer() {
    lock.lock()
    let existing = timer
    timer = nil
    lastFingerprint = nil
    lock.unlock()
    existing?.cancel()
  }

  /// App launch and quit are the changes a user is most likely to make while
  /// staring at the picker, and NSWorkspace reports them immediately. Polling
  /// still covers everything else; these just remove the up-to-one-second lag
  /// from the two most visible cases.
  private func observeWorkspaceHints() {
    let center = NSWorkspace.shared.notificationCenter
    let names: [NSNotification.Name] = [
      NSWorkspace.didLaunchApplicationNotification,
      NSWorkspace.didTerminateApplicationNotification,
    ]
    let observers = names.map { name in
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.poll()
      }
    }
    lock.lock()
    workspaceObservers.append(contentsOf: observers)
    lock.unlock()
  }

  private func stopObservingWorkspaceHints() {
    lock.lock()
    let observers = workspaceObservers
    workspaceObservers = []
    lock.unlock()
    for observer in observers {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
  }
}
