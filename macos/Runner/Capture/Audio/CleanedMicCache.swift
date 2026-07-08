import AVFoundation
import Foundation

/// Per-project disk cache for `MicEchoCanceller.cancel` output.
///
/// The canceller is O(recording length) — full decode of both sidecars, a
/// windowed delay search, and a 512-tap NLMS pass — and its output depends
/// ONLY on the two sidecar files and the algorithm version, never on gain or
/// any user setting (preview applies gain as a live audio mix, export bakes it
/// separately via `bakeGain`). So the cleaned mic is computed once per
/// recording and reused by every preview open AND every export.
///
/// Layout, inside the project bundle so the cache dies atomically with the
/// project (`derived/` is the designed home for rebuildable artifacts — see
/// `RecordingProjectPaths.rebuildableProjectArtifactURLs`):
///
///   derived/mic-cleaned.caf   — the cleaned mic (present only when bleed was
///                               actually cancelled)
///   derived/mic-cleaned.json  — cache key + result metadata. Also records the
///                               NEGATIVE result: "no bleed detected"
///                               (headphones, silent mic) pays the full
///                               analysis cost yet produces no file, so it must
///                               be cached too or those projects never benefit.
///
/// The file names deliberately do NOT start with `mic-echo-cancelled-`: that
/// prefix means "per-run temp file" — the export sweeps it from `Caches/Temp`
/// with no age gate and the preview adopts-and-deletes it — while cache files
/// are owned here and must survive both.
///
/// Concurrency: every compute runs on one serial background queue and
/// re-checks the cache once it reaches the queue, so concurrent requests for
/// the same project (preview open + export start, rapid re-opens) coalesce
/// into a single compute instead of racing the write. The serial queue also
/// bounds peak memory to one decode-everything canceller run at a time.
final class CleanedMicCache {
  static let shared = CleanedMicCache()

  static let cleanedFileName = "mic-cleaned.caf"
  static let metadataFileName = "mic-cleaned.json"

  /// A lookup/compute result plus who owns the produced file's lifetime.
  struct Outcome {
    let result: MicEchoCanceller.Result
    /// True when `result.cleanedMicURL` is the cache-owned file in `derived/`
    /// (or no new file was produced at all): the caller must NOT delete it or
    /// register it for temp cleanup. False when caching was unavailable and
    /// the caller received a per-run temp file it owns, exactly like the
    /// pre-cache behavior.
    let cacheOwned: Bool
    /// True when served from disk without recomputing.
    let fromCache: Bool
  }

  /// On-disk metadata: the cache key (sidecar identity + algorithm version)
  /// and the cached canceller result.
  struct Entry: Codable, Equatable {
    let algorithmVersion: Int
    let micFileSize: Int64
    let micModifiedMs: Int64
    let systemFileSize: Int64
    let systemModifiedMs: Int64
    let applied: Bool
    let bleedCorrelation: Float
    let delayMs: Double
    let reductionDb: Float
  }

  private let computeQueue = DispatchQueue(
    label: "com.clingfy.audio.cleaned-mic-cache", qos: .userInitiated)

  static func cleanedFileURL(for projectRoot: URL) -> URL {
    RecordingProjectPaths.derivedDirectoryURL(for: projectRoot)
      .appendingPathComponent(cleanedFileName, isDirectory: false)
  }

  static func metadataFileURL(for projectRoot: URL) -> URL {
    RecordingProjectPaths.derivedDirectoryURL(for: projectRoot)
      .appendingPathComponent(metadataFileName, isDirectory: false)
  }

  // MARK: - Lookup (fast: two stats + a tiny JSON read; safe on the main thread)

  /// Returns the cached outcome when the metadata matches the current sidecar
  /// files and algorithm version, else nil. Never computes.
  func cachedOutcome(micURL: URL, systemURL: URL, projectRoot: URL) -> Outcome? {
    guard let data = try? Data(contentsOf: Self.metadataFileURL(for: projectRoot)),
      let entry = try? JSONDecoder().decode(Entry.self, from: data),
      entry.algorithmVersion == MicEchoCanceller.algorithmVersion,
      let micStat = Self.fileStat(micURL),
      let systemStat = Self.fileStat(systemURL),
      entry.micFileSize == micStat.size,
      entry.micModifiedMs == micStat.modifiedMs,
      entry.systemFileSize == systemStat.size,
      entry.systemModifiedMs == systemStat.modifiedMs
    else { return nil }
    let cleanedURL = Self.cleanedFileURL(for: projectRoot)
    if entry.applied {
      guard FileManager.default.fileExists(atPath: cleanedURL.path) else { return nil }
      return Outcome(
        result: MicEchoCanceller.Result(
          cleanedMicURL: cleanedURL, applied: true,
          bleedCorrelation: entry.bleedCorrelation, delayMs: entry.delayMs,
          reductionDb: entry.reductionDb),
        cacheOwned: true, fromCache: true)
    }
    return Outcome(
      result: MicEchoCanceller.Result(
        cleanedMicURL: micURL, applied: false,
        bleedCorrelation: entry.bleedCorrelation, delayMs: entry.delayMs,
        reductionDb: entry.reductionDb),
      cacheOwned: true, fromCache: true)
  }

  // MARK: - Compute

  /// Cache-or-compute, blocking. On a hit this returns immediately; on a miss
  /// it waits for (or joins) the serial compute. Callers that must not block
  /// use `outcomeAsync`. Throws only genuine decode/write failures, so the
  /// caller can degrade to the raw mic exactly as before.
  func outcome(micURL: URL, systemURL: URL, projectRoot: URL) throws -> Outcome {
    if let hit = cachedOutcome(micURL: micURL, systemURL: systemURL, projectRoot: projectRoot) {
      return hit
    }
    return try computeQueue.sync {
      // A concurrent request may have filled the cache while we queued.
      if let hit = cachedOutcome(micURL: micURL, systemURL: systemURL, projectRoot: projectRoot) {
        return hit
      }
      return try computeAndStore(micURL: micURL, systemURL: systemURL, projectRoot: projectRoot)
    }
  }

