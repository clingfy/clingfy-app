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

  func testStorageInfoProviderSnapshotCarriesThresholdsAndPaths() {
    let snapshot = StorageInfoProvider.buildSnapshot(
      captureDestinationURL: AppPaths.tempRoot(),
      recordingsURL: AppPaths.recordingsRoot(),
      tempURL: AppPaths.tempRoot(),
      logsURL: AppPaths.logsRoot()
    )

    XCTAssertEqual(snapshot.warningThresholdBytes, StorageInfoProvider.warningThresholdBytes)
    XCTAssertEqual(snapshot.criticalThresholdBytes, StorageInfoProvider.criticalThresholdBytes)
    XCTAssertEqual(snapshot.recordingsPath, AppPaths.recordingsRoot().path)
    XCTAssertEqual(snapshot.tempPath, AppPaths.tempRoot().path)
    XCTAssertEqual(snapshot.logsPath, AppPaths.logsRoot().path)
  }

  func testStorageInfoProviderDirectorySizeReturnsZeroForMissingDirectory() {
    let missingURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent(UUID().uuidString, isDirectory: true)

    XCTAssertEqual(StorageInfoProvider.directorySize(missingURL), 0)
  }

  func testStorageInfoProviderBuildSnapshotAggregatesRecordingTempAndLogs() throws {
    let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let recordingsURL = rootURL.appendingPathComponent("recordings", isDirectory: true)
    let tempURL = rootURL.appendingPathComponent("temp", isDirectory: true)
    let logsURL = rootURL.appendingPathComponent("logs", isDirectory: true)
    let fileManager = FileManager.default

    try fileManager.createDirectory(at: recordingsURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: tempURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: logsURL, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: rootURL) }

    let recordingsData = Data("recordings".utf8)
    let tempData = Data("temp".utf8)
    let logsData = Data("logs".utf8)

    try recordingsData.write(to: recordingsURL.appendingPathComponent("a.mov"))
    try tempData.write(to: tempURL.appendingPathComponent("b.mov"))
    try logsData.write(to: logsURL.appendingPathComponent("c.jsonl"))

    let snapshot = StorageInfoProvider.buildSnapshot(
      captureDestinationURL: tempURL,
      recordingsURL: recordingsURL,
      tempURL: tempURL,
      logsURL: logsURL
    )

    XCTAssertGreaterThan(snapshot.systemTotalBytes, 0)
    XCTAssertGreaterThan(snapshot.systemAvailableBytes, 0)
    XCTAssertGreaterThanOrEqual(snapshot.recordingsBytes, Int64(recordingsData.count))
    XCTAssertGreaterThanOrEqual(snapshot.tempBytes, Int64(tempData.count))
    XCTAssertGreaterThanOrEqual(snapshot.logsBytes, Int64(logsData.count))
  }

  func testRecordingStoreDeleteAllOnlyRemovesFilesFromRecordingsWorkspace() throws {
    let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let recordingsURL = rootURL.appendingPathComponent("recordings", isDirectory: true)
    let tempURL = rootURL.appendingPathComponent("temp", isDirectory: true)
    let logsURL = rootURL.appendingPathComponent("logs", isDirectory: true)
    let fileManager = FileManager.default

    try fileManager.createDirectory(at: recordingsURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: tempURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: logsURL, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: rootURL) }

    let rawURL = recordingsURL.appendingPathComponent("clip.mov")
    let cursorURL = AppPaths.cursorSidecarURL(for: rawURL)
    let metaURL = AppPaths.metadataSidecarURL(for: rawURL)
    let tempArtifactURL = tempURL.appendingPathComponent("capture.inprogress.mov")
    let logURL = logsURL.appendingPathComponent("logs_2026-03-25.jsonl")

    try Data("raw".utf8).write(to: rawURL)
    try Data("cursor".utf8).write(to: cursorURL)
    try Data("meta".utf8).write(to: metaURL)
    try Data("temp".utf8).write(to: tempArtifactURL)
    try Data("log".utf8).write(to: logURL)

    let store = RecordingStore(rootURL: recordingsURL, fileManager: fileManager)
    let deletedCount = store.deleteAll()

    XCTAssertEqual(deletedCount, 1)
    XCTAssertFalse(fileManager.fileExists(atPath: rawURL.path))
    XCTAssertFalse(fileManager.fileExists(atPath: cursorURL.path))
    XCTAssertFalse(fileManager.fileExists(atPath: metaURL.path))
    XCTAssertTrue(fileManager.fileExists(atPath: tempArtifactURL.path))
    XCTAssertTrue(fileManager.fileExists(atPath: logURL.path))
  }

  func testCachedRecordingsCleanupPolicyAllowsOnlyIdleState() {
    XCTAssertTrue(CachedRecordingsCleanupPolicy.canClear(recorderState: .idle))
    XCTAssertFalse(CachedRecordingsCleanupPolicy.canClear(recorderState: .starting))
    XCTAssertFalse(CachedRecordingsCleanupPolicy.canClear(recorderState: .recording))
    XCTAssertFalse(CachedRecordingsCleanupPolicy.canClear(recorderState: .stopping))
  }

  func testCaptureDestinationPreflightBypassAllowedForNonProductionBuilds() {
    XCTAssertTrue(
      CaptureDestinationPreflightPolicy.shouldBypassLowStorageCheck(
        requested: true,
        bundleIdentifier: "com.clingfy.clingfy.dev",
        isDebugBuild: false
      )
    )

    XCTAssertEqual(
      CaptureDestinationPreflightPolicy.decision(
        availableBytes: 0,
        requestedBypass: true,
        bundleIdentifier: "com.clingfy.clingfy.dev",
        isDebugBuild: false
      ),
      .proceed
    )
  }

  func testCaptureDestinationPreflightBypassIgnoredInProductionBuilds() {
    XCTAssertFalse(
      CaptureDestinationPreflightPolicy.shouldBypassLowStorageCheck(
        requested: true,
        bundleIdentifier: "com.clingfy.clingfy",
        isDebugBuild: false
      )
    )

    XCTAssertEqual(
      CaptureDestinationPreflightPolicy.decision(
        availableBytes: 5 * 1024 * 1024 * 1024,
        requestedBypass: true,
        bundleIdentifier: "com.clingfy.clingfy",
        isDebugBuild: false
      ),
      .belowCriticalThreshold
    )
  }
}
