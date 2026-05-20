import XCTest

@testable import Clingfy

/// Slice 4 / PR 18 guard: the two pure decisions extracted into
/// `CursorHighlightCoordinator` reproduce the inline behavior of the old
/// facade-private `effectiveCursorEnabledForRecording` getter and the ternary
/// in `updateCursorVisibility()`. The side-effecting `updateVisibility(...)`
/// path is exercised end-to-end by the start/stop recording flow.
@MainActor
final class CursorHighlightCoordinatorTests: XCTestCase {

  // MARK: - effectiveCursorEnabledForRecording truth table

  func testEffectiveCursorEnabledRequiresPrefEnabledAndNoSessionSuppression() {
    // prefs on, no session suppression → enabled
    XCTAssertTrue(
      CursorHighlightCoordinator.effectiveCursorEnabledForRecording(
        prefsCursorEnabled: true, sessionDisableCursorHighlight: false))

    // prefs off, no session suppression → disabled
    XCTAssertFalse(
      CursorHighlightCoordinator.effectiveCursorEnabledForRecording(
        prefsCursorEnabled: false, sessionDisableCursorHighlight: false))

    // prefs on, session suppression active → disabled
    XCTAssertFalse(
      CursorHighlightCoordinator.effectiveCursorEnabledForRecording(
        prefsCursorEnabled: true, sessionDisableCursorHighlight: true))

    // prefs off, session suppression active → disabled
    XCTAssertFalse(
      CursorHighlightCoordinator.effectiveCursorEnabledForRecording(
        prefsCursorEnabled: false, sessionDisableCursorHighlight: true))
  }

  // MARK: - shouldShowCursor decision matrix (linked vs unlinked)

  func testLinkedCursorShowsOnlyWhileActivelyRecordingAndEffectivelyEnabled() {
    // linked + recording + effective enabled → show
    XCTAssertTrue(
      CursorHighlightCoordinator.shouldShowCursor(
        cursorLinked: true,
        isActivelyRecording: true,
        effectiveCursorEnabledForRecording: true))

    // linked + recording + effective disabled → hide
    XCTAssertFalse(
      CursorHighlightCoordinator.shouldShowCursor(
        cursorLinked: true,
        isActivelyRecording: true,
        effectiveCursorEnabledForRecording: false))

    // linked + idle + effective enabled → hide (linked = recording-only)
    XCTAssertFalse(
      CursorHighlightCoordinator.shouldShowCursor(
        cursorLinked: true,
        isActivelyRecording: false,
        effectiveCursorEnabledForRecording: true))

    // linked + idle + effective disabled → hide
    XCTAssertFalse(
      CursorHighlightCoordinator.shouldShowCursor(
        cursorLinked: true,
        isActivelyRecording: false,
        effectiveCursorEnabledForRecording: false))
  }

  func testUnlinkedCursorTracksEffectiveEnableOnlyAndIgnoresRecordingState() {
    // unlinked + recording + effective enabled → show
    XCTAssertTrue(
      CursorHighlightCoordinator.shouldShowCursor(
        cursorLinked: false,
        isActivelyRecording: true,
        effectiveCursorEnabledForRecording: true))

    // unlinked + idle + effective enabled → show (unlinked = always when on)
    XCTAssertTrue(
      CursorHighlightCoordinator.shouldShowCursor(
        cursorLinked: false,
        isActivelyRecording: false,
        effectiveCursorEnabledForRecording: true))

    // unlinked + recording + effective disabled → hide
    XCTAssertFalse(
      CursorHighlightCoordinator.shouldShowCursor(
        cursorLinked: false,
        isActivelyRecording: true,
        effectiveCursorEnabledForRecording: false))

    // unlinked + idle + effective disabled → hide
    XCTAssertFalse(
      CursorHighlightCoordinator.shouldShowCursor(
        cursorLinked: false,
        isActivelyRecording: false,
        effectiveCursorEnabledForRecording: false))
  }

  // MARK: - End-to-end: session suppression beats prefs.cursorEnabled

  func testSessionDisableCursorHighlightSuppressesVisibilityRegardlessOfPrefs() {
    // The high-level guarantee that callers rely on: even with prefs on +
    // unlinked + recording, a session-level disable wins.
    let effective = CursorHighlightCoordinator.effectiveCursorEnabledForRecording(
      prefsCursorEnabled: true, sessionDisableCursorHighlight: true)
    XCTAssertFalse(effective)

    XCTAssertFalse(
      CursorHighlightCoordinator.shouldShowCursor(
        cursorLinked: false,
        isActivelyRecording: true,
        effectiveCursorEnabledForRecording: effective))
  }
}
