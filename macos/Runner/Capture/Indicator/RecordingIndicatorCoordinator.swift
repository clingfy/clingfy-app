import Foundation

/// Slice 4 / PR 17: owns the `RecordingIndicator` panel and the two pure
/// helpers that map recorder state into indicator-view state and format the
/// elapsed-recording label. Previously inline as
/// `currentIndicatorState()` / `formattedElapsed()` /
/// `applyIndicatorState()` on `ScreenRecorderFacade`.
///
/// The coordinator deliberately does NOT own `RecordedDurationTracker`,
/// `state: RecorderState`, `capture`, `prefs`, or the indicator-tap callbacks;
/// the facade keeps them and passes them in on every `apply(...)`. This
/// preserves the existing `setRecordingIndicatorPinned(_:)` bridge and the
/// `_testCurrentIndicatorState` / `_testIndicatorConfiguration` test seams.
/// Engine-domain; see `windows-port-inventory.md` §7.
@MainActor
final class RecordingIndicatorCoordinator {

  private let indicator: RecordingIndicator

  init(indicator: RecordingIndicator = RecordingIndicator()) {
    self.indicator = indicator
  }

  /// Pure mapping previously held as `currentIndicatorState()` on the facade.
  /// Verbatim — `.idle` and `.starting` collapse to `.hidden`.
  static func indicatorState(for recorderState: RecorderState) -> IndicatorState {
    switch recorderState {
    case .recording: return .recording
    case .paused: return .paused
    case .stopping: return .stopping
    case .idle, .starting: return .hidden
    }
  }

  /// Pure formatter previously held as `formattedElapsed()` on the facade.
  /// `DateComponentsFormatter` with `[.pad]` zero-formatting; clamps negatives.
  static func formatElapsed(seconds: Int) -> String {
    let secs = max(0, seconds)
    let f = DateComponentsFormatter()
    f.allowedUnits = [.hour, .minute, .second]
    f.zeroFormattingBehavior = [.pad]
    return f.string(from: TimeInterval(secs)) ?? "00:00:00"
  }

  /// Apply the indicator state. The facade keeps owning the recorder state
  /// machine, `capture.canPauseResume`, the elapsed provider, the tap
  /// callbacks, and `prefs.indicatorPinned`; this method only does the
  /// derive-and-forward step previously inline in `applyIndicatorState()`.
  ///
  /// The `onPauseTapped` callback is suppressed when `canPauseResume` is
  /// `false`, matching the old `capture.canPauseResume ? ... : nil` gating.
  func apply(
    recorderState: RecorderState,
    pinned: Bool,
    canPauseResume: Bool,
    onPauseTapped: @escaping () -> Void,
    onStopTapped: @escaping () -> Void,
    onResumeTapped: @escaping () -> Void,
    elapsedProvider: @escaping () -> String
  ) {
    indicator.setState(
      Self.indicatorState(for: recorderState),
      pinned: pinned,
      onPauseTapped: canPauseResume ? onPauseTapped : nil,
      onStopTapped: onStopTapped,
      onResumeTapped: onResumeTapped,
      elapsedProvider: elapsedProvider
    )
  }
}
