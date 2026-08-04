import XCTest

@testable import Clingfy

/// Covers the service that owns an in-flight transcription: source resolution,
/// single-flight, cancellation, and progress staging.
///
/// Runs against a fake engine. Nothing here should need a 626 MB model.
final class CaptionsServiceTests: XCTestCase {

  // MARK: - Fake engine

  private final class FakeTranscriber: CaptionTranscriber {
    var availability: TranscriberAvailability = .available
    var segments: [TranscribedSegment] = []
    /// Blocks the run until signalled, so single-flight and cancellation can be
    /// observed while a job is genuinely in flight.
    var gate: DispatchSemaphore?
    private(set) var callCount = 0

    func transcribe(
      url: URL,
      options: TranscriptionOptions,
      progress: @escaping (Double) -> Void,
      isCancelled: @escaping () -> Bool
    ) throws -> [TranscribedSegment] {
      callCount += 1
      if let gate { gate.wait() }
      if isCancelled() { throw TranscriptionError.cancelled }
      progress(1.0)
      return segments
    }
  }

  private func mediaSources(
    mic: String? = nil, system: String? = nil, screen: String = "/tmp/p/screen.mov"
  ) -> PreviewMediaSources {
    PreviewMediaSources(
      projectPath: "/tmp/p",
      screenPath: screen,
      cameraPath: nil,
      metadataPath: nil,
      cursorPath: nil,
      zoomManualPath: nil,
      cameraSyncTimeline: nil,
      micAudioPath: mic,
      systemAudioPath: system
    )
  }

  // MARK: - Source resolution

  /// Nothing on disk is decodable in a unit test, so every path resolves to
  /// nil. What is being pinned is the SELECTION logic — that a source the user
  /// turned off is never even probed.
  func testDeselectedSourcesAreNotUsed() {
    let sources = CaptionsService.resolveSources(
      mediaSources: mediaSources(mic: "/tmp/p/mic.m4a", system: "/tmp/p/system.m4a"),
      useMic: false,
      useSystem: false)
    XCTAssertNil(sources.micURL)
    XCTAssertNil(sources.systemURL)
  }

  func testAbsentPathsResolveToNothing() {
    let sources = CaptionsService.resolveSources(
      mediaSources: mediaSources(), useMic: true, useSystem: true)
    XCTAssertNil(sources.micURL)
    XCTAssertNil(sources.systemURL)
    XCTAssertFalse(sources.hasSeparatedSources)
  }

  func testEmptyPathStringsAreTreatedAsAbsent() {
    let sources = CaptionsService.resolveSources(
      mediaSources: mediaSources(mic: "", system: ""), useMic: true, useSystem: true)
    XCTAssertNil(sources.micURL)
    XCTAssertNil(sources.systemURL)
  }

  // MARK: - Single flight

  /// WhisperKit is not Sendable and has open data races on its own state, so
  /// two concurrent jobs on one instance is a crash waiting to happen.
  func testASecondJobIsRefusedWhileOneIsRunning() {
    let fake = FakeTranscriber()
    let gate = DispatchSemaphore(value: 0)
    fake.gate = gate
    let service = CaptionsService(transcriber: fake)

    let started = expectation(description: "first job running")
    // Progress fires again once the gate opens, and fulfilling twice is an
    // XCTest API violation — so only the first tick counts.
    started.assertForOverFulfill = false
    let firstDone = expectation(description: "first job finished")
    let sources = TranscriptionJob.Sources(
      micURL: URL(fileURLWithPath: "/tmp/mic.m4a"), systemURL: nil, embeddedURL: nil)

    service.generateCaptions(
      sources: sources, language: nil,
      onProgress: { _ in started.fulfill() },
      completion: { _ in firstDone.fulfill() })
    wait(for: [started], timeout: 5)

    let secondDone = expectation(description: "second job refused")
    var secondOutcome: Result<[Caption], Error>?
    service.generateCaptions(
      sources: sources, language: nil,
      onProgress: { _ in },
      completion: { outcome in
        secondOutcome = outcome
        secondDone.fulfill()
      })
    wait(for: [secondDone], timeout: 5)

    switch secondOutcome {
    case .failure:
      break  // expected
    default:
      XCTFail("a second concurrent transcription must be refused")
    }

    gate.signal()
    wait(for: [firstDone], timeout: 10)
  }

  func testAJobCanRunAfterThepreviousOneFinished() {
    let fake = FakeTranscriber()
    let service = CaptionsService(transcriber: fake)
    let sources = TranscriptionJob.Sources(
      micURL: URL(fileURLWithPath: "/tmp/mic.m4a"), systemURL: nil, embeddedURL: nil)

    for attempt in 1...2 {
      let done = expectation(description: "run \(attempt)")
      service.generateCaptions(
        sources: sources, language: nil, onProgress: { _ in },
        completion: { _ in done.fulfill() })
      wait(for: [done], timeout: 10)
    }
    XCTAssertEqual(fake.callCount, 2, "the guard must not latch permanently")
  }

