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
}
