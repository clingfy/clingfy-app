import CoreGraphics
import XCTest

@testable import Clingfy

/// PR 12 guard: CaptureTargetResolver reproduces the exact per-DisplayTargetMode
/// behavior of the old inline ScreenRecorderFacade.resolveCaptureTarget(),
/// including every throw. Pure / deterministic via a fake display seam.
final class CaptureTargetResolverTests: XCTestCase {
  private struct FakeDisplays: CaptureDisplayResolving {
    var appWindowOrMain: CGDirectDisplayID = 11
    var underMouse: CGDirectDisplayID? = 22
    var windowTarget: (displayID: CGDirectDisplayID, rect: CGRect)? = (
      33, CGRect(x: 5, y: 6, width: 100, height: 200)
    )
    func displayIDForAppWindowOrMain() -> CGDirectDisplayID { appWindowOrMain }
    func displayIDUnderMouse() -> CGDirectDisplayID? { underMouse }
    func captureTarget(forWindowID id: CGWindowID)
      -> (displayID: CGDirectDisplayID, rect: CGRect)?
    { windowTarget }
  }

  private let resolver = CaptureTargetResolver()

  private func input(
    _ mode: DisplayTargetMode,
    displayID: CGDirectDisplayID? = nil,
    windowID: CGWindowID? = nil,
    areaRect: CGRect? = nil,
    areaDisplayId: Int? = nil
  ) -> CaptureTargetResolver.Input {
    .init(
      displayMode: mode, selectedDisplayID: displayID, selectedAppWindowID: windowID,
      areaRect: areaRect, areaDisplayId: areaDisplayId)
  }

  func testExplicitIDUsesSelectedThenFallsBack() throws {
    let a = try resolver.resolve(input(.explicitID, displayID: 99), displayService: FakeDisplays())
    XCTAssertEqual(a, CaptureTarget(mode: .explicitID, displayID: 99, cropRect: nil, windowID: nil))

    let b = try resolver.resolve(input(.explicitID), displayService: FakeDisplays())
    XCTAssertEqual(b, CaptureTarget(mode: .explicitID, displayID: 11, cropRect: nil, windowID: nil))
  }

  func testAppWindowUsesAppWindowOrMain() throws {
    let t = try resolver.resolve(input(.appWindow), displayService: FakeDisplays())
    XCTAssertEqual(t, CaptureTarget(mode: .appWindow, displayID: 11, cropRect: nil, windowID: nil))
  }

  func testMouseModesUseUnderMouseThenFallback() throws {
    let t = try resolver.resolve(input(.mouseAtStart), displayService: FakeDisplays())
    XCTAssertEqual(
      t, CaptureTarget(mode: .mouseAtStart, displayID: 22, cropRect: nil, windowID: nil))

    let follow = try resolver.resolve(input(.followMouse), displayService: FakeDisplays())
    XCTAssertEqual(
      follow, CaptureTarget(mode: .mouseAtStart, displayID: 22, cropRect: nil, windowID: nil))

    var noMouse = FakeDisplays()
    noMouse.underMouse = nil
    let fb = try resolver.resolve(input(.mouseAtStart), displayService: noMouse)
    XCTAssertEqual(
      fb, CaptureTarget(mode: .mouseAtStart, displayID: 11, cropRect: nil, windowID: nil))
  }

  func testSingleAppWindowThrowsWhenNoWindowSelected() {
    XCTAssertThrowsError(
      try resolver.resolve(input(.singleAppWindow), displayService: FakeDisplays())
    ) { XCTAssertEqual($0 as? CaptureTargetError, .noWindowSelected) }
  }

  func testSingleAppWindowThrowsWhenWindowUnavailable() {
    var unavailable = FakeDisplays()
    unavailable.windowTarget = nil
    XCTAssertThrowsError(
      try resolver.resolve(input(.singleAppWindow, windowID: 7), displayService: unavailable)
    ) { XCTAssertEqual($0 as? CaptureTargetError, .windowUnavailable) }
  }

  func testSingleAppWindowResolvesConfig() throws {
    let t = try resolver.resolve(input(.singleAppWindow, windowID: 7), displayService: FakeDisplays())
    XCTAssertEqual(
      t,
      CaptureTarget(
        mode: .singleAppWindow, displayID: 33,
        cropRect: CGRect(x: 5, y: 6, width: 100, height: 200), windowID: 7))
  }

  func testAreaRecordingThrowsWhenIncomplete() {
    XCTAssertThrowsError(
      try resolver.resolve(input(.areaRecording, areaRect: .zero), displayService: FakeDisplays())
    ) { XCTAssertEqual($0 as? CaptureTargetError, .noAreaSelected) }
    XCTAssertThrowsError(
      try resolver.resolve(input(.areaRecording, areaDisplayId: 1), displayService: FakeDisplays())
    ) { XCTAssertEqual($0 as? CaptureTargetError, .noAreaSelected) }
  }

  func testAreaRecordingResolves() throws {
    let rect = CGRect(x: 1, y: 2, width: 640, height: 480)
    let t = try resolver.resolve(
      input(.areaRecording, areaRect: rect, areaDisplayId: 5), displayService: FakeDisplays())
    XCTAssertEqual(
      t, CaptureTarget(mode: .areaRecording, displayID: 5, cropRect: rect, windowID: nil))
  }
}