  /// Cache-or-compute off the calling thread; `completion` runs on MAIN. A
  /// compute failure degrades to the raw mic (`applied == false`, not cached,
  /// so a transient failure is retried on the next open) — the preview must
  /// never fail to open over echo cancellation.
  func outcomeAsync(
    micURL: URL, systemURL: URL, projectRoot: URL,
    completion: @escaping (Outcome) -> Void
  ) {
    computeQueue.async { [self] in
      var out: Outcome
      if let hit = cachedOutcome(micURL: micURL, systemURL: systemURL, projectRoot: projectRoot) {
        out = hit
      } else {
        do {
          out = try computeAndStore(
            micURL: micURL, systemURL: systemURL, projectRoot: projectRoot)
        } catch {
          NativeLogger.w(
            "Audio", "Mic echo cancellation failed; degrading to the raw mic",
            context: ["error": "\(error)", "project": projectRoot.lastPathComponent])
          out = Outcome(
            result: MicEchoCanceller.Result(
              cleanedMicURL: micURL, applied: false, bleedCorrelation: 0, delayMs: 0,
              reductionDb: 0),
            cacheOwned: true, fromCache: false)
        }
      }
      let outcome = out
      DispatchQueue.main.async { completion(outcome) }
    }
  }

  // MARK: - Internals

  /// Runs the canceller and commits the result into `derived/`. Must run on
  /// `computeQueue` (single writer). The canceller stages its output CAF
  /// directly inside `derived/` — NOT `Caches/Temp`, where the export's stale
  /// sweep deletes `mic-echo-cancelled-*` with no age gate and could reap a
  /// finished-but-not-yet-renamed compute.
  private func computeAndStore(micURL: URL, systemURL: URL, projectRoot: URL) throws -> Outcome {
    let fileManager = FileManager.default
    let derivedDir = RecordingProjectPaths.derivedDirectoryURL(for: projectRoot)
    var cacheUsable = true
    do {
      try fileManager.createDirectory(at: derivedDir, withIntermediateDirectories: true)
    } catch {
      cacheUsable = false
    }
    // Key stats are taken BEFORE the decode so a sidecar replaced mid-compute
    // invalidates the entry (its stats at write time won't match the next read).
    let micStat = Self.fileStat(micURL)
    let systemStat = Self.fileStat(systemURL)
    if micStat == nil || systemStat == nil { cacheUsable = false }

    guard cacheUsable, let micStat, let systemStat else {
      // No usable cache slot: per-run temp compute, caller owns the file —
      // byte-identical to the pre-cache behavior.
      let tempRoot = AppPaths.tempRoot()
      try? fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
      let result = try MicEchoCanceller.cancel(
        micURL: micURL, systemURL: systemURL, outputDirectory: tempRoot)
      return Outcome(result: result, cacheOwned: false, fromCache: false)
    }

    let result = try MicEchoCanceller.cancel(
      micURL: micURL, systemURL: systemURL, outputDirectory: derivedDir)
    let cleanedURL = Self.cleanedFileURL(for: projectRoot)
    var storedResult = result
    if result.applied {
      do {
        // Same-volume move = atomic rename; only this queue writes here.
        try? fileManager.removeItem(at: cleanedURL)
        try fileManager.moveItem(at: result.cleanedMicURL, to: cleanedURL)
        storedResult = MicEchoCanceller.Result(
          cleanedMicURL: cleanedURL, applied: true,
          bleedCorrelation: result.bleedCorrelation, delayMs: result.delayMs,
          reductionDb: result.reductionDb)
      } catch {
        // Couldn't claim the cache slot — hand the staged file to the caller
        // unchanged; its `mic-echo-cancelled-` name keeps the caller-owned
        // temp-file lifecycle working.
        NativeLogger.w(
          "Audio", "Cleaned-mic cache write failed; result is uncached this run",
          context: ["error": "\(error)", "project": projectRoot.lastPathComponent])
        return Outcome(result: result, cacheOwned: false, fromCache: false)
      }
    } else {
      // A stale positive from an earlier sidecar state must not survive next
      // to a fresh "no bleed" entry.
      try? fileManager.removeItem(at: cleanedURL)
    }

    let entry = Entry(
      algorithmVersion: MicEchoCanceller.algorithmVersion,
      micFileSize: micStat.size, micModifiedMs: micStat.modifiedMs,
      systemFileSize: systemStat.size, systemModifiedMs: systemStat.modifiedMs,
      applied: result.applied,
      bleedCorrelation: result.bleedCorrelation, delayMs: result.delayMs,
      reductionDb: result.reductionDb)
    // Metadata is the commit point, written last and atomically: readers
    // validate it before touching the CAF, so a crash between the moves above
    // and this write just means a recompute next open.
    if let data = try? JSONEncoder().encode(entry) {
      try? data.write(to: Self.metadataFileURL(for: projectRoot), options: .atomic)
    }
    return Outcome(result: storedResult, cacheOwned: true, fromCache: false)
  }

  struct FileStat: Equatable {
    let size: Int64
    let modifiedMs: Int64
  }

  static func fileStat(_ url: URL) -> FileStat? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
      let size = (attrs[.size] as? NSNumber)?.int64Value,
      let modified = attrs[.modificationDate] as? Date
    else { return nil }
    return FileStat(
      size: size, modifiedMs: Int64((modified.timeIntervalSince1970 * 1000.0).rounded()))
  }
}
