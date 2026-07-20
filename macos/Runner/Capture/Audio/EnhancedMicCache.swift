import Foundation

/// Per-project disk cache for `AudioEnhancementPipeline.enhance` output — the
/// voice-cleanup (noise reduction) counterpart to `CleanedMicCache`.
///
/// It is a SEPARATE cache rather than another stage inside `CleanedMicCache`
/// for two reasons:
///
///  - `CleanedMicCache`'s documented invariant is that its output depends only
///    on the two sidecars and the algorithm version, never on a user setting.
///    Voice cleanup has a user-chosen strength, so folding it in would break
///    that invariant and serve stale audio after a mode change.
///  - Echo cancellation is the more expensive pass. Changing the cleanup mode
///    must not force it to run again.
///
/// Layout, alongside the echo-cancellation cache inside the project bundle:
///
///   derived/mic-enhanced.caf   — the denoised mic
///   derived/mic-enhanced.json  — cache key + result metadata
///
/// The cache key is the INPUT file's identity (size + mtime) plus the mode and
/// both version numbers. Keying on the input file rather than on the raw
/// sidecar is what makes this composable: the input is the echo-cancelled mic
/// when that stage applied, and the raw `capture/mic.m4a` when it did not, so
/// toggling echo cancellation — or recomputing it — changes the input identity
/// and invalidates this entry automatically.
final class EnhancedMicCache {
  static let shared = EnhancedMicCache()

  /// Each mode caches to its OWN file, so switching Light↔Balanced is an instant
  /// cache hit instead of a recompute, and — because the file a mode change
  /// produces is never the one the live preview is reading — a switch cannot
  /// delete a file out from under the playing item. Bounded by `keepNewestModes`.
  ///
  /// The stem is deliberately NOT `mic-enhanced-`: that prefix names the
  /// pipeline's per-run STAGED temp files (`AudioEnhancementPipeline`
  /// `.stagedFileNamePrefix`), which `removeStagedFiles` and the export's temp
  /// sweep both delete. A committed cache file must not collide with that.
  static let cacheFileStem = "voice-cleanup-"
  /// How many mode files to keep per project. 2 covers instant Light↔Balanced,
  /// the only two modes the UI exposes, at ~2x the single-slot disk cost.
  static let keepNewestModes = 2

  static func cacheFileURL(for projectRoot: URL, mode: VoiceCleanupMode) -> URL {
    RecordingProjectPaths.derivedDirectoryURL(for: projectRoot)
      .appendingPathComponent("\(cacheFileStem)\(mode.rawValue).caf", isDirectory: false)
  }

  static func cacheMetadataURL(for projectRoot: URL, mode: VoiceCleanupMode) -> URL {
    RecordingProjectPaths.derivedDirectoryURL(for: projectRoot)
      .appendingPathComponent("\(cacheFileStem)\(mode.rawValue).json", isDirectory: false)
  }

  /// A lookup/compute result plus who owns the produced file's lifetime,
  /// mirroring `CleanedMicCache.Outcome`.
  struct Outcome {
    let result: AudioEnhancementPipeline.Result
    /// True when the URL is the cache-owned file in `derived/` (or no new file
    /// was produced): the caller must NOT delete it or register it for temp
    /// cleanup. False when caching was unavailable and the caller received a
    /// per-run temp file it owns.
    let cacheOwned: Bool
    /// True when served from disk without recomputing.
    let fromCache: Bool
  }

  /// On-disk metadata: the cache key and the cached pipeline result.
  struct Entry: Codable, Equatable {
    let pipelineVersion: Int
    let engineVersion: Int
    let mode: String
    let inputFileSize: Int64
    let inputModifiedMs: Int64
    let applied: Bool
    let noiseReductionDb: Float
  }

  /// Shared with `CleanedMicCache` — see `AudioComputeQueue`.
  private let computeQueue = AudioComputeQueue.shared

  // MARK: - Lookup (fast: one stat + a tiny JSON read; safe on the main thread)

  /// Returns the cached outcome when the mode's metadata matches the current
  /// input file and versions, else nil. Never computes. A disabled request is a
  /// synchronous "hit" on the input mic, so the preview opens immediately
  /// instead of parking on `outcomeAsync`.
  func cachedOutcome(inputMicURL: URL, request: VoiceCleanupRequest, projectRoot: URL) -> Outcome? {
    guard request.enabled else { return Self.bypassOutcome(micURL: inputMicURL) }
    guard
      let data = try? Data(
        contentsOf: Self.cacheMetadataURL(for: projectRoot, mode: request.mode)),
      let entry = try? JSONDecoder().decode(Entry.self, from: data),
      entry.pipelineVersion == AudioEnhancementPipeline.pipelineVersion,
      entry.engineVersion == RNNoiseEngine.engineVersion,
      entry.mode == request.mode.rawValue,
      let inputStat = CleanedMicCache.fileStat(inputMicURL),
      entry.inputFileSize == inputStat.size,
      entry.inputModifiedMs == inputStat.modifiedMs
    else { return nil }
    let enhancedURL = Self.cacheFileURL(for: projectRoot, mode: request.mode)
    guard entry.applied, FileManager.default.fileExists(atPath: enhancedURL.path) else {
      return nil
    }
    return Outcome(
      result: AudioEnhancementPipeline.Result(
        enhancedMicURL: enhancedURL, applied: true, noiseReductionDb: entry.noiseReductionDb),
      cacheOwned: true, fromCache: true)
  }