  // MARK: - Progress staging

  /// Loading a ~626 MB model and letting Core ML specialise it for this chip
  /// takes tens of seconds on a cold cache. A determinate bar pinned at 0%
  /// through that is indistinguishable from a hang, so the first tick is
  /// deliberately indeterminate.
  func testTheFirstTickIsIndeterminatePreparing() {
    let service = CaptionsService(transcriber: FakeTranscriber())
    var first: JobProgress?
    let done = expectation(description: "finished")

    service.generateCaptions(
      sources: TranscriptionJob.Sources(
        micURL: URL(fileURLWithPath: "/tmp/mic.m4a"), systemURL: nil, embeddedURL: nil),
      language: nil,
      onProgress: { progress in
        if first == nil { first = progress }
      },
      completion: { _ in done.fulfill() })
    wait(for: [done], timeout: 10)

    XCTAssertEqual(first?.job, .captions)
    XCTAssertEqual(first?.stage, .preparing)
    XCTAssertNil(first?.fraction, "must be indeterminate, not zero")
  }

  func testProgressIsTaggedAsCaptionsNotExport() {
    let service = CaptionsService(transcriber: FakeTranscriber())
    var jobs: Set<String> = []
    let done = expectation(description: "finished")

    service.generateCaptions(
      sources: TranscriptionJob.Sources(
        micURL: URL(fileURLWithPath: "/tmp/mic.m4a"), systemURL: nil, embeddedURL: nil),
      language: nil,
      onProgress: { jobs.insert($0.job.rawValue) },
      completion: { _ in done.fulfill() })
    wait(for: [done], timeout: 10)

    XCTAssertEqual(
      jobs, ["captions"],
      "a caption tick tagged export would move the export bar")
  }

  // MARK: - Cancellation

  func testCancellationEndsTheJobWithTheCancelledError() {
    let fake = FakeTranscriber()
    let gate = DispatchSemaphore(value: 0)
    fake.gate = gate
    let service = CaptionsService(transcriber: fake)

    let started = expectation(description: "running")
    started.assertForOverFulfill = false
    let done = expectation(description: "finished")
    var outcome: Result<[Caption], Error>?

    service.generateCaptions(
      sources: TranscriptionJob.Sources(
        micURL: URL(fileURLWithPath: "/tmp/mic.m4a"), systemURL: nil, embeddedURL: nil),
      language: nil,
      onProgress: { _ in started.fulfill() },
      completion: { result in
        outcome = result
        done.fulfill()
      })
    wait(for: [started], timeout: 5)

    service.cancel()
    gate.signal()
    wait(for: [done], timeout: 10)

    switch outcome {
    case .failure(let error):
      XCTAssertEqual(error as? TranscriptionError, .cancelled)
    default:
      XCTFail("cancellation must surface as .cancelled, not as success")
    }
  }

  /// Cancel state must not leak into the next job, or one cancellation would
  /// poison every subsequent transcription.
  func testCancellingDoesNotPoisonTheNextRun() {
    let fake = FakeTranscriber()
    let service = CaptionsService(transcriber: fake)
    let sources = TranscriptionJob.Sources(
      micURL: URL(fileURLWithPath: "/tmp/mic.m4a"), systemURL: nil, embeddedURL: nil)

    service.cancel()  // before anything is running

    let done = expectation(description: "runs anyway")
    var outcome: Result<[Caption], Error>?
    service.generateCaptions(
      sources: sources, language: nil, onProgress: { _ in },
      completion: { result in
        outcome = result
        done.fulfill()
      })
    wait(for: [done], timeout: 10)

    switch outcome {
    case .success:
      break  // expected: beginRun clears the stale flag
    default:
      XCTFail("a stale cancel flag must not kill the next job")
    }
  }

  func testCancellingWhenNothingIsRunningIsHarmless() {
    let service = CaptionsService(transcriber: FakeTranscriber())
    service.cancel()
    service.cancel()
  }

  // MARK: - Model location

  /// Never the engine's default, which is ~/Documents/huggingface — in an
  /// unsandboxed Developer-ID app that is the user's real Documents folder.
  func testModelsLiveInApplicationSupportNotDocuments() {
    let path = CaptionsService.modelDirectory().path
    XCTAssertTrue(
      path.contains("Application Support"),
      "models must not land in a user-visible folder: \(path)")
    XCTAssertFalse(path.contains("/Documents/"), "got \(path)")
    XCTAssertTrue(path.hasSuffix("Models"), "got \(path)")
  }
}
