import CoreGraphics
import XCTest

@testable import Clingfy

/// Slice 5 / PR 20 guard: the two preflight clusters extracted into
/// `RecordingSessionCoordinator` reproduce the exact truth table of the
/// inline gates that used to live in `ScreenRecorderFacade.startRecording`
/// (Slice 3 / PR 14's pure helpers + Slice 3 / PR 12's target resolver).
@MainActor
final class RecordingSessionCoordinatorTests: XCTestCase {

  // MARK: - Display-service stub

  /// Stub `CaptureDisplayResolving` driven by closures so each test can
  /// dictate exactly what the target resolver sees.
  private final class StubDisplayResolver: CaptureDisplayResolving {
    var displayIDForAppWindowOrMainResult: CGDirectDisplayID = 1
    var displayIDUnderMouseResult: CGDirectDisplayID? = 1
    var captureTargetForWindowIDResult: (displayID: CGDirectDisplayID, rect: CGRect)? = nil

    func displayIDForAppWindowOrMain() -> CGDirectDisplayID {
      displayIDForAppWindowOrMainResult
    }
    func displayIDUnderMouse() -> CGDirectDisplayID? {
      displayIDUnderMouseResult
    }
    func captureTarget(forWindowID id: CGWindowID) -> (
      displayID: CGDirectDisplayID, rect: CGRect
    )? {
      captureTargetForWindowIDResult
    }
  }

  private func makeCoordinator() -> RecordingSessionCoordinator {
    RecordingSessionCoordinator(captureTargetResolver: CaptureTargetResolver())
  }

  private func explicitIDInput(displayID: CGDirectDisplayID = 1)
    -> CaptureTargetResolver.Input
  {
    .init(
      displayMode: .explicitID, selectedDisplayID: displayID,
      selectedAppWindowID: nil, areaRect: nil, areaDisplayId: nil)
  }

  // MARK: - Cluster 1: screen permission + capture-target resolution

  func testFailsImmediatelyWhenScreenPermissionDenied() {
    let coord = makeCoordinator()
    let outcome = coord.evaluateScreenPermissionAndTarget(
      screenRecordingSatisfied: { false },
      captureTargetInput: explicitIDInput(),
      displayService: StubDisplayResolver())

    XCTAssertEqual(outcome, .fail(errorCode: NativeErrorCode.screenRecordingPermission))
  }

  func testProceedsWithResolvedTargetWhenScreenPermissionGranted() {
    let coord = makeCoordinator()
    let outcome = coord.evaluateScreenPermissionAndTarget(
      screenRecordingSatisfied: { true },
      captureTargetInput: explicitIDInput(displayID: 42),
      displayService: StubDisplayResolver())

    switch outcome {
    case .proceed(let target):
      XCTAssertEqual(target.displayID, 42)
      XCTAssertEqual(target.mode, .explicitID)
    case .fail(let code):
      XCTFail("expected .proceed, got .fail(\(code))")
    }
  }

  func testMapsNoWindowSelectedToNoWindowSelectedCode() {
    let coord = makeCoordinator()
    let outcome = coord.evaluateScreenPermissionAndTarget(
      screenRecordingSatisfied: { true },
      captureTargetInput: .init(
        displayMode: .singleAppWindow, selectedDisplayID: nil,
        selectedAppWindowID: nil, areaRect: nil, areaDisplayId: nil),
      displayService: StubDisplayResolver())

    XCTAssertEqual(outcome, .fail(errorCode: NativeErrorCode.noWindowSelected))
  }

  func testMapsWindowUnavailableToWindowNotAvailableCode() {
    let coord = makeCoordinator()
    let stub = StubDisplayResolver()
    stub.captureTargetForWindowIDResult = nil  // window vanished
    let outcome = coord.evaluateScreenPermissionAndTarget(
      screenRecordingSatisfied: { true },
      captureTargetInput: .init(
        displayMode: .singleAppWindow, selectedDisplayID: nil,
        selectedAppWindowID: 999, areaRect: nil, areaDisplayId: nil),
      displayService: stub)

    XCTAssertEqual(outcome, .fail(errorCode: NativeErrorCode.windowNotAvailable))
  }

  func testMapsNoAreaSelectedToNoAreaSelectedCode() {
    let coord = makeCoordinator()
    let outcome = coord.evaluateScreenPermissionAndTarget(
      screenRecordingSatisfied: { true },
      captureTargetInput: .init(
        displayMode: .areaRecording, selectedDisplayID: nil,
        selectedAppWindowID: nil, areaRect: nil, areaDisplayId: nil),
      displayService: StubDisplayResolver())

    XCTAssertEqual(outcome, .fail(errorCode: NativeErrorCode.noAreaSelected))
  }

  // MARK: - Cluster 2: microphone + accessibility preflight

  private var anyTarget: CaptureTarget {
    CaptureTarget(mode: .explicitID, displayID: 1, cropRect: nil, windowID: nil)
  }

  func testMicAndAccessibilityProceedsOnHappyPath() {
    let coord = makeCoordinator()
    let outcome = coord.evaluateMicAndAccessibility(
      target: anyTarget,
      sessionDisableMicrophone: false,
      audioDeviceId: nil,  // no mic selected ⇒ no auth required
      audioAuthorized: false,
      cursorEnabledForRecording: false,
      cursorLinked: false,
      accessibilityAllowed: true)

    if case .proceed(let echoed) = outcome {
      XCTAssertEqual(echoed.displayID, 1)
    } else {
      XCTFail("expected .proceed, got \(outcome)")
    }
  }

  func testMicFailureIsReturnedBeforeAccessibility() {
    let coord = makeCoordinator()
    // Both gates would fail: real mic selected + unauthorized,
    // AND accessibility-blocking config. Mic wins as the first failure.
    let outcome = coord.evaluateMicAndAccessibility(
      target: anyTarget,
      sessionDisableMicrophone: false,
      audioDeviceId: "mic-1",
      audioAuthorized: false,
      cursorEnabledForRecording: true,
      cursorLinked: true,
      accessibilityAllowed: false)

    XCTAssertEqual(outcome, .fail(errorCode: NativeErrorCode.microphonePermissionRequired))
  }

  func testAccessibilityFailureSurfacesWhenMicPasses() {
    let coord = makeCoordinator()
    let outcome = coord.evaluateMicAndAccessibility(
      target: anyTarget,
      sessionDisableMicrophone: true,  // mic gate satisfied
      audioDeviceId: "mic-1",
      audioAuthorized: false,
      cursorEnabledForRecording: true,
      cursorLinked: true,
      accessibilityAllowed: false)

    XCTAssertEqual(outcome, .fail(errorCode: NativeErrorCode.accessibilityPermissionRequired))
  }

  func testNoMicSelectedSkipsMicGateRegardlessOfAuth() {
    let coord = makeCoordinator()
    for sentinel in [nil, "", "__none__"] as [String?] {
      let outcome = coord.evaluateMicAndAccessibility(
        target: anyTarget,
        sessionDisableMicrophone: false,
        audioDeviceId: sentinel,
        audioAuthorized: false,
        cursorEnabledForRecording: false,
        cursorLinked: false,
        accessibilityAllowed: true)

      if case .proceed = outcome { /* ok */ } else {
        XCTFail("expected .proceed for audioDeviceId=\(sentinel ?? "nil"), got \(outcome)")
      }
    }
  }
}
