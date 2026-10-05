import Foundation

/// Centralized path management for app-internal and user-facing directories.
///
/// This class provides a clear separation between:
/// - **Internal workspace**: App-private storage for raw recordings, cursor data, and metadata
/// - **Export folder**: User-facing folder for final exported files (managed by SaveFolderStore)
enum AppPaths {
  private static let fallbackAppFolder = "com.tiin.clingfy"

  // MARK: - Internal Workspace (App-Private)

  /// Returns the root directory for internal recordings storage.
  /// Location: `~/Library/Application Support/<app-id>/Recordings/`
  ///
  /// This directory is:
  /// - Not user-facing (hidden in Application Support)
  /// - Excluded from backups (best-effort)
  /// - Safe from accidental user deletion
  /// - Works in both sandboxed and non-sandboxed builds
  static func recordingsRoot() -> URL {
    let recordingsDir = applicationSupportRoot()
      .appendingPathComponent("Recordings", isDirectory: true)
    ensureDirectory(recordingsDir, label: "recordings workspace", excludeFromBackup: true)
    return recordingsDir
  }

  /// Returns the root directory for internal log storage.
  /// Location: `~/Library/Application Support/<app-id>/Logs/`
  static func logsRoot() -> URL {
    let logsDir = applicationSupportRoot().appendingPathComponent("Logs", isDirectory: true)
    ensureDirectory(logsDir, label: "logs workspace", excludeFromBackup: true)
    return logsDir
  }

  /// Returns the root directory for downloaded speech-recognition models.
  /// Location: `~/Library/Application Support/<app-id>/Models/`
  ///
  /// Set explicitly on the transcription engine because its own default is
  /// `~/Documents/huggingface` — in an unsandboxed Developer-ID app that is the
  /// user's real Documents folder. Several hundred megabytes of model weights
  /// appearing there is user-visible clutter in a paid product, and Documents
  /// may sit inside iCloud Drive sync or behind Full Disk Access.
  ///
  /// Excluded from backup: the models are large, and re-downloadable.
  static func captionModelsDirectory() -> URL {
    let modelsDir = applicationSupportRoot()
      .appendingPathComponent("Models", isDirectory: true)
    ensureDirectory(modelsDir, label: "caption models", excludeFromBackup: true)
    return modelsDir
  }

  /// Where the speech models live, WITHOUT creating anything.
  ///
  /// Read-only callers must use this. `captionModelsDirectory()` creates the
  /// folder as a side effect, so asking it "how big is the model?" would
  /// materialise an empty `Models/` for every user who has never transcribed —
  /// and directory existence would stop meaning "a model is installed".
  static func captionModelsDirectoryURLIfPresent() -> URL {
    applicationSupportRootURL().appendingPathComponent("Models", isDirectory: true)
  }

  /// Clingfy's own slice of the Core ML ANE bundle cache.
  ///
  /// Measured 2026-10-05, because the number this comment used to carry was
  /// wrong and worth replacing with how to check rather than another figure.
  /// On this machine, macOS build 25B78:
  ///
  ///   ~/Library/Caches/com.clingfy.clingfy.dev/com.apple.e5rt.e5bundlecache
  ///     -> 24 KB, and only 64-byte `model.milhash` stubs
  ///   ~/Library/Caches/com.apple.e5rt.e5bundlecache/25B78
  ///     -> 29 MB, the actual compiled bundles
  ///
  /// The real blobs are in the SECOND path, which is not ours. It sits outside
  /// every app container, is keyed by OS build, and its ten entries are named
  /// by content hash with nothing identifying which app asked for them — any
  /// app doing Core ML on the ANE has entries there. So it is deliberately
  /// neither counted nor deleted: reporting it would attribute other apps'
  /// bytes to Clingfy, and removing it would throw away their compiled models
  /// to reclaim a cache macOS rebuilds on demand.
  ///
  /// What that means for the Storage screen: the compiled-cache row is honest
  /// about what Clingfy owns and can free, and understates the true one-off
  /// cost of a transcription by whatever the shared cache holds. That is the
  /// right trade, but it is a trade, so do not "fix" the row by pointing it at
  /// the shared path.
  static func compiledModelCacheDirectoryURLIfPresent() -> URL {
    cachesRootURL().appendingPathComponent(
      "com.apple.e5rt.e5bundlecache", isDirectory: true)
  }

  /// Returns the daily log file URL for the provided date.
  static func logFileURL(for date: Date = Date()) -> URL {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    let fileName = "logs_\(formatter.string(from: date)).jsonl"
    return logsRoot().appendingPathComponent(fileName, isDirectory: false)
  }

  /// Returns a temporary directory for intermediate operations.
  /// Location: `~/Library/Caches/<app-id>/Temp/`
  ///
  /// Use this for temporary export files or other transient data.
  static func tempRoot() -> URL {
    let tempDir = cachesRoot().appendingPathComponent("Temp", isDirectory: true)
    ensureDirectory(tempDir, label: "temp directory")
    return tempDir
  }

  // MARK: - Validation

  /// Checks if a URL is within the internal recordings workspace.
  static func isInternalRecording(_ url: URL) -> Bool {
    let standardizedPath = url.standardizedFileURL.path
    let currentRoot = recordingsRoot().standardizedFileURL.path
    return standardizedPath.hasPrefix(currentRoot)
  }

  // MARK: - Private Helpers

  private static func appFolderName() -> String {
    let bundleID = Bundle.main.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let bundleID, !bundleID.isEmpty {
      return bundleID
    }
    return fallbackAppFolder
  }

  /// The same location as [applicationSupportRoot], minus the side effect.
  private static func applicationSupportRootURL() -> URL {
    systemRoot(
      for: .applicationSupportDirectory,
      fallbackSubpath: "Library/Application Support"
    ).appendingPathComponent(appFolderName(), isDirectory: true)
  }

  private static func applicationSupportRoot() -> URL {
    let root = applicationSupportRootURL()
    ensureDirectory(root, label: "application support root")
    return root
  }

  /// The same location as [cachesRoot], minus the side effect.
  private static func cachesRootURL() -> URL {
    systemRoot(for: .cachesDirectory, fallbackSubpath: "Library/Caches")
      .appendingPathComponent(appFolderName(), isDirectory: true)
  }

  private static func cachesRoot() -> URL {
    let root = cachesRootURL()
    ensureDirectory(root, label: "caches root")
    return root
  }

  private static func systemRoot(
    for searchPath: FileManager.SearchPathDirectory,
    fallbackSubpath: String
  ) -> URL {
    if let url = FileManager.default.urls(for: searchPath, in: .userDomainMask).first {
      return url
    }

    return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .appendingPathComponent(fallbackSubpath, isDirectory: true)
  }

  private static func ensureDirectory(
    _ url: URL,
    label: String,
    excludeFromBackup shouldExcludeFromBackup: Bool = false
  ) {
    let fm = FileManager.default
    do {
      try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
      if shouldExcludeFromBackup {
        excludeFromBackup(url)
      }
    } catch {
      NativeLogger.e(
        "AppPaths", "Failed to create \(label)",
        context: ["path": url.path, "error": error.localizedDescription])
    }
  }

  private static func excludeFromBackup(_ url: URL) {
    var resourceValues = URLResourceValues()
    resourceValues.isExcludedFromBackup = true
    var mutableURL = url
    do {
      try mutableURL.setResourceValues(resourceValues)
    } catch {
      // Best-effort, don't fail if this doesn't work
      NativeLogger.w("AppPaths", "Could not exclude from backup", context: ["path": url.path])
    }
  }
}