  // MARK: - Compute

  /// Cache-or-compute, blocking. Used by the export preamble. Throws only
  /// genuine decode/write failures so the caller can degrade to the
  /// un-enhanced mic.
  ///
  /// MUST NOT be called from `AudioComputeQueue.shared` (it would deadlock);
  /// the echo-cancellation stage always completes and returns first.
  func outcome(inputMicURL: URL, request: VoiceCleanupRequest, projectRoot: URL) throws -> Outcome {
    if let hit = cachedOutcome(
      inputMicURL: inputMicURL, request: request, projectRoot: projectRoot)
    {
      return hit
    }
    return try computeQueue.sync {
      // A concurrent request may have filled the cache while we queued.
      if let hit = cachedOutcome(
        inputMicURL: inputMicURL, request: request, projectRoot: projectRoot)
      {
        return hit
      }
      return try computeAndStore(
        inputMicURL: inputMicURL, request: request, projectRoot: projectRoot)
    }
  }

  /// Cache-or-compute off the calling thread; `completion` runs on MAIN. A
  /// compute failure degrades to the un-enhanced mic and is NOT cached, so a
  /// transient failure is retried on the next open — the preview must never
  /// fail to open over voice cleanup.
  func outcomeAsync(
    inputMicURL: URL, request: VoiceCleanupRequest, projectRoot: URL,
    completion: @escaping (Outcome) -> Void
  ) {
    computeQueue.async { [self] in
      var out: Outcome
      if let hit = cachedOutcome(
        inputMicURL: inputMicURL, request: request, projectRoot: projectRoot)
      {
        out = hit
      } else {
        do {
          out = try computeAndStore(
            inputMicURL: inputMicURL, request: request, projectRoot: projectRoot)
        } catch {
          NativeLogger.w(
            "Audio", "Voice cleanup failed; degrading to the un-enhanced mic",
            context: ["error": "\(error)", "project": projectRoot.lastPathComponent])
          out = Self.bypassOutcome(micURL: inputMicURL)
        }
      }
      let outcome = out
      DispatchQueue.main.async { completion(outcome) }
    }
  }

  // MARK: - Internals

  /// Cache-or-compute body. Must run on `computeQueue` (single writer). Falls
  /// back to a per-run temp compute whenever the in-bundle slot is unavailable
  /// (project gone, unreadable input, read-only volume) so the cleanup is still
  /// applied.
  private func computeAndStore(
    inputMicURL: URL, request: VoiceCleanupRequest, projectRoot: URL
  ) throws -> Outcome {
    let fileManager = FileManager.default
    // Taken BEFORE the decode so an input replaced mid-compute invalidates the
    // entry (its stats at write time won't match the next read).
    let inputStat = CleanedMicCache.fileStat(inputMicURL)

    let derivedDir = RecordingProjectPaths.derivedDirectoryURL(for: projectRoot)
    var cacheSlotReady = false
    if inputStat != nil, fileManager.fileExists(atPath: projectRoot.path) {
      do {
        try fileManager.createDirectory(at: derivedDir, withIntermediateDirectories: true)
        Self.removeStagedFiles(in: derivedDir, fileManager: fileManager)
        cacheSlotReady = true
      } catch {
        cacheSlotReady = false
      }
    }

    if cacheSlotReady, let inputStat {
      do {
        return try computeIntoCache(
          inputMicURL: inputMicURL, request: request, projectRoot: projectRoot,
          derivedDir: derivedDir, inputStat: inputStat, fileManager: fileManager)
      } catch AudioEnhancementPipeline.EnhanceError.writeFailed(let url) {
        // The decode succeeded but writing INTO the bundle failed — the project
        // is on a read-only volume. Retry into the always-writable temp root
        // rather than drop the cleanup.
        Self.removeStagedFiles(in: derivedDir, fileManager: fileManager)
        NativeLogger.w(
          "Audio", "Enhanced-mic cache write failed (read-only bundle?); computing into temp root",
          context: ["url": url.lastPathComponent, "project": projectRoot.lastPathComponent])
      }
    }

    return try computeIntoTemp(
      inputMicURL: inputMicURL, request: request, fileManager: fileManager)
  }

