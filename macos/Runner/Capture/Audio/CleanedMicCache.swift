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
/// into a single compute instead of racing the write. The queue is shared
/// across ALL projects on purpose: it bounds peak memory to ONE
/// decode-everything canceller run at a time (an hour-long recording holds
/// several full 48 kHz float arrays — a few GB — so two concurrent computes
/// could exhaust memory on a small Mac). The cost is that a synchronous
/// caller (the export preamble) can wait behind an unrelated project's
/// in-flight compute; that beachball is rare (it needs a long cache-miss
/// preview of project A overlapping a cache-miss export of project B) and is
/// the accepted price of the hard memory bound.
final class CleanedMicCache {
  static let shared = CleanedMicCache()

  static let cleanedFileName = "mic-cleaned.caf"
  static let metadataFileName = "mic-cleaned.json"

  /// Master gate for the whole echo-cancellation path, read per lookup so a
  /// settings change applies to the very next preview open / export. When it
  /// returns false every entry point serves the RAW mic immediately — no
  /// compute, no cache read — but existing cache files are left in place so
  /// re-enabling is instant. Injectable so tests don't touch UserDefaults.
  static var isEnabledProvider: () -> Bool = { PreferencesStore().micEchoCancellationEnabled }

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
  /// files and algorithm version, else nil. Never computes. When echo
  /// cancellation is disabled this is a synchronous "hit" on the raw mic, so
  /// the preview opens immediately instead of parking on `outcomeAsync`.
  func cachedOutcome(micURL: URL, systemURL: URL, projectRoot: URL) -> Outcome? {
    guard Self.isEnabledProvider() else {
      NativeLogger.i(
        "Audio", "Mic echo cancellation disabled by preference; using the raw mic",
        context: ["project": projectRoot.lastPathComponent])
      return Self.bypassOutcome(micURL: micURL)
    }
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
      // A concurrent request may have filled the cache while we queued — and
      // the preference may have flipped, which `cachedOutcome` also re-checks.
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

  /// Cache-or-compute body. Must run on `computeQueue` (single writer). Tries
  /// to commit into the project's `derived/` slot; on any reason the slot is
  /// unavailable (project gone, unreadable sidecars, read-only bundle) it
  /// falls back to a per-run temp compute that the caller owns — the pre-cache
  /// behavior — so the cleaned mic is still served and the echo never leaks
  /// back in.
  private func computeAndStore(micURL: URL, systemURL: URL, projectRoot: URL) throws -> Outcome {
    let fileManager = FileManager.default
    // Key stats are taken BEFORE the decode so a sidecar replaced mid-compute
    // invalidates the entry (its stats at write time won't match the next read).
    let micStat = Self.fileStat(micURL)
    let systemStat = Self.fileStat(systemURL)

    // Only claim the in-bundle cache slot when the bundle still exists and its
    // sidecars are readable. Gating on `projectRoot` existence stops a queued
    // compute from recreating a `<bundle>.clingfyproj/derived/` HUSK after the
    // user deleted or Finder-renamed the recording while the compute waited.
    let derivedDir = RecordingProjectPaths.derivedDirectoryURL(for: projectRoot)
    var cacheSlotReady = false
    if let micStat, let systemStat,
      fileManager.fileExists(atPath: projectRoot.path)
    {
      do {
        try fileManager.createDirectory(at: derivedDir, withIntermediateDirectories: true)
        // Reclaim any staged CAF a previously crashed/failed compute stranded
        // here (see `removeStagedFiles`). Nothing else sweeps `derived/`, and
        // this queue is the single writer, so this is the safe place to do it.
        Self.removeStagedFiles(in: derivedDir, fileManager: fileManager)
        cacheSlotReady = true
      } catch {
        cacheSlotReady = false
      }
    }

    if cacheSlotReady, let micStat, let systemStat {
      do {
        return try computeIntoCache(
          micURL: micURL, systemURL: systemURL, projectRoot: projectRoot,
          derivedDir: derivedDir, micStat: micStat, systemStat: systemStat,
          fileManager: fileManager)
      } catch MicEchoCanceller.CancelError.writeFailed(let url) {
        // The decode succeeded but writing INTO the bundle failed — the project
        // is on a read-only volume (DMG, network share, permission-stripped
        // copy); `createDirectory` on an existing `derived/` does NOT surface
        // that. The pre-cache code always wrote to the always-writable temp
        // root and served the CLEANED mic here, so match that: retry into temp
        // rather than degrade to the raw (echo-carrying) mic. Sweep any partial
        // staged file first.
        Self.removeStagedFiles(in: derivedDir, fileManager: fileManager)
        NativeLogger.w(
          "Audio", "Cleaned-mic cache write failed (read-only bundle?); computing into temp root",
          context: ["url": url.lastPathComponent, "project": projectRoot.lastPathComponent])
      }
    }

    return try computeIntoTemp(micURL: micURL, systemURL: systemURL, fileManager: fileManager)
  }

  /// Runs the canceller into `derivedDir`, commits the result (moves the CAF
  /// to the stable cache name, writes metadata last as the commit point), and
  /// returns a cache-owned outcome. Propagates `CancelError.writeFailed` so the
  /// caller can fall back to temp.
  private func computeIntoCache(
    micURL: URL, systemURL: URL, projectRoot: URL, derivedDir: URL,
    micStat: FileStat, systemStat: FileStat, fileManager: FileManager
  ) throws -> Outcome {
    let result = try MicEchoCanceller.cancel(
      micURL: micURL, systemURL: systemURL, outputDirectory: derivedDir)
    let cleanedURL = Self.cleanedFileURL(for: projectRoot)
    var storedResult = result
    if result.applied {
      // Same-volume move = atomic rename; only this queue writes here.
      try? fileManager.removeItem(at: cleanedURL)
      try fileManager.moveItem(at: result.cleanedMicURL, to: cleanedURL)
      storedResult = MicEchoCanceller.Result(
        cleanedMicURL: cleanedURL, applied: true,
        bleedCorrelation: result.bleedCorrelation, delayMs: result.delayMs,
        reductionDb: result.reductionDb)
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
    // validate it before touching the CAF, so a crash between the move above
    // and this write just means a recompute next open.
    if let data = try? JSONEncoder().encode(entry) {
      try? data.write(to: Self.metadataFileURL(for: projectRoot), options: .atomic)
    }
    return Outcome(result: storedResult, cacheOwned: true, fromCache: false)
  }

  /// Per-run temp compute, caller owns the produced file — byte-identical to
  /// the pre-cache behavior. Nothing is persisted, so a transient failure that
  /// reached here is retried on the next open.
  private func computeIntoTemp(micURL: URL, systemURL: URL, fileManager: FileManager) throws
    -> Outcome
  {
    let tempRoot = AppPaths.tempRoot()
    try? fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    let result = try MicEchoCanceller.cancel(
      micURL: micURL, systemURL: systemURL, outputDirectory: tempRoot)
    return Outcome(result: result, cacheOwned: false, fromCache: false)
  }

  /// The canceller stages its output as `mic-echo-cancelled-<uuid>.caf` before
  /// we rename it to the stable cache name. A crash or a write failure between
  /// the stage and the rename would strand that file inside `derived/`, where
  /// no other sweep looks. Clearing it whenever a compute (re)enters the slot
  /// is the backstop.
  static func removeStagedFiles(in directory: URL, fileManager: FileManager = .default) {
    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else { return }
    for url in entries where url.lastPathComponent.hasPrefix("mic-echo-cancelled-") {
      try? fileManager.removeItem(at: url)
    }
  }

  /// The disabled-path outcome: the untouched raw mic, shaped exactly like a
  /// negative ("no bleed") result so no caller special-cases it. `cacheOwned`
  /// because no new file exists for the caller to own or clean up.
  static func bypassOutcome(micURL: URL) -> Outcome {
    Outcome(
      result: MicEchoCanceller.Result(
        cleanedMicURL: micURL, applied: false, bleedCorrelation: 0, delayMs: 0, reductionDb: 0),
      cacheOwned: true, fromCache: false)
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
