import Foundation

/// Tracks wall-clock recording time across pause/resume segments.
/// Pure value type — no platform dependency (engine-domain; see windows-port-inventory §7).
struct RecordedDurationTracker {
  private(set) var wallClockSessionStart: Date?
  private var activeSegmentStart: Date?
  private(set) var accumulatedRecordedDuration: TimeInterval = 0
  private(set) var isPaused = false

  mutating func start(at date: Date = Date()) {
    wallClockSessionStart = date
    activeSegmentStart = date
    accumulatedRecordedDuration = 0
    isPaused = false
  }

  mutating func pause(at date: Date = Date()) {
    guard let activeSegmentStart else { return }
    accumulatedRecordedDuration += max(0, date.timeIntervalSince(activeSegmentStart))
    self.activeSegmentStart = nil
    isPaused = true
  }

  mutating func resume(at date: Date = Date()) {
    guard wallClockSessionStart != nil, activeSegmentStart == nil else { return }
    activeSegmentStart = date
    isPaused = false
  }

  mutating func stop(at date: Date = Date()) {
    if let activeSegmentStart {
      accumulatedRecordedDuration += max(0, date.timeIntervalSince(activeSegmentStart))
    }
    activeSegmentStart = nil
    isPaused = false
  }

  mutating func reset() {
    wallClockSessionStart = nil
    activeSegmentStart = nil
    accumulatedRecordedDuration = 0
    isPaused = false
  }

  func currentRecordedDuration(at date: Date = Date()) -> TimeInterval {
    guard let activeSegmentStart else { return accumulatedRecordedDuration }
    return accumulatedRecordedDuration + max(0, date.timeIntervalSince(activeSegmentStart))
  }
}
