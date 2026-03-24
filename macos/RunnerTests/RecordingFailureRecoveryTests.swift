import Foundation
import XCTest

@testable import Clingfy

final class RecordingFailureRecoveryTests: XCTestCase {
  func testCaptureDestinationUsesInProgressURLWhenSessionIsActive() {
    let session = RecordingFileSession(
      finalRawURL: URL(fileURLWithPath: "/tmp/final.mov"),
      inProgressRawURL: URL(fileURLWithPath: "/tmp/inprogress.mov")
    )

    XCTAssertEqual(
      CaptureDestinationDiagnostics.url(for: session).standardizedFileURL,
      session.inProgressRawURL.standardizedFileURL
    )
  }

  func testCaptureDestinationFallsBackToTempRootWhenIdle() {
    XCTAssertEqual(
      CaptureDestinationDiagnostics.url(for: nil).standardizedFileURL,
      AppPaths.tempRoot().standardizedFileURL
    )
  }

  func testPromotionPlanPrefersInProgressRawWhenPresent() {
    let session = RecordingFileSession(
      finalRawURL: URL(fileURLWithPath: "/tmp/final.mov"),
      inProgressRawURL: URL(fileURLWithPath: "/tmp/inprogress.mov")
    )
    let recordedRawURL = URL(fileURLWithPath: "/tmp/backend.mov")

    let plan = RecordingArtifactPromotionPlan.make(
      session: session,
      recordedRawURL: recordedRawURL,
      fileExists: { $0 == session.inProgressRawURL }
    )

    XCTAssertEqual(plan.sourceRawURL, session.inProgressRawURL)
    XCTAssertEqual(plan.finalRawURL, session.finalRawURL)
  }

  func testPromotionPlanFallsBackToRecordedRawWhenInProgressMissing() {
    let session = RecordingFileSession(
      finalRawURL: URL(fileURLWithPath: "/tmp/final.mov"),
      inProgressRawURL: URL(fileURLWithPath: "/tmp/inprogress.mov")
    )
    let recordedRawURL = URL(fileURLWithPath: "/tmp/backend.mov")

    let plan = RecordingArtifactPromotionPlan.make(
      session: session,
      recordedRawURL: recordedRawURL,
      fileExists: { _ in false }
    )

    XCTAssertEqual(plan.sourceRawURL, recordedRawURL)
    XCTAssertEqual(plan.finalRawURL, session.finalRawURL)
  }

  func testTerminalCompletionGuardSuppressesDuplicatesUntilReset() {
    var guardState = TerminalCompletionGuard()

    XCTAssertTrue(guardState.beginCompletion())
    XCTAssertFalse(guardState.beginCompletion())

    guardState.reset()

    XCTAssertTrue(guardState.beginCompletion())
  }
}
