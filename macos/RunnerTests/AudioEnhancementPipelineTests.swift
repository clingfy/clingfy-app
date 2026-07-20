import AVFoundation
import XCTest

@testable import Clingfy

/// Covers the file-to-file voice-cleanup stage, its wire parsing, and the cache
/// semantics that decide when a cleaned mic is reused versus recomputed.
final class AudioEnhancementPipelineTests: XCTestCase {
  private var workDirectory: URL!

  override func setUpWithError() throws {
    workDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("voice-cleanup-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
  }

  // MARK: - Fixtures

  /// Writes noisy speech to a mono 48 kHz CAF the pipeline can decode.
  @discardableResult
  private func writeNoisyVoice(seconds: Double = 2.0, named name: String = "mic.caf") throws -> URL
  {
    let rate: Float = 48_000
    let count = Int(Double(rate) * seconds)
    var samples = [Float](repeating: 0, count: count)
    var state: UInt32 = 4242
    for i in 0..<count {
      let t = Float(i) / rate
      var voice: Float = 0
      for harmonic in 1...12 {
        voice += sinf(2 * .pi * 140 * Float(harmonic) * t) / Float(harmonic)
      }
      state = state &* 1_103_515_245 &+ 12345
      let noise = (Float((state >> 16) & 0x7fff) / 16384.0 - 1.0) * 0.1
      samples[i] = voice * 0.2 + noise
    }
    return try MicEchoCanceller.writeMonoPCM(
      samples, directory: workDirectory, namePrefix: "fixture-\(name)-")
  }

  private func decodeRms(_ url: URL) throws -> Float {
    let samples = try MicEchoCanceller.decodePCMMono48k(url: url)
    guard !samples.isEmpty else { return 0 }
    let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
    return (sum / Float(samples.count)).squareRoot()
  }

  private func makeProject() throws -> URL {
    let root = workDirectory.appendingPathComponent("Take.clingfyproj", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  // MARK: - Wire parsing

  func testRequestParsesEnabledAndMode() {
    let request = VoiceCleanupRequest.fromFlutter(["enabled": true, "mode": "light"])
    XCTAssertTrue(request.enabled)
    XCTAssertEqual(request.mode, .light)
  }

  func testRequestIsDisabledWhenTheKeyIsAbsentOrMalformed() {
    XCTAssertFalse(VoiceCleanupRequest.fromFlutter(nil).enabled)
    XCTAssertFalse(VoiceCleanupRequest.fromFlutter("nonsense").enabled)
    XCTAssertFalse(VoiceCleanupRequest.fromFlutter([:] as [String: Any]).enabled)
    XCTAssertFalse(VoiceCleanupRequest.fromFlutter(["enabled": false, "mode": "light"]).enabled)
  }

  /// Matches Dart's `CleanupMode.fromWire`, which also falls back to balanced.
  func testUnknownModeFallsBackToBalanced() {
    let request = VoiceCleanupRequest.fromFlutter(["enabled": true, "mode": "ultra"])
    XCTAssertEqual(request.mode, .balanced)
  }

  /// `highQuality` is reserved for a future full-band engine. Until it is
  /// vendored the level must still run — at full RNNoise strength — so a
  /// project saved by a newer build does not silently lose its cleanup.
  func testHighQualityCurrentlyRunsAtFullStrength() {
    XCTAssertEqual(VoiceCleanupMode.highQuality.wetMix, VoiceCleanupMode.balanced.wetMix)
    XCTAssertLessThan(VoiceCleanupMode.light.wetMix, VoiceCleanupMode.balanced.wetMix)
  }

  func testModeWireValuesMatchDart() {
    XCTAssertEqual(VoiceCleanupMode.light.rawValue, "light")
    XCTAssertEqual(VoiceCleanupMode.balanced.rawValue, "balanced")
    XCTAssertEqual(VoiceCleanupMode.highQuality.rawValue, "highQuality")
  }

  // MARK: - Pipeline

  func testEnhanceProducesAQuieterFileAndReportsPositiveReduction() throws {
    let mic = try writeNoisyVoice()
    let result = try AudioEnhancementPipeline.enhance(
      micURL: mic, mode: .balanced, outputDirectory: workDirectory)

    XCTAssertTrue(result.applied)
    XCTAssertNotEqual(result.enhancedMicURL, mic)
    XCTAssertTrue(FileManager.default.fileExists(atPath: result.enhancedMicURL.path))
    XCTAssertGreaterThan(
      result.noiseReductionDb, 0,
      "Positive means quieter. A negative value here would mean the stage added energy.")
    XCTAssertLessThan(try decodeRms(result.enhancedMicURL), try decodeRms(mic))
  }

  func testEnhancePreservesDurationWithinAFrame() throws {
    let mic = try writeNoisyVoice(seconds: 1.5)
    let result = try AudioEnhancementPipeline.enhance(
      micURL: mic, mode: .balanced, outputDirectory: workDirectory)
    let before = try MicEchoCanceller.decodePCMMono48k(url: mic).count
    let after = try MicEchoCanceller.decodePCMMono48k(url: result.enhancedMicURL).count
    XCTAssertEqual(before, after, "Cleanup must not change the mic's length")
  }

  func testStagedOutputUsesItsOwnPrefix() throws {
    let mic = try writeNoisyVoice()
    let result = try AudioEnhancementPipeline.enhance(
      micURL: mic, mode: .balanced, outputDirectory: workDirectory)
    XCTAssertTrue(
      result.enhancedMicURL.lastPathComponent.hasPrefix(
        AudioEnhancementPipeline.stagedFileNamePrefix),
      "Reusing the echo canceller's prefix would let its temp sweep delete this file")
  }

  func testEnhanceThrowsOnAnUndecodableInput() throws {
    let bogus = workDirectory.appendingPathComponent("not-audio.caf")
    try Data("nope".utf8).write(to: bogus)
    XCTAssertThrowsError(
      try AudioEnhancementPipeline.enhance(
        micURL: bogus, mode: .balanced, outputDirectory: workDirectory))
  }

  // MARK: - Cache

  func testDisabledRequestBypassesWithoutTouchingTheCache() throws {
    let mic = try writeNoisyVoice()
    let project = try makeProject()
    let outcome = try EnhancedMicCache.shared.outcome(
      inputMicURL: mic, request: .disabled, projectRoot: project)

    XCTAssertFalse(outcome.result.applied)
    XCTAssertEqual(outcome.result.enhancedMicURL, mic)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: EnhancedMicCache.metadataFileURL(for: project).path))
  }

  func testComputeThenHitServesTheCachedFile() throws {
    let mic = try writeNoisyVoice()
    let project = try makeProject()
    let request = VoiceCleanupRequest(enabled: true, mode: .balanced)

    let first = try EnhancedMicCache.shared.outcome(
      inputMicURL: mic, request: request, projectRoot: project)
    XCTAssertTrue(first.result.applied)
    XCTAssertFalse(first.fromCache)
    XCTAssertTrue(first.cacheOwned)
    XCTAssertEqual(first.result.enhancedMicURL, EnhancedMicCache.enhancedFileURL(for: project))

    let second = try EnhancedMicCache.shared.outcome(
      inputMicURL: mic, request: request, projectRoot: project)
    XCTAssertTrue(second.fromCache)
    XCTAssertEqual(second.result.enhancedMicURL, first.result.enhancedMicURL)
  }

  /// The whole reason this is a separate cache from `CleanedMicCache`: the
  /// output depends on a user setting, so a mode change must not be served a
  /// stale file.
  func testChangingModeInvalidatesTheEntry() throws {
    let mic = try writeNoisyVoice()
    let project = try makeProject()

    _ = try EnhancedMicCache.shared.outcome(
      inputMicURL: mic, request: VoiceCleanupRequest(enabled: true, mode: .balanced),
      projectRoot: project)
    let afterModeChange = EnhancedMicCache.shared.cachedOutcome(
      inputMicURL: mic, request: VoiceCleanupRequest(enabled: true, mode: .light),
      projectRoot: project)

    XCTAssertNil(afterModeChange, "A different strength must recompute, not reuse")
  }

  /// Keying on the INPUT file is what composes with echo cancellation: when
  /// that stage turns on or recomputes, the input identity changes and this
  /// entry must fall out.
  func testChangingTheInputFileInvalidatesTheEntry() throws {
    let mic = try writeNoisyVoice()
    let project = try makeProject()
    let request = VoiceCleanupRequest(enabled: true, mode: .balanced)

    _ = try EnhancedMicCache.shared.outcome(
      inputMicURL: mic, request: request, projectRoot: project)
    XCTAssertNotNil(
      EnhancedMicCache.shared.cachedOutcome(
        inputMicURL: mic, request: request, projectRoot: project))

    let otherMic = try writeNoisyVoice(seconds: 1.0, named: "other")
    XCTAssertNil(
      EnhancedMicCache.shared.cachedOutcome(
        inputMicURL: otherMic, request: request, projectRoot: project),
      "A different input mic must not be served the previous input's cleanup")
  }

  func testMissingCachedFileForcesRecompute() throws {
    let mic = try writeNoisyVoice()
    let project = try makeProject()
    let request = VoiceCleanupRequest(enabled: true, mode: .balanced)

    _ = try EnhancedMicCache.shared.outcome(
      inputMicURL: mic, request: request, projectRoot: project)
    try FileManager.default.removeItem(at: EnhancedMicCache.enhancedFileURL(for: project))

    XCTAssertNil(
      EnhancedMicCache.shared.cachedOutcome(
        inputMicURL: mic, request: request, projectRoot: project),
      "Metadata without its audio file must not report a hit")
  }

  func testCorruptMetadataForcesRecompute() throws {
    let mic = try writeNoisyVoice()
    let project = try makeProject()
    let request = VoiceCleanupRequest(enabled: true, mode: .balanced)

    _ = try EnhancedMicCache.shared.outcome(
      inputMicURL: mic, request: request, projectRoot: project)
    try Data("{".utf8).write(to: EnhancedMicCache.metadataFileURL(for: project))

    XCTAssertNil(
      EnhancedMicCache.shared.cachedOutcome(
        inputMicURL: mic, request: request, projectRoot: project))
  }

  func testStagedFilesAreSweptFromTheDerivedSlot() throws {
    let project = try makeProject()
    let derived = RecordingProjectPaths.derivedDirectoryURL(for: project)
    try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
    let stranded = derived.appendingPathComponent(
      "\(AudioEnhancementPipeline.stagedFileNamePrefix)stale.caf")
    try Data("x".utf8).write(to: stranded)

    EnhancedMicCache.removeStagedFiles(in: derived)

    XCTAssertFalse(FileManager.default.fileExists(atPath: stranded.path))
  }

  /// The echo canceller's own staged files live in the same directory and are
  /// swept by its cache, not this one.
  func testSweepLeavesTheEchoCancellerStagedFilesAlone() throws {
    let project = try makeProject()
    let derived = RecordingProjectPaths.derivedDirectoryURL(for: project)
    try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
    let otherStage = derived.appendingPathComponent("mic-echo-cancelled-stale.caf")
    try Data("x".utf8).write(to: otherStage)

    EnhancedMicCache.removeStagedFiles(in: derived)

    XCTAssertTrue(FileManager.default.fileExists(atPath: otherStage.path))
  }

  func testAsyncOutcomeDeliversOnMain() throws {
    let mic = try writeNoisyVoice(seconds: 1.0)
    let project = try makeProject()
    let expectation = expectation(description: "voice cleanup completes")

    EnhancedMicCache.shared.outcomeAsync(
      inputMicURL: mic, request: VoiceCleanupRequest(enabled: true, mode: .balanced),
      projectRoot: project
    ) { outcome in
      XCTAssertTrue(Thread.isMainThread)
      XCTAssertTrue(outcome.result.applied)
      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 60)
  }

  /// A decode failure must degrade to the un-enhanced mic rather than fail the
  /// preview open, and must not be cached so the next open retries.
  func testAsyncFailureDegradesToTheInputMic() throws {
    let project = try makeProject()
    let bogus = workDirectory.appendingPathComponent("broken.caf")
    try Data("nope".utf8).write(to: bogus)
    let expectation = expectation(description: "degrades")

    EnhancedMicCache.shared.outcomeAsync(
      inputMicURL: bogus, request: VoiceCleanupRequest(enabled: true, mode: .balanced),
      projectRoot: project
    ) { outcome in
      XCTAssertFalse(outcome.result.applied)
      XCTAssertEqual(outcome.result.enhancedMicURL, bogus)
      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 60)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: EnhancedMicCache.metadataFileURL(for: project).path),
      "A transient failure must not be cached")
  }
}
