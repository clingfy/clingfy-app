import AVFoundation
import XCTest

@testable import Clingfy

/// Tests for the per-project cleaned-mic cache. The cache sits in front of
/// `MicEchoCanceller.cancel` (already covered by `MicEchoCancellerTests`), so
/// these tests assert CACHING behavior — key matching, invalidation,
/// negative-result caching, commit atomics, coalescing — not audio quality.
final class CleanedMicCacheTests: XCTestCase {

  private var projectRoot: URL!
  private var savedIsEnabledProvider: (() -> Bool)!

  override func setUpWithError() throws {
    // The user preference defaults to OFF; pin the gate ON so the caching
    // behavior under test is reachable regardless of UserDefaults state.
    savedIsEnabledProvider = CleanedMicCache.isEnabledProvider
    CleanedMicCache.isEnabledProvider = { true }
    projectRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent("Test.clingfyproj", isDirectory: true)
    try FileManager.default.createDirectory(
      at: projectRoot.appendingPathComponent("capture", isDirectory: true),
      withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    CleanedMicCache.isEnabledProvider = savedIsEnabledProvider
    try? FileManager.default.removeItem(at: projectRoot.deletingLastPathComponent())
  }

  // Deterministic white-ish noise in [-1, 1] (seeded LCG) so tests are stable.
  private func noise(_ count: Int, seed: UInt64) -> [Float] {
    var state = seed &+ 0x9E37_79B9_7F4A_7C15
    var out = [Float](repeating: 0, count: count)
    for i in 0..<count {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      let bits = UInt32(truncatingIfNeeded: state >> 32)
      out[i] = (Float(bits) / Float(UInt32.max)) * 2 - 1
    }
    return out
  }

  private func writeCAF(_ samples: [Float], name: String) throws -> URL {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: MicEchoCanceller.sampleRate, channels: 1,
      interleaved: false)!
    let url = projectRoot.appendingPathComponent("capture/\(name)", isDirectory: false)
    try? FileManager.default.removeItem(at: url)
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = AVAudioPCMBuffer(
      pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer {
      buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
    }
    try file.write(from: buffer)
    return url
  }

  /// mic = voice + delayed scaled system → real bleed the canceller cancels.
  private func writeBleedPair(micSeed: UInt64 = 7, systemSeed: UInt64 = 8) throws -> (
    mic: URL, system: URL
  ) {
    let n = 48_000
    let voice = noise(n, seed: micSeed)
    let system = noise(n, seed: systemSeed)
    let delay = 2_640  // ~55 ms at 48 kHz
    var mic = voice
    for i in delay..<n { mic[i] = voice[i] + 0.6 * system[i - delay] }
    return (try writeCAF(mic, name: "mic.caf"), try writeCAF(system, name: "system.caf"))
  }

  /// Independent mic/system → no bleed, canceller is a no-op.
  private func writeIndependentPair() throws -> (mic: URL, system: URL) {
    let n = 48_000
    return (
      try writeCAF(noise(n, seed: 9), name: "mic.caf"),
      try writeCAF(noise(n, seed: 10), name: "system.caf")
    )
  }

  /// Entry whose key matches the CURRENT files on disk, at the given version.
  private func matchingEntry(algorithmVersion: Int, mic: URL, system: URL)
    -> CleanedMicCache.Entry
  {
    let micStat = CleanedMicCache.fileStat(mic)!
    let systemStat = CleanedMicCache.fileStat(system)!
    return CleanedMicCache.Entry(
      algorithmVersion: algorithmVersion,
      micFileSize: micStat.size, micModifiedMs: micStat.modifiedMs,
      systemFileSize: systemStat.size, systemModifiedMs: systemStat.modifiedMs,
      applied: false, bleedCorrelation: 0.05, delayMs: 0, reductionDb: 0)
  }

  // MARK: - Miss → compute → hit

  func testMissComputesCachesAndHits() throws {
    let (mic, system) = try writeBleedPair()
    let cache = CleanedMicCache()

    XCTAssertNil(
      cache.cachedOutcome(micURL: mic, systemURL: system, projectRoot: projectRoot),
      "fresh project must be a miss")

    let computed = try cache.outcome(micURL: mic, systemURL: system, projectRoot: projectRoot)
    XCTAssertTrue(computed.result.applied, "the synthetic bleed must be cancelled")
    XCTAssertFalse(computed.fromCache)
    XCTAssertTrue(computed.cacheOwned, "cache slot was available → cache owns the file")
    XCTAssertEqual(
      computed.result.cleanedMicURL, CleanedMicCache.cleanedFileURL(for: projectRoot),
      "the cleaned mic must be committed to derived/ under the stable cache name")
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: CleanedMicCache.metadataFileURL(for: projectRoot).path))

