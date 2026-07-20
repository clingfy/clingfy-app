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

  static let enhancedFileName = "mic-enhanced.caf"
  static let metadataFileName = "mic-enhanced.json"

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

  static func enhancedFileURL(for projectRoot: URL) -> URL {
    RecordingProjectPaths.derivedDirectoryURL(for: projectRoot)
      .appendingPathComponent(enhancedFileName, isDirectory: false)
  }

  static func metadataFileURL(for projectRoot: URL) -> URL {
    RecordingProjectPaths.derivedDirectoryURL(for: projectRoot)
      .appendingPathComponent(metadataFileName, isDirectory: false)
  }

  // MARK: - Lookup (fast: one stat + a tiny JSON read; safe on the main thread)

  /// Returns the cached outcome when the metadata matches the current input
  /// file, mode and versions, else nil. Never computes. A disabled request is a
  /// synchronous "hit" on the input mic, so the preview opens immediately
  /// instead of parking on `outcomeAsync`.
  func cachedOutcome(inputMicURL: URL, request: VoiceCleanupRequest, projectRoot: URL) -> Outcome? {
    guard request.enabled else { return Self.bypassOutcome(micURL: inputMicURL) }
    guard let data = try? Data(contentsOf: Self.metadataFileURL(for: projectRoot)),
      let entry = try? JSONDecoder().decode(Entry.self, from: data),
      entry.pipelineVersion == AudioEnhancementPipeline.pipelineVersion,
      entry.engineVersion == RNNoiseEngine.engineVersion,
      entry.mode == request.mode.rawValue,
      let inputStat = CleanedMicCache.fileStat(inputMicURL),
      entry.inputFileSize == inputStat.size,
      entry.inputModifiedMs == inputStat.modifiedMs
    else { return nil }
    let enhancedURL = Self.enhancedFileURL(for: projectRoot)
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
    let enhancedURL = Self.enhancedFileURL(for: projectRoot)
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
      try? data.write(to: Self.metadataFileURL(for: projectRoot), options: .atomic)
    }
    return Outcome(
      result: AudioEnhancementPipeline.Result(
        enhancedMicURL: enhancedURL, applied: true, noiseReductionDb: result.noiseReductionDb),
      cacheOwned: true, fromCache: false)
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
