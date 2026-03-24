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

  func testRecordingArtifactPromoterMovesRawAndSidecarsToFinalRecording() throws {
    let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: rootURL) }

    let session = RecordingFileSession(
      finalRawURL: rootURL.appendingPathComponent("final.mov"),
      inProgressRawURL: rootURL.appendingPathComponent("temp.inprogress.mov")
    )
    let recordedRawURL = rootURL.appendingPathComponent("backend.mov")

    try Data("raw".utf8).write(to: session.inProgressRawURL)
    try Data("cursor".utf8).write(to: AppPaths.cursorSidecarURL(for: session.inProgressRawURL))
    try Data("meta".utf8).write(to: AppPaths.metadataSidecarURL(for: session.inProgressRawURL))

    let promotedURL = try RecordingArtifactPromoter.promote(
      session: session,
      recordedRawURL: recordedRawURL,
      fileManager: fileManager
    )

    XCTAssertEqual(promotedURL.standardizedFileURL, session.finalRawURL.standardizedFileURL)
    XCTAssertTrue(fileManager.fileExists(atPath: session.finalRawURL.path))
    XCTAssertTrue(fileManager.fileExists(atPath: AppPaths.cursorSidecarURL(for: session.finalRawURL).path))
    XCTAssertTrue(fileManager.fileExists(atPath: AppPaths.metadataSidecarURL(for: session.finalRawURL).path))
    XCTAssertFalse(fileManager.fileExists(atPath: session.inProgressRawURL.path))
    XCTAssertFalse(
      fileManager.fileExists(atPath: AppPaths.cursorSidecarURL(for: session.inProgressRawURL).path)
    )
    XCTAssertFalse(
      fileManager.fileExists(
        atPath: AppPaths.metadataSidecarURL(for: session.inProgressRawURL).path
      )
    )
  }

  func testTerminalCompletionGuardSuppressesDuplicatesUntilReset() {
    var guardState = TerminalCompletionGuard()

    XCTAssertTrue(guardState.beginCompletion())
    XCTAssertFalse(guardState.beginCompletion())

    guardState.reset()

    XCTAssertTrue(guardState.beginCompletion())
  }

  func testCursorFailurePlanFlushesWhenCursorCaptureIsActiveAndURLExists() {
    let recordingURL = URL(fileURLWithPath: "/tmp/recording.inprogress.mov")

    let plan = CursorFailureFinalizationPlan.make(
      recordingURL: recordingURL,
      cursorCaptureActive: true
    )

    XCTAssertTrue(plan.shouldFlushCursor)
    XCTAssertEqual(plan.cursorURL, AppPaths.cursorSidecarURL(for: recordingURL))
  }

  func testCursorFailurePlanSkipsFlushWithoutURLOrInactiveCursorCapture() {
    let inactivePlan = CursorFailureFinalizationPlan.make(
      recordingURL: URL(fileURLWithPath: "/tmp/recording.inprogress.mov"),
      cursorCaptureActive: false
    )
    let nilURLPlan = CursorFailureFinalizationPlan.make(
      recordingURL: nil,
      cursorCaptureActive: true
    )

    XCTAssertFalse(inactivePlan.shouldFlushCursor)
    XCTAssertFalse(nilURLPlan.shouldFlushCursor)
    XCTAssertNil(nilURLPlan.cursorURL)
  }

  func testCursorRecorderStopWithoutStartDoesNotCreateSidecar() {
    let recorder = CursorRecorder()
    let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("cursor.json")
    let completion = expectation(description: "cursor stop completion")

    recorder.stop(outputURL: outputURL) {
      completion.fulfill()
    }

    wait(for: [completion], timeout: 1.0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
  }

  func testCursorRecordingWriterCompletesAfterSidecarExists() {
    let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("cursor.json")
    let recording = CursorRecording(
      sprites: [],
      frames: [CursorFrame(t: 0.0, x: 0.5, y: 0.25, spriteID: -1)]
    )
    let completion = expectation(description: "cursor writer completion")

    CursorRecordingWriter.write(
      recording: recording,
      to: outputURL,
      queue: DispatchQueue(label: "test.cursor.writer")
    ) {
      XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

      do {
        let data = try Data(contentsOf: outputURL)
        let decoded = try JSONDecoder().decode(CursorRecording.self, from: data)
        XCTAssertEqual(decoded.frames.count, 1)
      } catch {
        XCTFail("Expected cursor sidecar to be readable before completion: \(error)")
      }

      try? FileManager.default.removeItem(at: outputURL)
      completion.fulfill()
    }

    wait(for: [completion], timeout: 1.0)
  }
}
