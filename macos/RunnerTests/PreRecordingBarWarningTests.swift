import AppKit
import XCTest

@testable import Clingfy

/// The pre-recording bar is the surface a user looks at immediately before
/// hitting record, and both conditions it now reports — a mic far too quiet,
/// system audio bleeding into the mic — are only cheap to fix BEFORE the take.
final class PreRecordingBarWarningTests: XCTestCase {

  func testWarningTintOverridesTheHealthyAccentWhenEnabled() {
    XCTAssertEqual(
      PreRecordingBarView.audioButtonTint(enabled: true, warning: true),
      .systemOrange)
    XCTAssertEqual(
      PreRecordingBarView.audioButtonTint(enabled: true, warning: false),
      .controlAccentColor)
  }

  /// A warning about a source that is switched off is noise. "No microphone"
  /// is the first-run default, so an ungated warning would fire on a brand-new
  /// install and teach the user to ignore the real one.
  func testDisabledSourceIsNeverWarned() {
    XCTAssertEqual(
      PreRecordingBarView.audioButtonTint(enabled: false, warning: true),
      .secondaryLabelColor)
    XCTAssertEqual(
      PreRecordingBarView.audioButtonTint(enabled: false, warning: false),
      .secondaryLabelColor)
  }

  /// The tint has to be distinguishable without hovering — that is the whole
  /// point of promoting this off the tooltip. Guard against someone "tidying"
  /// the warning colour back into the accent colour.
  func testWarningTintIsVisiblyDistinctFromBothOtherStates() {
    let warning = PreRecordingBarView.audioButtonTint(enabled: true, warning: true)
    XCTAssertNotEqual(warning, PreRecordingBarView.audioButtonTint(enabled: true, warning: false))
    XCTAssertNotEqual(warning, PreRecordingBarView.audioButtonTint(enabled: false, warning: true))
  }

  /// Both keys must exist on both sides of the bridge, or the bar silently
  /// renders a warning with no text.
  func testWarningStringKeysHaveNativeFallbacks() {
    let store = NativeStringsStore.shared
    let micTooLow = store.string(for: NativeUIStringKey.preRecordingBarMicTooLow)
    let bleed = store.string(for: NativeUIStringKey.preRecordingBarBleedRisk)

    XCTAssertFalse(micTooLow.isEmpty)
    XCTAssertFalse(bleed.isEmpty)
    // A missing key must not fall through to the raw key name.
    XCTAssertNotEqual(micTooLow, NativeUIStringKey.preRecordingBarMicTooLow)
    XCTAssertNotEqual(bleed, NativeUIStringKey.preRecordingBarBleedRisk)
    XCTAssertNotEqual(micTooLow, bleed)
  }

  // MARK: - Panel re-framing

  /// updateState runs on every state push. A live microphone pushes state
  /// many times a second, and an animated setFrame on an unchanged frame
  /// re-lays out a floating panel each time — which disturbs which window the
  /// window server considers key, and made in-app keyboard shortcuts stop
  /// responding.
  func testAnUnchangedFrameIsNotReapplied() {
    let frame = NSRect(x: 100, y: 200, width: 640, height: 64)
    XCTAssertTrue(PreRecordingBarController.framesAreEquivalent(frame, frame))
  }

  func testSubPointDifferencesDoNotCountAsAChange() {
    // Layout rounding produces these; treating them as real would animate the
    // panel forever.
    let a = NSRect(x: 100, y: 200, width: 640, height: 64)
    let b = NSRect(x: 100.2, y: 199.9, width: 640.3, height: 64)
    XCTAssertTrue(PreRecordingBarController.framesAreEquivalent(a, b))
  }

  /// A genuine content-width change — a button appearing or disappearing —
  /// must still re-frame, or the bar clips its own controls.
  func testARealWidthChangeStillCountsAsAChange() {
    let a = NSRect(x: 100, y: 200, width: 640, height: 64)
    let wider = NSRect(x: 100, y: 200, width: 700, height: 64)
    XCTAssertFalse(PreRecordingBarController.framesAreEquivalent(a, wider))

    let moved = NSRect(x: 140, y: 200, width: 640, height: 64)
    XCTAssertFalse(PreRecordingBarController.framesAreEquivalent(a, moved))
  }
}
