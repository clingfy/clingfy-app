import Foundation

/// What the speech model costs on disk, and how to get it back.
///
/// The model is a dependency, not the user's data: several hundred megabytes
/// arrive on first transcription and nothing in the app has ever shown them or
/// offered to remove them. It is deliberately kept out of the storage snapshot's
/// "Total Clingfy usage" for the same reason — re-downloadable weights are not
/// recordings, and folding them in would make that number jump by ~859 MB the
/// first time somebody captions something.
enum CaptionModelStore {

  struct Info {
    /// Keyed off bytes, never directory existence: an empty `Models/` folder is
    /// not an installed model, and something else may well have created it.
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
  /// reporting a number derived from a different set than the one removed is
  /// how "freed 600 MB" ends up wrong while a third of it is still on disk.
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
