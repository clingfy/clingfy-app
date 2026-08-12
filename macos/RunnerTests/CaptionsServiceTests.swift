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
    /// Fractions to emit as a model download before transcribing, mirroring the
    /// real engine's first-run behaviour.
    var downloadFractions: [Double] = []
    /// Thrown instead of returning, so failures from below the protocol — the
    /// decoder's own error type among them — can be put through the service.
    var errorToThrow: Error?
    private(set) var callCount = 0

    /// The real engine holds its model open across jobs and reports it here; the
    /// delete path in Settings is gated on exactly this. Implemented rather than
    /// inherited from the protocol default, which answers `false` unconditionally
    /// — which is why a transcriber that latched "busy" forever passed every
    /// test in this file.
    private let engineLock = NSLock()
    private var engineBusy = false
    private var releases = 0

    /// How many times the engine actually handed the weights back.
    ///
    /// Locked because the service now releases from a detached task at the end
    /// of every job, so this is written off the test thread.
    var releaseCount: Int {
      engineLock.lock()
      defer { engineLock.unlock() }
      return releases
    }

    private var attempts = 0

    /// Every ASK, refusals included.
    ///
    /// Separate from `releaseCount` because a refused release is invisible in
    /// that number, and "the retry loop stopped asking" is exactly what a test
    /// of the stand-down has to see.
    var releaseAttempts: Int {
      engineLock.lock()
      defer { engineLock.unlock() }
      return attempts
    }

    /// What `releaseModel()` answers. The real engine refuses while a cancelled
    /// job's abandoned task still owns the weights, and the delete path must not
    /// remove files on a refusal.
    ///
    /// Behind the same lock as the rest of the engine state: a test flips it
    /// from the test thread while the service's retry loop is asking on a
    /// cooperative thread, which is an unsynchronised write to a `var` read from
    /// another thread — the exact shape of the defect this file exists to guard.
    var releaseSucceeds: Bool {
      get {
        engineLock.lock()
        defer { engineLock.unlock() }
        return releaseWillSucceed
      }
      set {
        engineLock.lock()
        releaseWillSucceed = newValue
        engineLock.unlock()
      }
    }
    private var releaseWillSucceed = true

    /// EVERY closure the service has handed the engine, in order, kept past the
    /// end of the run that owned it — and behind the lock, because they are
    /// written on the service queue and read from the test thread.
    ///
    /// All of them, not just the last: the contract has two halves, and only the
    /// first distinguishes a per-job token from one shared flag. A cancelled
    /// job's probe must still answer `true` after that job has ended (its task is
    /// abandoned mid-download and goes on polling for as long as the download
    /// takes), while the NEXT job's probe must answer `false`. Keeping only the
    /// last probe tests the second half alone, which the old shared flag also
    /// satisfied — `beginRun` cleared it.
    private var isCancelledProbes: [() -> Bool] = []

    /// Signalled once per `transcribe`, AFTER the probe is captured and BEFORE
    /// the gate blocks.
    ///
    /// The engine entry is the thing a cancellation test needs to have happened,
    /// and progress is not it: `generateCaptions` fires `onProgress(.preparing)`
    /// synchronously on the CALLER's thread before it reaches `queue.async`, so
    /// waiting on the first tick returns while the service queue has not even
    /// been scheduled. A cancel that won that race killed the job before the
    /// engine was entered, no probe was ever captured, and the test failed — for
    /// two of four consecutive runs, which is worse than no test at all.
    let enteredEngine = DispatchSemaphore(value: 0)

    var capturedProbes: [() -> Bool] {
      engineLock.lock()
      defer { engineLock.unlock() }
      return isCancelledProbes
    }

    var isEngineBusy: Bool {
      engineLock.lock()
      defer { engineLock.unlock() }
      return engineBusy
    }

    func setEngineBusy(_ value: Bool) {
      engineLock.lock()
      engineBusy = value
      engineLock.unlock()
    }

    func releaseModel() async -> Bool {
      engineLock.lock()
      attempts += 1
      let succeeds = releaseWillSucceed
      if succeeds {
        releases += 1
        engineBusy = false
      }
      engineLock.unlock()
      return succeeds
    }

    func transcribe(
      url: URL,
      options: TranscriptionOptions,
      progress: @escaping (TranscriptionProgress) -> Void,
      isCancelled: @escaping () -> Bool
    ) throws -> [TranscribedSegment] {
      callCount += 1
      engineLock.lock()
      isCancelledProbes.append(isCancelled)
      engineLock.unlock()
      enteredEngine.signal()
      for fraction in downloadFractions {
        progress(.downloadingModel(fraction))
      }
      if let gate { gate.wait() }
      if let errorToThrow { throw errorToThrow }
      if isCancelled() { throw TranscriptionError.cancelled }
      progress(.transcribing(1.0))
      return segments
    }
  }

  /// Polls until `condition` holds, or gives up.
  ///
  /// For state settled in a `defer` that runs AFTER the completion handler —
  /// there is no callback to wait on, and sleeping a fixed interval instead is
  /// how a suite starts failing once a week on a loaded machine.
  private func waitUntil(
    timeout: TimeInterval = 5, _ condition: () -> Bool
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
  }

  private func micOnly() -> TranscriptionJob.Sources {
    TranscriptionJob.Sources(
      micURL: URL(fileURLWithPath: "/tmp/mic.m4a"), systemURL: nil, embeddedURL: nil)
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

  // MARK: - Model download

  /// The bug this pins, from a real first run: the panel showed a determinate
  /// bar frozen at 10% for the length of a 626 MB download, because every phase
  /// was reported as `transcribing` and the download reported nothing at all.
  func testModelDownloadIsItsOwnStage() {
    let fake = FakeTranscriber()
    fake.downloadFractions = [0.25, 0.5, 0.75]
    let service = CaptionsService(transcriber: fake)

    var stages: [JobProgress.Stage] = []
    var downloadFractions: [Double] = []
    let done = expectation(description: "finished")
    service.generateCaptions(
      sources: TranscriptionJob.Sources(
        micURL: URL(fileURLWithPath: "/tmp/mic.m4a"), systemURL: nil, embeddedURL: nil),
      language: nil,
      onProgress: { progress in
        stages.append(progress.stage)
        if progress.stage == .downloadingModel, let fraction = progress.fraction {
          downloadFractions.append(fraction)
        }
      },
      completion: { _ in done.fulfill() })
    wait(for: [done], timeout: 10)

    XCTAssertTrue(
      stages.contains(.downloadingModel),
      "a model download must be named, not reported as transcribing")
    XCTAssertEqual(downloadFractions, [0.25, 0.5, 0.75], "and it must carry a real fraction")
  }

  /// A download fraction belongs to the whole job, not to one audio source. The
  /// per-source scaling would otherwise report a finished download as 50%.
  func testDownloadFractionsAreNotScaledPerSource() {
    let fake = FakeTranscriber()
    fake.downloadFractions = [1.0]
    let service = CaptionsService(transcriber: fake)

    var downloadFractions: [Double] = []
    let done = expectation(description: "finished")
    service.generateCaptions(
      sources: TranscriptionJob.Sources(
        micURL: URL(fileURLWithPath: "/tmp/mic.m4a"),
        systemURL: URL(fileURLWithPath: "/tmp/system.m4a"),
        embeddedURL: nil),
      language: nil,
      onProgress: { progress in
        if progress.stage == .downloadingModel, let fraction = progress.fraction {
          downloadFractions.append(fraction)
        }
      },
      completion: { _ in done.fulfill() })
    wait(for: [done], timeout: 10)

    XCTAssertTrue(
      downloadFractions.allSatisfy { $0 == 1.0 },
      "got \(downloadFractions) — a whole-job phase must not be halved")
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

  /// Stop pressed during the DECODE — which runs first, before any model
  /// download, so it is the likeliest moment to press it.
  ///
  /// The decoder throws `CaptionAudioDecoder.DecodeError.cancelled`, which is
  /// not a `TranscriptionError`. Every layer above tells a cancel from a failure
  /// with `error as? TranscriptionError`, so an untranslated decode error failed
  /// all of them at once: the service logged an error to Sentry, the bridge
  /// answered `CAPTIONS_FAILED`, and the panel told the user "Couldn't generate
  /// subtitles" for doing exactly what they meant to do.
  func testACancelFromInsideTheDecoderIsReportedAsCancelledNotAsAFailure() {
    let fake = FakeTranscriber()
    fake.errorToThrow = CaptionAudioDecoder.DecodeError.cancelled
    let service = CaptionsService(transcriber: fake)

    let done = expectation(description: "finished")
    var outcome: Result<[Caption], Error>?
    service.generateCaptions(
      sources: micOnly(), language: nil, onProgress: { _ in },
      completion: { result in
        outcome = result
        done.fulfill()
      })
    wait(for: [done], timeout: 10)

    switch outcome {
    case .failure(let error):
      XCTAssertEqual(
        error as? TranscriptionError, .cancelled,
        "a decode cancel must reach the bridge in the taxonomy the bridge reads")
    default:
      XCTFail("a cancelled decode must not report success")
    }
  }

  /// A file the decoder cannot open must not cross the seam as a foreign error
  /// type either, or the bridge reads `String(describing:)` of something it was
  /// never meant to see.
  func testADecodeFailureIsReportedInTheTranscriberTaxonomy() {
    let fake = FakeTranscriber()
    let missing = URL(fileURLWithPath: "/tmp/does-not-exist.m4a")
    fake.errorToThrow = CaptionAudioDecoder.DecodeError.noAudioTrack(missing)
    let service = CaptionsService(transcriber: fake)

    let done = expectation(description: "finished")
    var outcome: Result<[Caption], Error>?
    service.generateCaptions(
      sources: micOnly(), language: nil, onProgress: { _ in },
      completion: { result in
        outcome = result
        done.fulfill()
      })
    wait(for: [done], timeout: 10)

    guard case .failure(let error) = outcome else {
      return XCTFail("an undecodable source must not report success")
    }
    XCTAssertEqual(error as? TranscriptionError, .noAudioTrack(missing))
  }

  /// The cancel flag must survive the job it cancelled.
  ///
  /// A cancelled run abandons its engine task on purpose — the model download is
  /// not interruptible, and nobody should be held on screen for a 626 MB fetch
  /// they have already given up on — so that task goes on polling this closure
  /// long after the job has ended. The service used to clear one shared flag in
  /// the same `defer` that ended the job, so the abandoned task asked "was I
  /// cancelled?" moments later and was told no: it finished the download, and
  /// loaded it into a pipeline nobody would ever use.
  ///
  /// The wait is on the ENGINE having been entered, not on the first progress
  /// tick. `generateCaptions` emits that tick synchronously on the caller's
  /// thread before `queue.async`, so waiting on it proved nothing about the
  /// service queue and the cancel below could land before the engine was ever
  /// reached — a ~50% failure rate at the unwrap, on a test whose whole job is
  /// to guard a cancellation contract.
  func testTheCancelFlagOutlivesTheJobThatWasCancelled() throws {
    let fake = FakeTranscriber()
    let gate = DispatchSemaphore(value: 0)
    fake.gate = gate
    let service = CaptionsService(transcriber: fake)

    let done = expectation(description: "finished")
    service.generateCaptions(
      sources: micOnly(), language: nil,
      onProgress: { _ in },
      completion: { _ in done.fulfill() })
    XCTAssertEqual(
      fake.enteredEngine.wait(timeout: .now() + 5), .success,
      "the engine was never entered, so there is no probe to cancel")

    service.cancel()
    gate.signal()
    wait(for: [done], timeout: 10)
    // `endRun` runs in a `defer`, i.e. after the completion handler above.
    XCTAssertTrue(waitUntil { !service.isBusy }, "the job never finished unwinding")

    let probes = fake.capturedProbes
    XCTAssertEqual(probes.count, 1, "one source, one engine pass")
    let stillCancelled = try XCTUnwrap(probes.first)
    XCTAssertTrue(
      stillCancelled(),
      "the abandoned engine task was told its cancelled job was never cancelled")
  }

  /// And the next job still gets a clean one — a token is per job, so this is
  /// the other half of the same contract.
  ///
  /// Both halves are asserted here on purpose. The second half alone cannot fail
  /// when the per-job token is taken away: the old service-wide flag was cleared
  /// by `beginRun` as well as by `endRun`, so the second job saw `false` under
  /// either design and this test stayed green with its own fix fully reverted.
  /// `probes[0]` is what tells the designs apart — under the shared flag it goes
  /// `false` the moment the cancelled job's `defer` runs.
  func testTheNextJobGetsItsOwnUncancelledFlag() throws {
    let fake = FakeTranscriber()
    let gate = DispatchSemaphore(value: 0)
    fake.gate = gate
    let service = CaptionsService(transcriber: fake)

    let first = expectation(description: "first")
    service.generateCaptions(
      sources: micOnly(), language: nil, onProgress: { _ in },
      completion: { _ in first.fulfill() })
    // Cancel it where a user actually can: inside the engine, holding a probe.
    XCTAssertEqual(fake.enteredEngine.wait(timeout: .now() + 5), .success)
    service.cancel()
    gate.signal()
    wait(for: [first], timeout: 10)
    XCTAssertTrue(waitUntil { !service.isBusy })

    // The second job must not block on a gate the first one consumed.
    fake.gate = nil
    let second = expectation(description: "second")
    var outcome: Result<[Caption], Error>?
    service.generateCaptions(
      sources: micOnly(), language: nil, onProgress: { _ in },
      completion: { result in
        outcome = result
        second.fulfill()
      })
    wait(for: [second], timeout: 10)
    XCTAssertTrue(waitUntil { !service.isBusy })

    let probes = fake.capturedProbes
    XCTAssertEqual(probes.count, 2, "two jobs, two engine passes")
    XCTAssertTrue(
      probes[0](),
      "the cancelled job's flag was cleared out from under the task still polling it")
    XCTAssertFalse(
      probes[1](),
      "a cancel belongs to the job it was aimed at, not to the service")
    guard case .success = outcome else {
      return XCTFail("a cancel aimed at the previous job must not kill this one")
    }
  }

  // MARK: - Model lifetime

  /// `isBusy` is what Settings › Storage asks before allowing a delete, and the
  /// dangerous window is wider than a job: a cancelled first-run download keeps
  /// writing into the model directory after the user has moved on.
  func testBusyFollowsTheEngineAndNotOnlyTheJob() {
    let fake = FakeTranscriber()
    let service = CaptionsService(transcriber: fake)
    XCTAssertFalse(service.isBusy)

    fake.setEngineBusy(true)
    XCTAssertTrue(
      service.isBusy,
      "an engine still holding the model must block a delete even with no job running")
    XCTAssertTrue(service.isModelLoaded)
  }

  /// Unload, then delete — in that order, always. Core ML keeps the weights
  /// mmapped, so removing the directory under a live pipeline frees nothing and
  /// reports success.
  func testReleasingHandsBackTheModelBeforeTheCallerContinues() {
    let fake = FakeTranscriber()
    fake.setEngineBusy(true)
    let service = CaptionsService(transcriber: fake)

    let released = expectation(description: "released")
    var outcome: Bool?
    service.releaseModel {
      outcome = $0
      released.fulfill()
    }
    wait(for: [released], timeout: 5)

    XCTAssertEqual(outcome, true)
    XCTAssertEqual(fake.releaseCount, 1, "the delete path must unload before it removes")
    XCTAssertFalse(service.isModelLoaded)
    XCTAssertFalse(service.isBusy)
  }

  /// An engine that DECLINED to unload must be reported as such.
  ///
  /// The real engine skips the unload while a cancelled job's abandoned task
  /// still owns the pipeline — that task can be inside `WhisperKit(config)` and
  /// about to assign into `pipe`. That skip used to look exactly like a
  /// successful unload from here, and the one caller that matters,
  /// `deleteCaptionModel`, removes ~730 MB the instant this completes: it
  /// deleted weights that were never unloaded, out from under an uninterruptible
  /// download still writing into the same directory. Reporting the refusal is
  /// what lets the delete answer MODEL_IN_USE instead.
  func testARefusedReleaseIsReportedAsRefusedNotAsDone() {
    let fake = FakeTranscriber()
    fake.setEngineBusy(true)
    fake.releaseSucceeds = false
    let service = CaptionsService(transcriber: fake)

    let finished = expectation(description: "release answered")
    var outcome: Bool?
    service.releaseModel {
      outcome = $0
      finished.fulfill()
    }
    wait(for: [finished], timeout: 5)

    XCTAssertEqual(
      outcome, false,
      "the weights were never handed back, so the caller must not delete them")
    XCTAssertEqual(fake.releaseCount, 0)
    XCTAssertTrue(service.isModelLoaded, "the engine still holds it")
  }

  // MARK: - Handing the model back when the job ends

  /// The model must not outlive the job that loaded it.
  ///
  /// A WhisperKit pipeline is several hundred megabytes, and what a user does
  /// next after captioning is usually export the video they just captioned —
  /// the peak-memory moment in this app. When this release was dropped, a user
  /// who generated subtitles and then recorded a 4K screen carried the whole
  /// pipeline through recording, preview and export for the rest of the session.
  func testAFinishedJobHandsTheModelBack() {
    let fake = FakeTranscriber()
    fake.setEngineBusy(true)
    let service = CaptionsService(transcriber: fake)

    let done = expectation(description: "finished")
    service.generateCaptions(
      sources: micOnly(), language: nil, onProgress: { _ in },
      completion: { _ in done.fulfill() })
    wait(for: [done], timeout: 10)

    XCTAssertTrue(
      waitUntil { fake.releaseCount == 1 },
      "the job ended holding the model, so it stays resident for the whole session")
    XCTAssertFalse(service.isModelLoaded)
  }

  /// …but not out from under a cancelled job's abandoned task, and not never.
  ///
  /// The engine REFUSES the unload while that task still owns the pipeline — it
  /// can be inside `WhisperKit(config)`, about to assign into `pipe`. Taking the
  /// weights then is a data race. Treating the refusal as final is the other
  /// half of the trap: the cancelled run is exactly the case where nothing is
  /// going to ask for the model again, so a single attempt strands it for the
  /// rest of the session. The refusal has to mean "not yet".
  func testARefusedReleaseIsRetriedUntilTheDrainLetsGo() {
    let fake = FakeTranscriber()
    fake.setEngineBusy(true)
    fake.releaseSucceeds = false
    let service = CaptionsService(transcriber: fake)

    let done = expectation(description: "finished")
    service.generateCaptions(
      sources: micOnly(), language: nil, onProgress: { _ in },
      completion: { _ in done.fulfill() })
    wait(for: [done], timeout: 10)

    // Long enough for several retries to have come and gone. Nothing may be
    // released while the engine is saying no.
    Thread.sleep(forTimeInterval: 1.0)
    XCTAssertEqual(
      fake.releaseCount, 0,
      "the engine declined, so the weights were taken from a task still using them")
    XCTAssertTrue(service.isModelLoaded)

    // The abandoned task finishes; the engine will hand the model back now.
    fake.releaseSucceeds = true
    XCTAssertTrue(
      waitUntil { fake.releaseCount == 1 },
      "one refusal stranded the model for the rest of the session")
  }

  /// A retry left over from a finished job must not go on asking for weights
  /// that a NEWER job has already taken the engine to use.
  ///
  /// The retry is what makes this reachable at all: a single-attempt release
  /// cannot outlive its own job. Once one exists, a user who cancels a run and
  /// immediately starts another has a loop from the dead job polling the engine
  /// while the live one transcribes — and on the real engine that release is a
  /// `queue.async` that lands the moment the running job hands the queue back,
  /// unloading the pipeline the next pass was about to read.
  ///
  /// Asserted on release ATTEMPTS, not on releases. The refusal is what keeps
  /// the loop alive and observable, so counting only successful unloads would
  /// read zero whether the loop stood down or hammered away.
  func testARetryStandsDownWhileANewJobOwnsTheEngine() {
    let fake = FakeTranscriber()
    // Keeps the first job's retry loop alive, and therefore observable.
    fake.releaseSucceeds = false
    let service = CaptionsService(transcriber: fake)

    let first = expectation(description: "first")
    service.generateCaptions(
      sources: micOnly(), language: nil, onProgress: { _ in },
      completion: { _ in first.fulfill() })
    wait(for: [first], timeout: 10)
    // Consume the first job's engine-entry signal, or the second job's wait
    // below would be satisfied by it and prove nothing.
    XCTAssertEqual(fake.enteredEngine.wait(timeout: .now() + 5), .success)
    XCTAssertTrue(
      waitUntil { fake.releaseAttempts >= 2 },
      "the retry loop never ran, so there is nothing here to stand down")

    // A second job takes the engine and blocks inside it.
    let gate = DispatchSemaphore(value: 0)
    fake.gate = gate
    let second = expectation(description: "second")
    service.generateCaptions(
      sources: micOnly(), language: nil, onProgress: { _ in },
      completion: { _ in second.fulfill() })
    XCTAssertEqual(fake.enteredEngine.wait(timeout: .now() + 5), .success)

    // Let an iteration already in flight finish before taking the reading.
    Thread.sleep(forTimeInterval: 0.5)
    let whileRunning = fake.releaseAttempts
    // Several retry intervals' worth of silence.
    Thread.sleep(forTimeInterval: 1.0)
    XCTAssertEqual(
      fake.releaseAttempts, whileRunning,
      "the dead job's retry kept reaching for the model the live job is transcribing with")

    gate.signal()
    wait(for: [second], timeout: 10)
    fake.releaseSucceeds = true
    XCTAssertTrue(
      waitUntil { fake.releaseCount == 1 },
      "and the job that just ended must still hand the model back")
  }

  // MARK: - One engine, decided once

  /// `transcriber` must not be a `lazy var`.
  ///
  /// Swift's lazy initialisation is not atomic, and this property is first
  /// touched from threads that share no lock: the main thread through `isBusy` /
  /// `isModelLoaded` for the Settings › Storage delete gate, an export preamble
  /// through `releaseModel`, and the service queue when a job starts. A
  /// simultaneous first touch runs the initialiser twice and leaves those
  /// callers holding DIFFERENT engines — the job transcribes on one while the
  /// delete gate asks the other whether the model is loaded, is told no, and
  /// removes 730 MB that Core ML still has mmapped.
  ///
  /// Identity is the only observable difference: every method on the protocol
  /// answers the same for either instance. Constructed without an injected
  /// engine on purpose — injecting one assigns the property in `init` and skips
  /// the lazy path entirely, which is why every other test in this file is blind
  /// to this.
  func testTheEngineIsDecidedOnceEvenWhenThreadsFirstTouchItTogether() {
    for attempt in 1...200 {
      let service = CaptionsService()
      let lock = NSLock()
      var identities: Set<ObjectIdentifier> = []

      DispatchQueue.concurrentPerform(iterations: 8) { _ in
        let identity = service.engineIdentityForTesting
        lock.lock()
        identities.insert(identity)
        lock.unlock()
      }

      XCTAssertEqual(
        identities.count, 1,
        "attempt \(attempt): the service is driving \(identities.count) engines at once")
    }
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
