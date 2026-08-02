import Foundation

/// Coalesces a burst of events into a single trailing call.
///
/// Device and screen notifications do not arrive one per user action. Plugging
/// in a single dock can reconfigure several screens and emits
/// `didChangeScreenParameters` once per step; forwarding each one would make
/// Flutter re-enumerate displays several times for what the user experienced
/// as one event.
///
/// Trailing rather than leading on purpose: the interesting state is the one
/// after the burst settles. Firing on the first notification would report the
/// half-attached configuration and then never correct it.
final class TrailingDebouncer {
  private let delay: TimeInterval
  private let queue: DispatchQueue
  private let lock = NSLock()
  private var pendingWorkItem: DispatchWorkItem?

  init(delay: TimeInterval, queue: DispatchQueue = .main) {
    self.delay = delay
    self.queue = queue
  }

  deinit {
    // Without this a debouncer torn down mid-burst still fires into a
    // deallocated owner.
    cancel()
  }

  /// Schedules `action`, replacing any call still waiting. Only the last one
  /// scheduled within `delay` runs.
  func schedule(_ action: @escaping () -> Void) {
    let item = DispatchWorkItem(block: action)

    lock.lock()
    pendingWorkItem?.cancel()
    pendingWorkItem = item
    lock.unlock()

    queue.asyncAfter(deadline: .now() + delay, execute: item)
  }

  func cancel() {
    lock.lock()
    pendingWorkItem?.cancel()
    pendingWorkItem = nil
    lock.unlock()
  }
}
