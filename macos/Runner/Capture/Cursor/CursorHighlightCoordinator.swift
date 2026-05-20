import Foundation

/// Slice 4 / PR 18: owns the `CursorHighlighter` overlay + the two pure
/// visibility decisions previously held inline as
/// `effectiveCursorEnabledForRecording` and `updateCursorVisibility()` on
/// `ScreenRecorderFacade`.
///
/// The coordinator deliberately does NOT own `prefs.cursorEnabled`,
/// `prefs.cursorLinked`, `sessionDisableCursorHighlight`, or any of the
/// accessibility-prompt UX (`ensureAccessibilityAllowedAndGuideUser`,
/// `AXIsProcessTrusted`); the facade keeps those because they are
/// permission-coupled and move with the later permissions slice (see
/// PR 14 / `RecordingPreflightService`). Engine-domain; see
/// `windows-port-inventory.md` §7.
@MainActor
final class CursorHighlightCoordinator {

  private let cursor: CursorHighlighter

  init(cursor: CursorHighlighter = CursorHighlighter()) {
    self.cursor = cursor
  }

  /// Pure: the per-session-effective "should the recording-linked cursor be
  /// considered enabled?" value. Mirrors the old facade-private
  /// `effectiveCursorEnabledForRecording` getter:
  /// `prefs.cursorEnabled && !sessionDisableCursorHighlight`.
  static func effectiveCursorEnabledForRecording(
    prefsCursorEnabled: Bool,
    sessionDisableCursorHighlight: Bool
  ) -> Bool {
    prefsCursorEnabled && !sessionDisableCursorHighlight
  }

  /// Pure: the visibility-show decision previously held inline as the ternary
  /// in `updateCursorVisibility()`. When the cursor is *linked* to recording,
  /// it shows only while a recording is actively running and the
  /// per-session-effective enable is true; when *unlinked* it just tracks the
  /// per-session-effective enable.
  static func shouldShowCursor(
    cursorLinked: Bool,
    isActivelyRecording: Bool,
    effectiveCursorEnabledForRecording: Bool
  ) -> Bool {
    cursorLinked
      ? (isActivelyRecording && effectiveCursorEnabledForRecording)
      : effectiveCursorEnabledForRecording
  }

  /// Side-effecting wrapper used by the facade. Computes `shouldShowCursor`
  /// and starts or stops the highlighter to match — verbatim from the old
  /// `updateCursorVisibility()`.
  func updateVisibility(
    prefsCursorEnabled: Bool,
    sessionDisableCursorHighlight: Bool,
    cursorLinked: Bool,
    isActivelyRecording: Bool
  ) {
    let effective = Self.effectiveCursorEnabledForRecording(
      prefsCursorEnabled: prefsCursorEnabled,
      sessionDisableCursorHighlight: sessionDisableCursorHighlight)
    let shouldShow = Self.shouldShowCursor(
      cursorLinked: cursorLinked,
      isActivelyRecording: isActivelyRecording,
      effectiveCursorEnabledForRecording: effective)
    shouldShow ? cursor.start() : cursor.stop()
  }
}