    let hit = cache.cachedOutcome(micURL: mic, systemURL: system, projectRoot: projectRoot)
    XCTAssertNotNil(hit)
    XCTAssertTrue(hit!.fromCache)
    XCTAssertEqual(hit!.result.cleanedMicURL, computed.result.cleanedMicURL)
    XCTAssertEqual(hit!.result.applied, true)
    XCTAssertEqual(hit!.result.bleedCorrelation, computed.result.bleedCorrelation)
    XCTAssertEqual(hit!.result.reductionDb, computed.result.reductionDb)

    let again = try cache.outcome(micURL: mic, systemURL: system, projectRoot: projectRoot)
    XCTAssertTrue(again.fromCache, "second outcome() must be served from disk")
  }

  func testCachedAudioMatchesFreshCancellerOutput() throws {
    let (mic, system) = try writeBleedPair()
    let cache = CleanedMicCache()
    let outcome = try cache.outcome(micURL: mic, systemURL: system, projectRoot: projectRoot)

    let outDir = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: outDir) }
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let fresh = try MicEchoCanceller.cancel(
      micURL: mic, systemURL: system, outputDirectory: outDir)

    let cachedSamples = try MicEchoCanceller.decodePCMMono48k(url: outcome.result.cleanedMicURL)
    let freshSamples = try MicEchoCanceller.decodePCMMono48k(url: fresh.cleanedMicURL)
    XCTAssertEqual(
      cachedSamples, freshSamples,
      "the cache must store exactly what the canceller produced (deterministic algorithm)")
  }

  // MARK: - Negative-result caching

  func testNoBleedNegativeResultIsCached() throws {
    let (mic, system) = try writeIndependentPair()
    let cache = CleanedMicCache()

    let computed = try cache.outcome(micURL: mic, systemURL: system, projectRoot: projectRoot)
    XCTAssertFalse(computed.result.applied)
    XCTAssertEqual(computed.result.cleanedMicURL, mic, "no bleed → the raw mic passes through")
    XCTAssertTrue(computed.cacheOwned)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: CleanedMicCache.cleanedFileURL(for: projectRoot).path),
      "a negative result writes no CAF")

    // The expensive part of a no-bleed project is the ANALYSIS; the cache must
    // remember the negative verdict, not just cleaned files.
    let hit = cache.cachedOutcome(micURL: mic, systemURL: system, projectRoot: projectRoot)
    XCTAssertNotNil(hit, "the negative result must be served from cache")
    XCTAssertFalse(hit!.result.applied)
    XCTAssertEqual(hit!.result.cleanedMicURL, mic)
  }

  func testStalePositiveCafRemovedWhenRecomputeFindsNoBleed() throws {
    let (mic, system) = try writeBleedPair()
    let cache = CleanedMicCache()
    _ = try cache.outcome(micURL: mic, systemURL: system, projectRoot: projectRoot)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: CleanedMicCache.cleanedFileURL(for: projectRoot).path))

    // The sidecars change to an independent (no-bleed) pair → the recompute
    // must retract the stale positive CAF alongside the new negative entry.
    let (mic2, system2) = try writeIndependentPair()
    let recomputed = try cache.outcome(micURL: mic2, systemURL: system2, projectRoot: projectRoot)
    XCTAssertFalse(recomputed.result.applied)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: CleanedMicCache.cleanedFileURL(for: projectRoot).path),
      "a stale cleaned CAF must not survive a negative recompute")
  }

  // MARK: - Invalidation

  func testModifiedSidecarInvalidates() throws {
    let (mic, system) = try writeBleedPair()
    let cache = CleanedMicCache()
    _ = try cache.outcome(micURL: mic, systemURL: system, projectRoot: projectRoot)
    XCTAssertNotNil(cache.cachedOutcome(micURL: mic, systemURL: system, projectRoot: projectRoot))

    // Rewrite the mic in place with a different LENGTH (different byte size,
    // so this can't depend on filesystem mtime resolution).
    _ = try writeCAF(noise(24_000, seed: 31), name: "mic.caf")

    XCTAssertNil(
      cache.cachedOutcome(micURL: mic, systemURL: system, projectRoot: projectRoot),
      "a replaced sidecar must invalidate the entry")
    let recomputed = try cache.outcome(micURL: mic, systemURL: system, projectRoot: projectRoot)
    XCTAssertFalse(recomputed.fromCache, "outcome() must recompute after invalidation")
  }

  func testAlgorithmVersionMismatchInvalidates() throws {
    let (mic, system) = try writeIndependentPair()
    let cache = CleanedMicCache()
    _ = try cache.outcome(micURL: mic, systemURL: system, projectRoot: projectRoot)
    XCTAssertNotNil(cache.cachedOutcome(micURL: mic, systemURL: system, projectRoot: projectRoot))

    // Simulate an entry written by an older app version: same key stats, older
    // algorithm. It must read as a miss, never as stale audio served fresh.
    let entry = matchingEntry(
      algorithmVersion: MicEchoCanceller.algorithmVersion - 1, mic: mic, system: system)
    let data = try JSONEncoder().encode(entry)
    try data.write(to: CleanedMicCache.metadataFileURL(for: projectRoot), options: .atomic)

    XCTAssertNil(
      cache.cachedOutcome(micURL: mic, systemURL: system, projectRoot: projectRoot),
      "an older algorithmVersion must invalidate the entry")
  }

  func testCorruptMetadataIsMissAndRecovers() throws {
    let (mic, system) = try writeIndependentPair()
    let cache = CleanedMicCache()
    try FileManager.default.createDirectory(
      at: RecordingProjectPaths.derivedDirectoryURL(for: projectRoot),
      withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: CleanedMicCache.metadataFileURL(for: projectRoot))

    XCTAssertNil(cache.cachedOutcome(micURL: mic, systemURL: system, projectRoot: projectRoot))
    let recovered = try cache.outcome(micURL: mic, systemURL: system, projectRoot: projectRoot)
    XCTAssertFalse(recovered.fromCache)
    XCTAssertNotNil(
      cache.cachedOutcome(micURL: mic, systemURL: system, projectRoot: projectRoot),
      "outcome() must overwrite corrupt metadata with a fresh entry")
  }

  func testAppliedEntryWithMissingCafIsMiss() throws {
    let (mic, system) = try writeBleedPair()
    let cache = CleanedMicCache()
    _ = try cache.outcome(micURL: mic, systemURL: system, projectRoot: projectRoot)

    try FileManager.default.removeItem(at: CleanedMicCache.cleanedFileURL(for: projectRoot))
    XCTAssertNil(
      cache.cachedOutcome(micURL: mic, systemURL: system, projectRoot: projectRoot),
      "an applied entry whose CAF is gone must be a miss, not a broken hit")
  }

  // MARK: - Fallback paths (cacheOwned == false)

  /// When the cache slot can't be created (here: a plain file sits where
  /// `derived/` should be, so `createDirectory` throws), the compute must fall
  /// back to a caller-owned temp file and write no metadata — the two-consumer
  /// ownership contract (exporter registers for cleanup, preview adopts by the
  /// `mic-echo-cancelled-` prefix) depends on `cacheOwned == false` here.
  func testUnwritableDerivedFallsBackToTempCompute() throws {
    let (mic, system) = try writeBleedPair()
    // Block `derived/` with a regular file so createDirectory can't make it.
    try Data("blocker".utf8).write(
      to: RecordingProjectPaths.derivedDirectoryURL(for: projectRoot))
    let cache = CleanedMicCache()

    let outcome = try cache.outcome(micURL: mic, systemURL: system, projectRoot: projectRoot)
    addTeardownBlock {
      if !outcome.cacheOwned { try? FileManager.default.removeItem(at: outcome.result.cleanedMicURL) }
    }

    XCTAssertTrue(outcome.result.applied, "the bleed must still be cancelled")
    XCTAssertFalse(outcome.cacheOwned, "no cache slot ⇒ the caller owns the temp file")
    XCTAssertTrue(
      outcome.result.cleanedMicURL.lastPathComponent.hasPrefix("mic-echo-cancelled-"),
      "a caller-owned file must carry the per-run temp prefix the consumers key on")
    XCTAssertNotEqual(
      outcome.result.cleanedMicURL, CleanedMicCache.cleanedFileURL(for: projectRoot))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: CleanedMicCache.metadataFileURL(for: projectRoot).path),
      "a fallback compute must not write cache metadata")
  }

  /// A read-only bundle (DMG / network share / permission-stripped copy) makes
  /// the write INTO `derived/` fail even though `createDirectory` on the
  /// existing dir succeeds. The canceller output must still be served (from
  /// temp) — degrading to the raw mic would put the speaker→mic echo back into
  /// the mix, the exact regression this fallback prevents.
  func testReadOnlyBundleStillServesCleanedMicFromTemp() throws {
    let (mic, system) = try writeBleedPair()
    let derived = RecordingProjectPaths.derivedDirectoryURL(for: projectRoot)
    try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o555], ofItemAtPath: derived.path)
    addTeardownBlock {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: derived.path)
    }
    // Skip if this host can't actually enforce the read-only dir (rare, but
    // keeps the suite non-flaky rather than asserting on an unverifiable state).
    let probe = derived.appendingPathComponent("write-probe", isDirectory: false)
    if (try? Data("x".utf8).write(to: probe)) != nil {
      try? FileManager.default.removeItem(at: probe)
      throw XCTSkip("filesystem did not enforce a read-only directory")
    }

    let cache = CleanedMicCache()
    let outcome = try cache.outcome(micURL: mic, systemURL: system, projectRoot: projectRoot)
    addTeardownBlock {
      if !outcome.cacheOwned { try? FileManager.default.removeItem(at: outcome.result.cleanedMicURL) }
    }

    XCTAssertTrue(outcome.result.applied, "the cleaned mic must still be produced")
    XCTAssertFalse(outcome.cacheOwned, "a read-only bundle falls back to a caller-owned temp file")
    XCTAssertTrue(
      outcome.result.cleanedMicURL.lastPathComponent.hasPrefix("mic-echo-cancelled-"))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: CleanedMicCache.metadataFileURL(for: projectRoot).path),
      "a failed cache write must not leave metadata behind")
  }

  /// A crash or write failure between staging (`mic-echo-cancelled-<uuid>.caf`)
  /// and the rename strands the staged file in `derived/`, which no other sweep
  /// scans. The next compute into the slot must reclaim it.
  func testStagedStrayFilesSweptOnNextCompute() throws {
    let (mic, system) = try writeBleedPair()
    let derived = RecordingProjectPaths.derivedDirectoryURL(for: projectRoot)
    try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
    let stray = derived.appendingPathComponent(
      "mic-echo-cancelled-STRAY.caf", isDirectory: false)
    try Data(repeating: 0, count: 1024).write(to: stray)

    let cache = CleanedMicCache()
    _ = try cache.outcome(micURL: mic, systemURL: system, projectRoot: projectRoot)

    XCTAssertFalse(
      FileManager.default.fileExists(atPath: stray.path),
      "a stranded staged CAF must be reclaimed when a compute re-enters the slot")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: CleanedMicCache.cleanedFileURL(for: projectRoot).path),
      "the real cleaned mic is still committed under the stable name")
  }

  // MARK: - Coalescing

  func testConcurrentRequestsCoalesceIntoOneCompute() throws {
    let (mic, system) = try writeBleedPair()
    let cache = CleanedMicCache()

    let first = expectation(description: "first outcome")
    let second = expectation(description: "second outcome")
    var outcomes: [CleanedMicCache.Outcome] = []
    let lock = NSLock()
    for exp in [first, second] {
      DispatchQueue.global().async {
        let out = try? cache.outcome(micURL: mic, systemURL: system, projectRoot: self.projectRoot)
        lock.lock()
        if let out { outcomes.append(out) }
        lock.unlock()
        exp.fulfill()
      }
    }
    wait(for: [first, second], timeout: 60)

    XCTAssertEqual(outcomes.count, 2)
    for out in outcomes {
      XCTAssertTrue(out.result.applied)
      XCTAssertEqual(out.result.cleanedMicURL, CleanedMicCache.cleanedFileURL(for: projectRoot))
    }
    XCTAssertEqual(
      outcomes.filter { !$0.fromCache }.count, 1,
      "exactly one request computes; the one that queued behind it must re-check and hit")
  }

  // MARK: - Async wrapper

  func testOutcomeAsyncDeliversOnMainThread() throws {
    let (mic, system) = try writeIndependentPair()
    let cache = CleanedMicCache()
    let done = expectation(description: "completion")
    cache.outcomeAsync(micURL: mic, systemURL: system, projectRoot: projectRoot) { outcome in
      XCTAssertTrue(Thread.isMainThread, "the preview consumes this on the main thread")
      XCTAssertFalse(outcome.result.applied)
      XCTAssertEqual(outcome.result.cleanedMicURL, mic)
      done.fulfill()
    }
    wait(for: [done], timeout: 60)
  }

  func testOutcomeAsyncDegradesToRawMicOnDecodeFailure() throws {
    let mic = projectRoot.appendingPathComponent("capture/mic.caf", isDirectory: false)
    try Data("not audio".utf8).write(to: mic)
    let system = projectRoot.appendingPathComponent("capture/system.caf", isDirectory: false)
    try Data("not audio".utf8).write(to: system)
    let cache = CleanedMicCache()

    let done = expectation(description: "completion")
    cache.outcomeAsync(micURL: mic, systemURL: system, projectRoot: projectRoot) { outcome in
      XCTAssertFalse(outcome.result.applied)
      XCTAssertEqual(
        outcome.result.cleanedMicURL, mic,
        "a decode failure must degrade to the raw mic, never fail the open")
      done.fulfill()
    }
    wait(for: [done], timeout: 60)

    XCTAssertNil(
      cache.cachedOutcome(micURL: mic, systemURL: system, projectRoot: projectRoot),
      "failures are not cached — the next open retries")
  }

  // MARK: - Preference gate (echo cancellation disabled)

  func testDisabledPreferenceServesRawMicWithoutComputing() throws {
    let (mic, system) = try writeBleedPair()
    let cache = CleanedMicCache()
    CleanedMicCache.isEnabledProvider = { false }

    let lookup = cache.cachedOutcome(micURL: mic, systemURL: system, projectRoot: projectRoot)
    XCTAssertNotNil(
      lookup, "disabled must read as a synchronous hit so the preview opens without parking")
    XCTAssertFalse(lookup!.result.applied)
    XCTAssertEqual(lookup!.result.cleanedMicURL, mic, "the raw mic, untouched")
    XCTAssertTrue(lookup!.cacheOwned, "no new file exists for the caller to own")

    let outcome = try cache.outcome(micURL: mic, systemURL: system, projectRoot: projectRoot)
    XCTAssertFalse(outcome.result.applied)
    XCTAssertEqual(outcome.result.cleanedMicURL, mic)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: CleanedMicCache.metadataFileURL(for: projectRoot).path),
      "the disabled path must never compute or write cache files")
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: CleanedMicCache.cleanedFileURL(for: projectRoot).path))
  }

  func testDisabledPreferenceLeavesCacheIntactAndReenableHitsInstantly() throws {
    let (mic, system) = try writeBleedPair()
    let cache = CleanedMicCache()

    let computed = try cache.outcome(micURL: mic, systemURL: system, projectRoot: projectRoot)
    XCTAssertTrue(computed.result.applied, "precondition: a real cached cancellation exists")

    CleanedMicCache.isEnabledProvider = { false }
    let disabled = try cache.outcome(micURL: mic, systemURL: system, projectRoot: projectRoot)
    XCTAssertFalse(disabled.result.applied)
    XCTAssertEqual(
      disabled.result.cleanedMicURL, mic,
      "disabled must serve the raw mic even when a valid cleaned cache exists")
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: CleanedMicCache.cleanedFileURL(for: projectRoot).path),
      "disabling must not destroy the cache")

    CleanedMicCache.isEnabledProvider = { true }
    let reenabled = cache.cachedOutcome(micURL: mic, systemURL: system, projectRoot: projectRoot)
    XCTAssertNotNil(reenabled, "re-enabling must hit the preserved cache, no recompute")
    XCTAssertTrue(reenabled!.fromCache)
    XCTAssertTrue(reenabled!.result.applied)
    XCTAssertEqual(reenabled!.result.cleanedMicURL, computed.result.cleanedMicURL)
  }
}
