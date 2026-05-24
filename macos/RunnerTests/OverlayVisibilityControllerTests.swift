import CoreGraphics
import XCTest

@testable import Clingfy

/// Slice 4 / PR 15 guard: the extracted overlay state + decision reproduces
/// the exact behavior of the inline `lastOverlayWindowID`,
/// `overlayUpdateDeduper`, and `overlayWindowIDForCapture(...)` previously
/// owned by `ScreenRecorderFacade`. Pure / deterministic; runs on the main
/// actor because the controller is `@MainActor`.
@MainActor
final class OverlayVisibilityControllerTests: XCTestCase {

  func testLastOverlayWindowIDStartsNilAndRoundTrips() {
    let sut = OverlayVisibilityController()
    XCTAssertNil(sut.lastOverlayWindowID)

    sut.setLastOverlayWindowID(42)
    XCTAssertEqual(sut.lastOverlayWindowID, 42)

    sut.setLastOverlayWindowID(nil)
    XCTAssertNil(sut.lastOverlayWindowID)
  }

  // MARK: - Dedup behavior

  func testFirstSendAlwaysFiresIncludingNil() {
    let sut = OverlayVisibilityController()
    XCTAssertTrue(sut.shouldSendOverlayUpdate(nil))

    let sut2 = OverlayVisibilityController()
    XCTAssertTrue(sut2.shouldSendOverlayUpdate(7))
  }

  func testRepeatedSameWindowIDIsDeduped() {
    let sut = OverlayVisibilityController()
    XCTAssertTrue(sut.shouldSendOverlayUpdate(11))
    XCTAssertFalse(sut.shouldSendOverlayUpdate(11))
    XCTAssertFalse(sut.shouldSendOverlayUpdate(11))
  }

  func testDifferentWindowIDFiresAfterDedup() {
    let sut = OverlayVisibilityController()
    XCTAssertTrue(sut.shouldSendOverlayUpdate(11))
    XCTAssertFalse(sut.shouldSendOverlayUpdate(11))
    XCTAssertTrue(sut.shouldSendOverlayUpdate(12))
    XCTAssertFalse(sut.shouldSendOverlayUpdate(12))
  }

  func testNilThenSameNilIsDeduped() {
    let sut = OverlayVisibilityController()
    XCTAssertTrue(sut.shouldSendOverlayUpdate(nil))
    XCTAssertFalse(sut.shouldSendOverlayUpdate(nil))
  }

  func testTransitionFromValueToNilFires() {
    let sut = OverlayVisibilityController()
    XCTAssertTrue(sut.shouldSendOverlayUpdate(99))
    XCTAssertTrue(sut.shouldSendOverlayUpdate(nil))
    XCTAssertFalse(sut.shouldSendOverlayUpdate(nil))
  }

  func testResetDeduperRearmsFirstSend() {
    let sut = OverlayVisibilityController()
    XCTAssertTrue(sut.shouldSendOverlayUpdate(5))
    XCTAssertFalse(sut.shouldSendOverlayUpdate(5))

    sut.resetDeduper()

    // After reset the very next send (even the same window ID) must fire again.
    XCTAssertTrue(sut.shouldSendOverlayUpdate(5))
  }

  // MARK: - overlayWindowIDForCapture decision matrix

  func testNoSeparateCameraAlwaysForwardsLiveOverlayID() {
    let sut = OverlayVisibilityController()

    XCTAssertEqual(
      sut.overlayWindowIDForCapture(
        liveOverlayWindowID: 77,
        shouldRecordSeparateCameraAsset: false,
        supportsLiveOverlayExclusionDuringSeparateCameraCapture: false),
      77)

    XCTAssertEqual(
      sut.overlayWindowIDForCapture(
        liveOverlayWindowID: 77,
        shouldRecordSeparateCameraAsset: false,
        supportsLiveOverlayExclusionDuringSeparateCameraCapture: true),
      77)

    XCTAssertNil(
      sut.overlayWindowIDForCapture(
        liveOverlayWindowID: nil,
        shouldRecordSeparateCameraAsset: false,
        supportsLiveOverlayExclusionDuringSeparateCameraCapture: false))
  }

  func testSeparateCameraWithoutLiveExclusionSuppressesOverlayID() {
    let sut = OverlayVisibilityController()
    XCTAssertNil(
      sut.overlayWindowIDForCapture(
        liveOverlayWindowID: 77,
        shouldRecordSeparateCameraAsset: true,
        supportsLiveOverlayExclusionDuringSeparateCameraCapture: false))

    // Even with a nil live ID we still return nil — same observable value.
    XCTAssertNil(
      sut.overlayWindowIDForCapture(
        liveOverlayWindowID: nil,
        shouldRecordSeparateCameraAsset: true,
        supportsLiveOverlayExclusionDuringSeparateCameraCapture: false))
  }

  func testSeparateCameraWithLiveExclusionForwardsOverlayID() {
    let sut = OverlayVisibilityController()

    XCTAssertEqual(
      sut.overlayWindowIDForCapture(
        liveOverlayWindowID: 77,
        shouldRecordSeparateCameraAsset: true,
        supportsLiveOverlayExclusionDuringSeparateCameraCapture: true),
      77)

    XCTAssertNil(
      sut.overlayWindowIDForCapture(
        liveOverlayWindowID: nil,
        shouldRecordSeparateCameraAsset: true,
        supportsLiveOverlayExclusionDuringSeparateCameraCapture: true))
  }
}
