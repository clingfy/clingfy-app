import Foundation

/// What the speech model costs on disk, and how to get it back.
///
/// The model is a dependency, not the user's data: several hundred megabytes
/// arrive on first transcription and nothing in the app has ever shown them or
/// offered to remove them. It is deliberately kept out of the storage snapshot's
/// "Total Clingfy usage" for the same reason — re-downloadable weights are not
/// recordings, and folding them in would make that number jump by the better
/// part of a gigabyte the first time somebody captions something (600 MB of
/// weights on this machine, plus the tokenizer repo beside them).
enum CaptionModelStore {

  struct Info {
    /// Whether there are bytes here to report and to free — keyed off bytes,
    /// never directory existence, because an empty `Models/` folder is not an
    /// installed model and something else may well have created it.
    ///
    /// NOT the same question as `WhisperKitTranscriber.existingModelFolder()`,
    /// which is stricter: it requires all three compiled bundles plus
    /// `config.json` and answers "can the engine load this". The two disagree
    /// for exactly one state, a half-finished download, and both are right for
    /// their own purpose — this one says "300 MB you can delete", that one says
    /// "not loadable, fetch again". The engine repairs such a folder on the next
    /// Generate, so the disagreement is not a stuck state, and the Storage card
    /// never claims readiness: it shows the byte count and a Delete button,
    /// both of which are true of a partial download.
    ///
    /// Do not unify them. Making this one stricter would hide the Delete button
    /// for the one state where there are real bytes and no way for the user to
    /// reclaim them.
    let installed: Bool
    let modelBytes: Int64
    let compiledCacheBytes: Int64
    let modelPath: String
    let variant: String

    var totalBytes: Int64 { modelBytes + compiledCacheBytes }

    func toFlutter(busy: Bool, loaded: Bool) -> [String: Any] {
      [
        "installed": installed,
        "modelBytes": Int(modelBytes),
        "compiledCacheBytes": Int(compiledCacheBytes),
        "modelPath": modelPath,
        "variant": variant,
        "busy": busy,
        "loaded": loaded,
      ]
    }
  }

  static func info(variant: String) -> Info {
    let modelsURL = AppPaths.captionModelsDirectoryURLIfPresent()
    let modelBytes = directorySize(modelsURL)
    return Info(
      installed: modelBytes > 0,
      modelBytes: modelBytes,
      compiledCacheBytes: directorySize(
        AppPaths.compiledModelCacheDirectoryURLIfPresent()),
      modelPath: modelsURL.path,
      variant: variant
    )
  }

  /// Removes both directories and returns what was measured immediately before.
  ///
  /// Measured before, not after, and measured with the same walk that deletes:
  /// reporting a number derived from a different set than the one removed is how
  /// a "freed" figure ends up describing bytes that are still on disk.
  ///
  /// Both directories here are Clingfy's own. The shared ANE cache that holds
  /// the real compiled bundles is deliberately not among them — see
  /// `AppPaths.compiledModelCacheDirectoryURLIfPresent` for why removing it
  /// would take other apps' models with it.
  @discardableResult
  static func delete() -> Int64 {
    var freed: Int64 = 0
    for url in [
      AppPaths.captionModelsDirectoryURLIfPresent(),
      AppPaths.compiledModelCacheDirectoryURLIfPresent(),
    ] {
      let size = directorySize(url)
      guard size > 0 || FileManager.default.fileExists(atPath: url.path) else { continue }
      do {
        try FileManager.default.removeItem(at: url)
        freed += size
      } catch {
        NativeLogger.e(
          "Captions", "Failed to remove \(url.lastPathComponent)",
          error: String(describing: error))
      }
    }
    return freed
  }

  /// Recursive allocated size, hidden entries INCLUDED.
  ///
  /// `StorageInfoProvider.directorySize` passes `.skipsHiddenFiles`, which is
  /// right for user-facing recordings and wrong here: the download cache lives
  /// in dot-directories, so skipping them would report less than `delete()`
  /// removes.
  static func directorySize(_ url: URL, fileManager: FileManager = .default) -> Int64 {
    guard fileManager.fileExists(atPath: url.path) else { return 0 }
    let keys: [URLResourceKey] = [
      .isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey,
    ]
    guard
      let enumerator = fileManager.enumerator(
        at: url, includingPropertiesForKeys: keys, options: [])
    else { return 0 }

    var total: Int64 = 0
    for case let entry as URL in enumerator {
      guard let values = try? entry.resourceValues(forKeys: Set(keys)),
        values.isRegularFile == true
      else { continue }
      let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
      total += Int64(size)
    }
    return total
  }
}
