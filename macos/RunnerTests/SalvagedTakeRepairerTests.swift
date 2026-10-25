import AVFoundation
import XCTest

@testable import Clingfy

/// The repair that joins, at a later launch, the parts of a paused take that
/// could not be joined when it stopped.
final class SalvagedTakeRepairerTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("repair-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    SalvagedTakeRepairSweep.shared._testReset()
  }

  override func tearDownWithError() throws {
    SalvagedTakeRepairSweep.shared._testReset()
    try? FileManager.default.removeItem(at: root)
  }

  // MARK: - Screen

  /// The common case: part 1 was published alone, part 2 was set aside. The
  /// repair joins them, and the cursor, the audio and the metadata follow.
  func testASalvagedTakeIsJoinedWithItsCursorAndAudio() async throws {
    let project = try makeProject()
    let capture = RecordingProjectPaths.captureDirectoryURL(for: project)
    try writeMovie(RecordingProjectPaths.screenVideoURL(for: project), seconds: 1)
    try writeMovie(capture.appendingPathComponent("screen.segment-002.mov"), seconds: 1)
    try writeCursor(RecordingProjectPaths.cursorDataURL(for: project), times: [0.1])
    try writeCursor(capture.appendingPathComponent("screen.segment-002.cursor.json"), times: [0.2])
    try writeTone(RecordingProjectPaths.micAudioURL(for: project), seconds: 1)
    try writeTone(capture.appendingPathComponent("mic.segment-002.m4a"), seconds: 1)
    try writeScreenMetadata(project, segments: [segment(1, start: 0, seconds: 1)])
    try writeScreenManifest(
      project, published: 1,
      records: [
        record(1, start: 0, seconds: 1, cursor: true, mic: true),
        record(2, start: 2, seconds: 1, cursor: true, mic: true),
      ])
    try setStatus(project, .ready)

    let outcome = await repairer().repair(projectRoot: project)

    XCTAssertEqual(outcome, .repaired)
    XCTAssertEqual(duration(RecordingProjectPaths.screenVideoURL(for: project)), 2, accuracy: 0.1)
    XCTAssertEqual(duration(RecordingProjectPaths.micAudioURL(for: project)), 2, accuracy: 0.15)
    let cursor = try JSONDecoder().decode(
      CursorRecording.self, from: Data(contentsOf: RecordingProjectPaths.cursorDataURL(for: project)))
    XCTAssertEqual(cursor.frames.map(\.t)[0], 0.1, accuracy: 0.001)
    XCTAssertEqual(cursor.frames.map(\.t)[1], 1.2, accuracy: 0.05, "part 2 starts after part 1")

    let metadata = try RecordingMetadata.read(
      from: RecordingProjectPaths.screenMetadataURL(for: project))
    XCTAssertEqual(metadata.screen.segments.map(\.index), [1, 2])
    XCTAssertEqual(
      metadata.screen.segments.map(\.relativePath),
      ["screen.segment-001.mov", "screen.segment-002.mov"])
    XCTAssertEqual(metadata.endedAt, iso(3), "the take ends where its last part does")

    for name in [
      "screen.segment-002.mov", "screen.segment-002.cursor.json", "mic.segment-002.m4a",
      RecordingSegmentMerger.unmergedManifestName,
    ] {
      XCTAssertFalse(exists(capture.appendingPathComponent(name)), "\(name) should be gone")
    }
    XCTAssertFalse(exists(SalvagedTakeRepairer.stagingURL(for: project)))
    XCTAssertEqual(try status(project), .ready)
    XCTAssertFalse(repairer().needsRepair(projectRoot: project))
  }

  /// Every preset failed and nothing was published: the take finished
  /// failed, with no screen.mov. The repair gives it one.
  func testATakeWithNothingPublishedGetsItsScreenBack() async throws {
    let project = try makeProject()
    let capture = RecordingProjectPaths.captureDirectoryURL(for: project)
    try writeMovie(capture.appendingPathComponent("screen.segment-001.mov"), seconds: 1)
    try writeMovie(capture.appendingPathComponent("screen.segment-002.mov"), seconds: 1)
    try writeScreenMetadata(project, segments: [])
    try writeScreenManifest(
      project, published: nil,
      records: [record(1, start: 0, seconds: 1), record(2, start: 2, seconds: 1)])
    try setStatus(project, .failed)

    let outcome = await repairer().repair(projectRoot: project)

    XCTAssertEqual(outcome, .repaired)
    XCTAssertEqual(duration(RecordingProjectPaths.screenVideoURL(for: project)), 2, accuracy: 0.1)
    XCTAssertEqual(try status(project), .ready)
  }

  /// A part that cannot be read is left out of the join, and left on disk.
  func testAPartThatCannotBeReadIsLeftOutAndKept() async throws {
    let project = try makeProject()
    let capture = RecordingProjectPaths.captureDirectoryURL(for: project)
    try writeMovie(RecordingProjectPaths.screenVideoURL(for: project), seconds: 1)
    let broken = capture.appendingPathComponent("screen.segment-002.mov")
    try Data("not a movie".utf8).write(to: broken)
    try writeMovie(capture.appendingPathComponent("screen.segment-003.mov"), seconds: 1)
    try writeScreenMetadata(project, segments: [segment(1, start: 0, seconds: 1)])
    try writeScreenManifest(
      project, published: 1,
      records: [
        record(1, start: 0, seconds: 1), record(2, start: 2, seconds: 1),
        record(3, start: 4, seconds: 1),
      ])

    let outcome = await repairer().repair(projectRoot: project)

    XCTAssertEqual(outcome, .repaired)
    XCTAssertEqual(duration(RecordingProjectPaths.screenVideoURL(for: project)), 2, accuracy: 0.1)
    let metadata = try RecordingMetadata.read(
      from: RecordingProjectPaths.screenMetadataURL(for: project))
    XCTAssertEqual(metadata.screen.segments.map(\.index), [1, 3])
    XCTAssertTrue(exists(broken), "a part left out is not the repair's to delete")
    let manifest = try json(SalvagedTakeRepairer.screenManifestURL(for: project))
    let repair = try XCTUnwrap(manifest["repair"] as? [String: Any])
    XCTAssertNotNil(repair["joinedAt"], "the manifest still lists the part it left")
    XCTAssertEqual(repair["leftOut"] as? [String], ["screen.segment-002.mov"])
    XCTAssertFalse(repairer().needsRepair(projectRoot: project), "and is not retried")
  }

  /// A part before the published one is one the stop could not play alone.
  /// Joined in front, it would shift every edit made on the published part.
  func testAPartBeforeThePublishedOneStaysOut() async throws {
    let project = try makeProject()
    let capture = RecordingProjectPaths.captureDirectoryURL(for: project)
    let earlier = capture.appendingPathComponent("screen.segment-001.mov")
    try writeMovie(earlier, seconds: 1)
    try writeMovie(RecordingProjectPaths.screenVideoURL(for: project), seconds: 1)
    try writeMovie(capture.appendingPathComponent("screen.segment-003.mov"), seconds: 1)
    try writeScreenMetadata(project, segments: [segment(2, start: 2, seconds: 1)])
    try writeScreenManifest(
      project, published: 2,
      records: [
        record(1, start: 0, seconds: 1), record(2, start: 2, seconds: 1),
        record(3, start: 4, seconds: 1),
      ])

    let outcome = await repairer().repair(projectRoot: project)

    XCTAssertEqual(outcome, .repaired)
    let metadata = try RecordingMetadata.read(
      from: RecordingProjectPaths.screenMetadataURL(for: project))
    XCTAssertEqual(metadata.screen.segments.map(\.index), [2, 3])
    XCTAssertTrue(exists(earlier))
  }

  /// A file that cannot be moved into place stops the commit before any
  /// part is deleted, and the plan waits for the next launch.
  func testAFailedMoveStopsTheCommitBeforeAnythingIsDeleted() async throws {
    let project = try makeProject()
    let staging = SalvagedTakeRepairer.stagingURL(for: project)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    try writeMovie(staging.appendingPathComponent("screen.mov"), seconds: 2)
    let part = RecordingProjectPaths.captureDirectoryURL(for: project)
      .appendingPathComponent("screen.segment-002.mov")
    try Data("part".utf8).write(to: part)
    let plan: [String: Any] = [
      "version": 1,
      "moves": [["from": ".repair/screen.mov", "to": "no-such-folder/screen.mov"]],
      "deletes": ["capture/screen.segment-002.mov"],
      "camera": "keep", "markReady": false, "outcome": "repaired",
    ]
    try JSONSerialization.data(withJSONObject: plan).write(
      to: SalvagedTakeRepairer.commitURL(for: project))

    let outcome = await repairer().repair(projectRoot: project)

    guard case .failed = outcome else { return XCTFail("the commit cannot have landed") }
    XCTAssertTrue(exists(part), "nothing is deleted before every file is in place")
    XCTAssertTrue(exists(SalvagedTakeRepairer.commitURL(for: project)), "the plan is kept")
    XCTAssertTrue(repairer().needsRepair(projectRoot: project))
  }

  /// A failure can be reproducible: three attempts, then it stops, until a
  /// new version of the app gets one more.
  func testAttemptsStopAtTheCap() async throws {
    let project = try makeProject()
    let capture = RecordingProjectPaths.captureDirectoryURL(for: project)
    try writeMovie(RecordingProjectPaths.screenVideoURL(for: project), seconds: 1)
    try writeMovie(capture.appendingPathComponent("screen.segment-002.mov"), seconds: 1)
    try writeScreenMetadata(project, segments: [segment(1, start: 0, seconds: 1)])
    try writeScreenManifest(
      project, published: 1, records: [record(1, start: 0, seconds: 1), record(2, start: 2, seconds: 1)])
    let failing = repairer(screenPresets: ["NotAnExportPreset"])

    for _ in 0..<SalvagedTakeRepairer.maxAttempts {
      XCTAssertTrue(failing.needsRepair(projectRoot: project))
      guard case .failed = await failing.repair(projectRoot: project) else {
        return XCTFail("the join should fail")
      }
    }

    XCTAssertFalse(failing.needsRepair(projectRoot: project))
    let afterCap = await failing.repair(projectRoot: project)
    XCTAssertEqual(afterCap, .nothingToRepair)
    XCTAssertEqual(duration(RecordingProjectPaths.screenVideoURL(for: project)), 1, accuracy: 0.1)
    XCTAssertTrue(exists(capture.appendingPathComponent("screen.segment-002.mov")))
    let manifest = try json(SalvagedTakeRepairer.screenManifestURL(for: project))
    let repair = try XCTUnwrap(manifest["repair"] as? [String: Any])
    XCTAssertEqual(repair["attempts"] as? Int, 3)
    XCTAssertNotNil(repair["lastError"])
    XCTAssertTrue(
      repairer(screenPresets: ["NotAnExportPreset"], appVersion: "9.9.9")
        .needsRepair(projectRoot: project),
      "a new version gets another try")
  }

  // MARK: - Crash safety

  /// A repair that crashed after deciding to commit is finished, not redone:
  /// moves whose source is gone already happened.
  func testACommitThatStoppedHalfwayIsFinished() async throws {
    let project = try makeProject()
    let staging = SalvagedTakeRepairer.stagingURL(for: project)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    try writeMovie(RecordingProjectPaths.screenVideoURL(for: project), seconds: 1)
    try writeMovie(staging.appendingPathComponent("screen.mov"), seconds: 2)
    let leftover = RecordingProjectPaths.captureDirectoryURL(for: project)
      .appendingPathComponent("screen.segment-002.mov")
    try Data("part".utf8).write(to: leftover)
    let plan: [String: Any] = [
      "version": 1,
      "moves": [
        ["from": ".repair/cursor.json", "to": "capture/cursor.json"],  // already moved
        ["from": ".repair/screen.mov", "to": "capture/screen.mov"],
      ],
      "deletes": ["capture/screen.segment-002.mov"],
      "camera": "keep", "markReady": false, "outcome": "repaired",
    ]
    try JSONSerialization.data(withJSONObject: plan).write(
      to: SalvagedTakeRepairer.commitURL(for: project))

    XCTAssertTrue(repairer().needsRepair(projectRoot: project))
    let outcome = await repairer().repair(projectRoot: project)

    XCTAssertEqual(outcome, .repaired)
    XCTAssertEqual(duration(RecordingProjectPaths.screenVideoURL(for: project)), 2, accuracy: 0.1)
    XCTAssertFalse(exists(leftover))
    XCTAssertFalse(exists(staging))
  }

  /// A staging folder with no commit plan is a repair that stopped while
  /// building: nothing was moved yet, so it is thrown away and redone.
  func testAStagingFolderWithoutAPlanIsThrownAway() async throws {
    let project = try makeProject()
    let staging = SalvagedTakeRepairer.stagingURL(for: project)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    try Data("half a movie".utf8).write(to: staging.appendingPathComponent("screen.mov"))
    let capture = RecordingProjectPaths.captureDirectoryURL(for: project)
    try writeMovie(RecordingProjectPaths.screenVideoURL(for: project), seconds: 1)
    try writeMovie(capture.appendingPathComponent("screen.segment-002.mov"), seconds: 1)
    try writeScreenMetadata(project, segments: [segment(1, start: 0, seconds: 1)])
    try writeScreenManifest(
      project, published: 1, records: [record(1, start: 0, seconds: 1), record(2, start: 2, seconds: 1)])

    let outcome = await repairer().repair(projectRoot: project)

    XCTAssertEqual(outcome, .repaired)
    XCTAssertEqual(duration(RecordingProjectPaths.screenVideoURL(for: project)), 2, accuracy: 0.1)
    XCTAssertFalse(exists(staging))
  }

  // MARK: - Camera

  /// The camera's parts are joined, its metadata rebuilt from the manifest
  /// and the stub, and the take names its camera again.
  func testACameraIsRebuiltFromItsParts() async throws {
    let project = try makeProject(includeCamera: false)
    let segments = RecordingProjectPaths.cameraSegmentsDirectoryURL(for: project)
    try writeMovie(segments.appendingPathComponent("segment_000.mov"), seconds: 1)
    try writeMovie(segments.appendingPathComponent("segment_001.mov"), seconds: 1)
    try writeCameraStub(project)
    try writeMovie(RecordingProjectPaths.screenVideoURL(for: project), seconds: 4)
    try writeCameraManifest(
      project, visible: false,
      records: [
        [
          "index": 0, "camera": "segments/segment_000.mov", "present": true,
          "stretches": [stretch(0, 1)], "mirroredRaw": true,
        ],
        [
          "index": 1, "camera": "segments/segment_001.mov", "present": true,
          "stretches": [stretch(2, 0.5), stretch(3, 0.5), stretch(4, 0)], "mirroredRaw": true,
        ],
      ])
    try writeScreenMetadata(project, segments: [segment(1, start: 0, seconds: 4)], camera: false)

    let outcome = await repairer().repair(projectRoot: project)

    XCTAssertEqual(outcome, .repaired)
    XCTAssertEqual(duration(RecordingProjectPaths.cameraRawURL(for: project)), 2, accuracy: 0.1)
    let camera = try JSONDecoder().decode(
      CameraRecordingMetadata.self,
      from: Data(contentsOf: RecordingProjectPaths.cameraMetadataURL(for: project)))
    XCTAssertEqual(camera.recordingId, "stub-id")
    XCTAssertEqual(camera.dimensions, .init(width: 64, height: 64))
    XCTAssertEqual(camera.segments.map(\.index), [0, 1, 2], "a stretch with no length is dropped")
    XCTAssertEqual(
      camera.segments.map(\.relativePath), ["segment_000.mov", "segment_001.mov", "segment_001.mov"])
    XCTAssertEqual(camera.endedAt, iso(3.5))

    let metadata = try RecordingMetadata.read(
      from: RecordingProjectPaths.screenMetadataURL(for: project))
    XCTAssertEqual(metadata.camera?.segments.count, 3)
    XCTAssertEqual(metadata.editorSeed.cameraVisible, false, "visibility comes back as it was")
    let manifest = try RecordingProjectManifest.read(
      from: RecordingProjectPaths.manifestURL(for: project))
    XCTAssertNotNil(manifest.camera)
    XCTAssertTrue(
      ProjectOpenValidator.missingRequiredProjectFiles(for: manifest, projectRootURL: project)
        .isEmpty)
    XCTAssertFalse(exists(segments))
    XCTAssertFalse(exists(SalvagedTakeRepairer.cameraManifestURL(for: project)))
  }

  /// Out of attempts, a take that still names its lost camera in
  /// project.json, as a stop before this fix left it, must at least open.
  func testACameraThatCannotBeRebuiltIsDroppedSoTheTakeOpens() async throws {
    let project = try makeProject(includeCamera: true)
    let segments = RecordingProjectPaths.cameraSegmentsDirectoryURL(for: project)
    try writeMovie(segments.appendingPathComponent("segment_000.mov"), seconds: 1)
    try writeMovie(segments.appendingPathComponent("segment_001.mov"), seconds: 1)
    try writeCameraStub(project)
    try writeCameraManifest(
      project, visible: nil,
      records: [
        ["index": 0, "camera": "segments/segment_000.mov", "stretches": [stretch(0, 1)]],
        ["index": 1, "camera": "segments/segment_001.mov", "stretches": [stretch(2, 1)]],
      ])
    try writeMovie(RecordingProjectPaths.screenVideoURL(for: project), seconds: 1)
    try writeScreenMetadata(project, segments: [segment(1, start: 0, seconds: 3)], camera: false)
    try setStatus(project, .failed)
    let failing = repairer(cameraPresets: ["NotAnExportPreset"])

    for _ in 0..<SalvagedTakeRepairer.maxAttempts {
      _ = await failing.repair(projectRoot: project)
    }

    let manifest = try RecordingProjectManifest.read(
      from: RecordingProjectPaths.manifestURL(for: project))
    XCTAssertNil(manifest.camera)
    XCTAssertTrue(
      ProjectOpenValidator.missingRequiredProjectFiles(for: manifest, projectRootURL: project)
        .isEmpty)
    XCTAssertTrue(exists(segments), "the parts are kept")
    XCTAssertFalse(failing.needsRepair(projectRoot: project))
  }

  /// A camera out of attempts whose drop never landed (the last attempt
  /// crashed) is dropped at a later launch, so the take opens.
  func testALostCameraIsDroppedAtALaterLaunch() async throws {
    let project = try makeProject(includeCamera: true)
    try writeMovie(RecordingProjectPaths.screenVideoURL(for: project), seconds: 1)
    try writeScreenMetadata(project, segments: [segment(1, start: 0, seconds: 1)])
    var object: [String: Any] = [
      "version": 1, "segments": [[String: Any]](),
      "repair": ["attempts": SalvagedTakeRepairer.maxAttempts, "appVersion": "1.0.0"],
    ]
    object["reason"] = "test"
    try JSONSerialization.data(withJSONObject: object).write(
      to: SalvagedTakeRepairer.cameraManifestURL(for: project))
    try setStatus(project, .failed)

    XCTAssertTrue(repairer().needsRepair(projectRoot: project))
    let outcome = await repairer().repair(projectRoot: project)

    guard case .failed = outcome else { return XCTFail("a dropped camera is not a repair") }
    let manifest = try RecordingProjectManifest.read(
      from: RecordingProjectPaths.manifestURL(for: project))
    XCTAssertNil(manifest.camera)
    XCTAssertEqual(manifest.status, .ready, "whole without its camera, the take opens")
    XCTAssertFalse(repairer().needsRepair(projectRoot: project))
  }

  /// A crash-resumed commit that only dropped a camera is not reported as a
  /// repair: the notice would offer to open a take that lost its camera.
  func testAResumedCameraDropIsNotReportedAsARepair() async throws {
    let project = try makeProject()
    try FileManager.default.createDirectory(
      at: SalvagedTakeRepairer.stagingURL(for: project), withIntermediateDirectories: true)
    let plan: [String: Any] = [
      "version": 1, "moves": [[String: String]](), "deletes": [String](),
      "camera": "drop", "markReady": true, "outcome": "cameraDropped",
    ]
    try JSONSerialization.data(withJSONObject: plan).write(
      to: SalvagedTakeRepairer.commitURL(for: project))

    let outcome = await repairer().repair(projectRoot: project)

    guard case .failed = outcome else { return XCTFail("expected no repair to report") }
    XCTAssertFalse(exists(SalvagedTakeRepairer.stagingURL(for: project)))
  }

  /// The stop that drops the camera notes its visibility for the repair, and
  /// stops naming camera/raw.mov in project.json.
  func testTheStopThatDropsTheCameraPreparesTheRepair() throws {
    let project = try makeProject(includeCamera: true)
    try writeCameraManifest(project, visible: nil, records: [])

    ScreenRecorderFacade.recordCameraVisibilityForRepair(true, projectRoot: project)
    ScreenRecorderFacade.dropCameraFromProjectManifest(projectRoot: project)

    let manifest = try json(SalvagedTakeRepairer.cameraManifestURL(for: project))
    XCTAssertEqual(manifest[SalvagedTakeRepairer.cameraVisibleKey] as? Bool, true)
    XCTAssertNil(
      try RecordingProjectManifest.read(from: RecordingProjectPaths.manifestURL(for: project))
        .camera)
  }

  // MARK: - Sweep

  /// A Finder open of a project under repair waits for it; the startup report
  /// names it once the sweep is done.
  func testAnOpenWaitsForItsRepairAndTheReportNamesIt() throws {
    let project = try makeProject()
    let capture = RecordingProjectPaths.captureDirectoryURL(for: project)
    try writeMovie(RecordingProjectPaths.screenVideoURL(for: project), seconds: 1)
    try writeMovie(capture.appendingPathComponent("screen.segment-002.mov"), seconds: 1)
    try writeScreenMetadata(project, segments: [segment(1, start: 0, seconds: 1)])
    try writeScreenManifest(
      project, published: 1, records: [record(1, start: 0, seconds: 1), record(2, start: 2, seconds: 1)])
    let sweep = SalvagedTakeRepairSweep.shared

    sweep.start(rootURL: root, repairer: repairer()) { true }

    var opened = false
    sweep.whenProjectIsFree(project.path) {
      opened = true
      XCTAssertEqual(
        self.duration(RecordingProjectPaths.screenVideoURL(for: project)), 2, accuracy: 0.1,
        "the project opens with its parts joined")
    }
    XCTAssertFalse(opened, "the open waits for the repair")
    let reported = expectation(description: "report")
    sweep.whenFinished { paths in
      XCTAssertEqual(
        paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
        [project.resolvingSymlinksInPath().path])
      reported.fulfill()
    }
    wait(for: [reported], timeout: 60)
    XCTAssertTrue(opened)
  }

  /// A recording running at launch is not competed with: the project waits
  /// for the next launch.
  func testARunningRecordingDefersTheRepair() throws {
    let project = try makeProject()
    try writeScreenManifest(project, published: 1, records: [])
    let sweep = SalvagedTakeRepairSweep.shared

    sweep.start(rootURL: root, repairer: repairer()) { false }

    var reported: [String]?
    sweep.whenFinished { reported = $0 }
    XCTAssertEqual(reported, [])
    XCTAssertTrue(repairer().needsRepair(projectRoot: project), "still due next launch")
  }

  /// A repair stopped before it commits (a recording starting) changes
  /// nothing and does not use up an attempt.
  func testACancelledRepairChangesNothingAndKeepsItsAttempt() async throws {
    let project = try makeProject()
    let capture = RecordingProjectPaths.captureDirectoryURL(for: project)
    try writeMovie(RecordingProjectPaths.screenVideoURL(for: project), seconds: 1)
    let part = capture.appendingPathComponent("screen.segment-002.mov")
    try writeMovie(part, seconds: 1)
    try writeScreenMetadata(project, segments: [segment(1, start: 0, seconds: 1)])
    try writeScreenManifest(
      project, published: 1, records: [record(1, start: 0, seconds: 1), record(2, start: 2, seconds: 1)])
    let repairer = repairer()

    let task = Task { await repairer.repair(projectRoot: project) }
    task.cancel()
    let outcome = await task.value

    XCTAssertEqual(outcome, .cancelled)
    XCTAssertEqual(duration(RecordingProjectPaths.screenVideoURL(for: project)), 1, accuracy: 0.1)
    XCTAssertTrue(exists(part))
    XCTAssertFalse(exists(SalvagedTakeRepairer.stagingURL(for: project)))
    let manifest = try json(SalvagedTakeRepairer.screenManifestURL(for: project))
    XCTAssertEqual((manifest["repair"] as? [String: Any])?["attempts"] as? Int, 0)
    XCTAssertTrue(repairer.needsRepair(projectRoot: project), "tried again next launch")
  }

  /// A recording starting stops the repair under way; the projects after it
  /// wait for the next launch, and the report answers at once.
  func testARecordingStartingStopsTheSweep() throws {
    for _ in 0..<2 {
      let project = try makeProject()
      try writeScreenManifest(project, published: 1, records: [])
    }
    let sweep = SalvagedTakeRepairSweep.shared
    let calls = Counter()
    sweep._testSetRepair { _ in
      calls.increment()
      while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
      return .cancelled
    }

    sweep.start(rootURL: root, repairer: repairer()) { true }
    sweep.cancelCurrent()

    let reported = expectation(description: "report")
    sweep.whenFinished { paths in
      XCTAssertEqual(paths, [])
      reported.fulfill()
    }
    wait(for: [reported], timeout: 5)
    XCTAssertEqual(calls.value, 1, "the second project waits for the next launch")
  }

  /// A repair that never finishes, and ignores being stopped, is left behind:
  /// its Finder open and the startup report are released.
  func testAStuckRepairIsLeftBehind() throws {
    let project = try makeProject()
    try writeScreenManifest(project, published: 1, records: [])
    let sweep = SalvagedTakeRepairSweep.shared
    sweep._testSetTimeouts(project: 0.2, grace: 0.2)
    sweep._testSetRepair { _ in
      Thread.sleep(forTimeInterval: 3)  // ignores the stop
      return .repaired
    }

    sweep.start(rootURL: root, repairer: repairer()) { true }

    let opened = expectation(description: "open released")
    sweep.whenProjectIsFree(project.path) { opened.fulfill() }
    let reported = expectation(description: "report")
    sweep.whenFinished { paths in
      XCTAssertEqual(paths, [], "a repair given up on is not reported")
      reported.fulfill()
    }
    wait(for: [opened, reported], timeout: 2)
  }

  // MARK: - Fixtures

  private func repairer(
    screenPresets: [String] = SalvagedTakeRepairer.screenPresetOrder,
    cameraPresets: [String] = CameraRecorder.mergePresetOrder,
    appVersion: String = "1.0.0"
  ) -> SalvagedTakeRepairer {
    SalvagedTakeRepairer(
      screenPresets: screenPresets, cameraPresets: cameraPresets, appVersion: appVersion,
      now: { Date(timeIntervalSince1970: 1_000) })
  }

  private func makeProject(includeCamera: Bool = false) throws -> URL {
    let project = root.appendingPathComponent(
      "rec_\(UUID().uuidString.prefix(8)).\(RecordingProjectPaths.projectExtension)",
      isDirectory: true)
    let fm = FileManager.default
    for directory in [
      RecordingProjectPaths.captureDirectoryURL(for: project),
      RecordingProjectPaths.cameraSegmentsDirectoryURL(for: project),
      RecordingProjectPaths.derivedDirectoryURL(for: project),
    ] {
      try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try RecordingProjectManifest.create(
      projectId: project.deletingPathExtension().lastPathComponent, displayName: "Test",
      includeCamera: includeCamera
    ).write(to: RecordingProjectPaths.manifestURL(for: project))
    return project
  }

  private func setStatus(_ project: URL, _ status: RecordingProjectStatus) throws {
    let url = RecordingProjectPaths.manifestURL(for: project)
    var manifest = try RecordingProjectManifest.read(from: url)
    manifest.updateStatus(status)
    try manifest.write(to: url)
  }

  private func status(_ project: URL) throws -> RecordingProjectStatus {
    try RecordingProjectManifest.read(from: RecordingProjectPaths.manifestURL(for: project)).status
  }

  private func iso(_ seconds: TimeInterval) -> String {
    RecordingMetadata.iso8601String(from: Date(timeIntervalSince1970: 100 + seconds))
  }

  private func segment(_ index: Int, start: TimeInterval, seconds: Double)
    -> RecordingMetadata.CaptureSegment
  {
    .init(
      index: index, relativePath: "screen.segment-\(String(format: "%03d", index)).mov",
      startWallClock: iso(start), endWallClock: iso(start + seconds), durationSeconds: seconds)
  }

  private func record(
    _ index: Int, start: TimeInterval, seconds: Double, cursor: Bool = false, mic: Bool = false
  ) -> [String: Any] {
    let n = String(format: "%03d", index)
    var record: [String: Any] = [
      "index": index, "screen": "screen.segment-\(n).mov", "durationSeconds": seconds,
      "startWallClock": iso(start), "endWallClock": iso(start + seconds),
    ]
    if cursor { record["cursor"] = "screen.segment-\(n).cursor.json" }
    if mic { record["mic"] = "mic.segment-\(n).m4a" }
    return record
  }

  private func stretch(_ start: TimeInterval, _ seconds: Double) -> [String: Any] {
    ["startWallClock": iso(start), "endWallClock": iso(start + seconds), "durationSeconds": seconds]
  }

  private func writeScreenManifest(_ project: URL, published: Int?, records: [[String: Any]])
    throws
  {
    let data = try XCTUnwrap(
      RecordingSegmentMerger.unmergedManifest(
        segments: records, publishedIndex: published, reason: "test"))
    try data.write(to: SalvagedTakeRepairer.screenManifestURL(for: project))
  }

  private func writeCameraManifest(_ project: URL, visible: Bool?, records: [[String: Any]])
    throws
  {
    var object: [String: Any] = [
      "version": 1, "reason": "test", "publishedSegmentIndex": NSNull(), "segments": records,
    ]
    if let visible { object[SalvagedTakeRepairer.cameraVisibleKey] = visible }
    try JSONSerialization.data(withJSONObject: object).write(
      to: SalvagedTakeRepairer.cameraManifestURL(for: project))
  }

  private func writeCameraStub(_ project: URL) throws {
    try CameraRecordingMetadata(
      version: 1, recordingId: "stub-id",
      rawRelativePath: RecordingProjectPaths.relativeCameraRawPath,
      metadataRelativePath: RecordingProjectPaths.relativeCameraMetadataPath,
      deviceId: "camera-1", mirroredRaw: true, nominalFrameRate: 30,
      dimensions: .init(width: 64, height: 64), startedAt: iso(0), endedAt: nil, segments: []
    ).write(to: RecordingProjectPaths.cameraMetadataURL(for: project))
  }

  private func writeScreenMetadata(
    _ project: URL, segments: [RecordingMetadata.CaptureSegment], camera: Bool = false
  ) throws {
    let seed = RecordingMetadata.EditorSeed(
      cameraVisible: camera, cameraLayoutPreset: .overlayBottomRight,
      cameraNormalizedCenter: nil, cameraSizeFactor: 0.18, cameraShape: .circle,
      cameraCornerRadius: 0, cameraBorderWidth: 0, cameraBorderColorArgb: nil, cameraShadow: 0,
      cameraOpacity: 1, cameraMirror: true, cameraContentMode: .fill,
      cameraZoomBehavior: CameraCompositionParams.defaultZoomBehavior,
      cameraChromaKeyEnabled: false, cameraChromaKeyStrength: 0.4, cameraChromaKeyColorArgb: nil)
    var metadata = RecordingMetadata.create(
      screenRawRelativePath: RecordingProjectPaths.relativeScreenVideoPath,
      displayMode: .explicitID, displayID: 1, cropRect: nil, frameRate: 30, quality: .fhd,
      cursorEnabled: true, cursorLinked: true, windowID: nil, excludedRecorderApp: false,
      camera: nil, editorSeed: seed)
    metadata.screen.segments = segments
    try metadata.write(to: RecordingProjectPaths.screenMetadataURL(for: project))
  }

  private func writeCursor(_ url: URL, times: [TimeInterval]) throws {
    let recording = CursorRecording(
      sprites: [
        CursorSprite(id: 0, width: 1, height: 1, hotspotX: 0, hotspotY: 0, pixels: Data([0, 0, 0, 255]))
      ],
      frames: times.map { CursorFrame(t: $0, x: 0.5, y: 0.5, spriteID: 0) })
    try JSONEncoder().encode(recording).write(to: url)
  }

  private func writeMovie(_ url: URL, seconds: Double) throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
      ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
      ])
    writer.add(input)
    XCTAssertTrue(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for i in 0..<Int(seconds * 30) {
      var buffer: CVPixelBuffer?
      CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
      guard let buffer else { continue }
      while !input.isReadyForMoreMediaData { usleep(1000) }
      adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(seconds: seconds, preferredTimescale: 600))
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    XCTAssertEqual(done.wait(timeout: .now() + 30), .success)
  }

  private func writeTone(_ url: URL, seconds: Double) throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
    let input = AVAssetWriterInput(
      mediaType: .audio,
      outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64000,
      ])
    input.expectsMediaDataInRealTime = false
    writer.add(input)
    XCTAssertTrue(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    var asbd = AudioStreamBasicDescription(
      mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
      mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32,
      mReserved: 0)
    var format: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(
      allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
      magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
    let total = Int(seconds * 48000)
    var written = 0
    while written < total {
      while !input.isReadyForMoreMediaData { usleep(1000) }
      let count = min(1024, total - written)
      let byteCount = count * 4
      var block: CMBlockBuffer?
      CMBlockBufferCreateWithMemoryBlock(
        allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil,
        customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0,
        blockBufferOut: &block)
      let samples = (0..<count).map { Float(sin(Double(written + $0) * 0.05) * 0.2) }
      samples.withUnsafeBytes {
        _ = CMBlockBufferReplaceDataBytes(
          with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0,
          dataLength: byteCount)
      }
      var sample: CMSampleBuffer?
      CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: count,
        presentationTimeStamp: CMTime(value: CMTimeValue(written), timescale: 48000),
        packetDescriptions: nil, sampleBufferOut: &sample)
      input.append(sample!)
      written += count
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    XCTAssertEqual(done.wait(timeout: .now() + 30), .success)
  }

  private func duration(_ url: URL) -> Double {
    AVURLAsset(url: url).duration.seconds
  }

  private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
  }

  private func json(_ url: URL) throws -> [String: Any] {
    try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  }
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int { lock.withLock { count } }
  func increment() { lock.withLock { count += 1 } }
}