  /// Runs the pipeline into `derivedDir`, commits (moves the CAF to the stable
  /// cache name, writes metadata last as the commit point), and returns a
  /// cache-owned outcome.
  private func computeIntoCache(
    inputMicURL: URL, request: VoiceCleanupRequest, projectRoot: URL, derivedDir: URL,
    inputStat: CleanedMicCache.FileStat, fileManager: FileManager
  ) throws -> Outcome {
    let result = try AudioEnhancementPipeline.enhance(
      micURL: inputMicURL, mode: request.mode, outputDirectory: derivedDir)
    let enhancedURL = Self.cacheFileURL(for: projectRoot, mode: request.mode)
    let metadataURL = Self.cacheMetadataURL(for: projectRoot, mode: request.mode)
    // Invalidate THIS mode's entry before swapping its audio. A reader that
    // matched the old metadata against the new CAF would serve stale content
    // for one window; dropping the metadata first makes that window a plain
    // cache miss instead. Only this mode's files are touched — other cached
    // modes (and whatever the live preview is playing) are left intact.
    try? fileManager.removeItem(at: metadataURL)
    // Same-volume move = atomic rename; only this queue writes here.
    try? fileManager.removeItem(at: enhancedURL)
    try fileManager.moveItem(at: result.enhancedMicURL, to: enhancedURL)

    let entry = Entry(
      pipelineVersion: AudioEnhancementPipeline.pipelineVersion,
      engineVersion: RNNoiseEngine.engineVersion,
      mode: request.mode.rawValue,
      inputFileSize: inputStat.size, inputModifiedMs: inputStat.modifiedMs,
      applied: true, noiseReductionDb: result.noiseReductionDb)
    // Metadata is the commit point, written last and atomically: readers
    // validate it before touching the CAF, so a crash between the move above
    // and this write just means a recompute next open.
    if let data = try? JSONEncoder().encode(entry) {
      try? data.write(to: metadataURL, options: .atomic)
    }
    // Bound disk: keep the newest few mode files, drop the rest. Never evicts
    // the mode just written (it is the newest), so it cannot delete the file
    // the caller is about to install.
    Self.evictOldModes(in: derivedDir, keeping: request.mode, fileManager: fileManager)
    return Outcome(
      result: AudioEnhancementPipeline.Result(
        enhancedMicURL: enhancedURL, applied: true, noiseReductionDb: result.noiseReductionDb),
      cacheOwned: true, fromCache: false)
  }

  /// Keeps the `keepNewestModes` most-recently-written mode files (by the
  /// metadata's mtime) plus `keeping`, deleting the rest and their metadata.
  /// Also removes the legacy single-slot `mic-enhanced.caf`/`.json` from before
  /// per-mode caching. Runs on `computeQueue`, the single writer.
  static func evictOldModes(
    in directory: URL, keeping: VoiceCleanupMode, fileManager: FileManager = .default
  ) {
    // Legacy single-slot files (pre per-mode). Named without the mode suffix, so
    // they are never valid entries now — reclaim the disk.
    try? fileManager.removeItem(at: directory.appendingPathComponent("mic-enhanced.caf"))
    try? fileManager.removeItem(at: directory.appendingPathComponent("mic-enhanced.json"))

    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return }
    let metas = entries.filter {
      $0.lastPathComponent.hasPrefix(cacheFileStem) && $0.pathExtension == "json"
    }
    guard metas.count > keepNewestModes else { return }
    func mtime(_ url: URL) -> Date {
      (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        ?? .distantPast
    }
    // Newest-first, then always float `keeping` to the front so it survives even
    // if a filesystem's mtime resolution ties it with an older file.
    let keepName = "\(cacheFileStem)\(keeping.rawValue).json"
    let ordered = metas.sorted { a, b in
      if a.lastPathComponent == keepName { return true }
      if b.lastPathComponent == keepName { return false }
      return mtime(a) > mtime(b)
    }
    for meta in ordered.dropFirst(keepNewestModes) {
      try? fileManager.removeItem(at: meta)
      try? fileManager.removeItem(at: meta.deletingPathExtension().appendingPathExtension("caf"))
    }
  }

  /// Per-run temp compute, caller owns the produced file. Nothing is persisted,
  /// so a transient failure that reached here is retried on the next open.
  private func computeIntoTemp(
    inputMicURL: URL, request: VoiceCleanupRequest, fileManager: FileManager
  ) throws -> Outcome {
    let tempRoot = AppPaths.tempRoot()
    try? fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    let result = try AudioEnhancementPipeline.enhance(
      micURL: inputMicURL, mode: request.mode, outputDirectory: tempRoot)
    return Outcome(result: result, cacheOwned: false, fromCache: false)
  }

  /// The pipeline stages its output as `mic-enhanced-<uuid>.caf` before we
  /// rename it to the stable cache name. A crash between the stage and the
  /// rename would strand that file inside `derived/`, where no other sweep
  /// looks; clearing it whenever a compute (re)enters the slot is the backstop.
  static func removeStagedFiles(in directory: URL, fileManager: FileManager = .default) {
    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else { return }
    for url in entries
    where url.lastPathComponent.hasPrefix(AudioEnhancementPipeline.stagedFileNamePrefix) {
      try? fileManager.removeItem(at: url)
    }
  }

  /// The disabled / degraded outcome: the untouched input mic. `cacheOwned`
  /// because no new file exists for the caller to own or clean up.
  static func bypassOutcome(micURL: URL) -> Outcome {
    Outcome(
      result: AudioEnhancementPipeline.Result(
        enhancedMicURL: micURL, applied: false, noiseReductionDb: 0),
      cacheOwned: true, fromCache: false)
  }
}
