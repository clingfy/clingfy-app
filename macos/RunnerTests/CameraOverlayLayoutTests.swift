import Cocoa
import XCTest

@testable import Clingfy

final class CameraOverlayLayoutTests: XCTestCase {
  private let screenFrame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
  private let visibleFrame = CGRect(x: 24, y: 48, width: 1500, height: 920)
  private let contentSize: CGFloat = 220
  private let effectPadding: CGFloat = 50
  private let accuracy: CGFloat = 0.001

  func testPresetPlacementFrameUsesPhysicalTopAndVisibleWorkAreaSides() {
    let placementFrame = cameraOverlayPresetPlacementFrame(
      screenFrame: screenFrame,
      visibleFrame: visibleFrame
    )

    XCTAssertEqual(placementFrame.minX, visibleFrame.minX, accuracy: accuracy)
    XCTAssertEqual(placementFrame.maxX, visibleFrame.maxX, accuracy: accuracy)
    XCTAssertEqual(placementFrame.minY, visibleFrame.minY, accuracy: accuracy)
    XCTAssertEqual(placementFrame.maxY, screenFrame.maxY, accuracy: accuracy)
  }

  func testPresetOriginsAlignVisibleContentToExpectedEdges() {
    let topLeftInsets = insets(for: visibleRect(for: 0))
    XCTAssertEqual(topLeftInsets.top, padding, accuracy: accuracy)
    XCTAssertEqual(topLeftInsets.left, padding, accuracy: accuracy)

    let topRightInsets = insets(for: visibleRect(for: 1))
    XCTAssertEqual(topRightInsets.top, padding, accuracy: accuracy)
    XCTAssertEqual(topRightInsets.right, padding, accuracy: accuracy)

    let bottomLeftInsets = insets(for: visibleRect(for: 2))
    XCTAssertEqual(bottomLeftInsets.bottom, padding, accuracy: accuracy)
    XCTAssertEqual(bottomLeftInsets.left, padding, accuracy: accuracy)

    let bottomRightInsets = insets(for: visibleRect(for: 3))
    XCTAssertEqual(bottomRightInsets.bottom, padding, accuracy: accuracy)
    XCTAssertEqual(bottomRightInsets.right, padding, accuracy: accuracy)
  }

  func testPresetOriginsKeepInsetsSymmetricAcrossComparableEdges() {
    let topLeftInsets = insets(for: visibleRect(for: 0))
    let topRightInsets = insets(for: visibleRect(for: 1))
    let bottomLeftInsets = insets(for: visibleRect(for: 2))
    let bottomRightInsets = insets(for: visibleRect(for: 3))

    XCTAssertEqual(topLeftInsets.top, topRightInsets.top, accuracy: accuracy)
    XCTAssertEqual(bottomLeftInsets.bottom, bottomRightInsets.bottom, accuracy: accuracy)
    XCTAssertEqual(topLeftInsets.left, topRightInsets.right, accuracy: accuracy)
    XCTAssertEqual(bottomLeftInsets.left, bottomRightInsets.right, accuracy: accuracy)
  }

  private func visibleRect(for preset: Int) -> CGRect {
    let placementFrame = cameraOverlayPresetPlacementFrame(
      screenFrame: screenFrame,
      visibleFrame: visibleFrame
    )
    let origin = cameraOverlayPresetOrigin(
      for: preset,
      contentSize: contentSize,
      effectPadding: effectPadding,
      screenFrame: placementFrame
    )

    return CGRect(
      x: origin.x + effectPadding,
      y: origin.y + effectPadding,
      width: contentSize,
      height: contentSize
    )
  }

  private func insets(for visibleRect: CGRect) -> (top: CGFloat, right: CGFloat, bottom: CGFloat, left: CGFloat) {
    (
      top: screenFrame.maxY - visibleRect.maxY,
      right: visibleFrame.maxX - visibleRect.maxX,
      bottom: visibleRect.minY - visibleFrame.minY,
      left: visibleRect.minX - visibleFrame.minX
    )
  }
}
